//
//  APU.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/26/23.
//

import Foundation
import Synchronization

private let CHANNEL_ONE_RANGE: ClosedRange<Address> = 0xFF10...0xFF14
private let CHANNEL_TWO_RANGE: ClosedRange<Address> = 0xFF16...0xFF19
private let CHANNEL_THREE_RANGE: ClosedRange<Address> = 0xFF1A...0xFF1E
private let CHANNEL_FOUR_RANGE: ClosedRange<Address> = 0xFF20...0xFF23

private let WAVE_PATTERN_RANGE: ClosedRange<Address> = 0xFF30...0xFF3F

private let AUDIO_CONTROL: Address = 0xFF26
private let SOUND_PANNING: Address = 0xFF25
private let MASTER_VOLUME: Address = 0xFF24

private enum AudioMasterControl {
    static let audioOn: UInt8 = 0x80
    static let channelFourOn: UInt8 = 0x08
    static let channelThreeOn: UInt8 = 0x04
    static let channelTwoOn: UInt8 = 0x02
    static let channelOneOn: UInt8 = 0x01
}

private enum SoundPanning {
    static let channelFourLeft: UInt8 = 0x80
    static let channelThreeLeft: UInt8 = 0x40
    static let channelTwoLeft: UInt8 = 0x20
    static let channelOneLeft: UInt8 = 0x10
    static let channelFourRight: UInt8 = 0x08
    static let channelThreeRight: UInt8 = 0x04
    static let channelTwoRight: UInt8 = 0x02
    static let channelOneRight: UInt8 = 0x01
}

private enum DutyCycle {
    static let twelvePointFive: UInt8 = 0x00
    static let twentyFive: UInt8 = 0x01
    static let fifty: UInt8 = 0x02
    static let seventyFive: UInt8 = 0x03
}

private let TWELVE_POINT_FIVE_DUTY_CYCLE: [VolumeLevel] = [0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x00,
                                                           0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x00]
private let TWENTY_FIVE_DUTY_CYCLE: [VolumeLevel] = [0x00, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x00,
                                                     0x00, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x00]
private let FIFTY_DUTY_CYCLE: [VolumeLevel] = [0x00, 0x0F, 0x0F, 0x0F, 0x0F, 0x00, 0x00, 0x00,
                                               0x00, 0x0F, 0x0F, 0x0F, 0x0F, 0x00, 0x00, 0x00]
private let SEVENTY_FIVE_DUTY_CYCLE: [VolumeLevel] = [0x0F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F,
                                                      0x0F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F]

private let SAMPLE_RATE: Float = 44100.0
private let SAMPLE_LENGTH: Float = 1.0 / SAMPLE_RATE    // How long one audio sample should be, in fractions of a second
private let SAMPLE_COUNT = Int(SAMPLE_RATE) * 2
private let CPU_FREQUENCY: Float = 4194304.0
private let TICKS_PER_SECOND: Float = CPU_FREQUENCY / 4
private let TICK_LENGTH: Float = 1.0 / TICKS_PER_SECOND
private let TICKS_PER_SAMPLE = SAMPLE_LENGTH / TICK_LENGTH      // How many ticks are in each sample
private let TWENTY_MS_OF_SAMPLES = Int(0.02 / SAMPLE_LENGTH)    // How many elements is 20ms worth of samples?

class APU: MemoryMappedDevice {
    // MARK: - Private variables
    
    private var frameSequencer: Register = 0
    
    var channelOne: PulseWithPeriodSweep = PulseWithPeriodSweep(channelSweeps: true)
    var channelTwo: PulseWithPeriodSweep = PulseWithPeriodSweep(channelSweeps: false)
    var channelThree: WaveChannel = WaveChannel()
    var channelFour: NoiseChannel = NoiseChannel()
    
    private var samples: UnsafeMutablePointer<SoundSample>
    
    private let sampleReader = Atomic<Int>(0)
    private let sampleWriter = Atomic<Int>(TWENTY_MS_OF_SAMPLES * 2)  // Start a bit in to give us some buffer 0.0s
    
    private let channels: [AudioChannel]
    
    private var apuEnabled: Bool = false
    
    private var leftVolume: Register = 0
    private var rightVolume: Register = 0
    
    private var ticksSinceLastSample: Float = 0.0
    
    // We don't support VIN, but need to track these in case a games care
    
    private var vinLeft: Bool = false
    private var vinRight: Bool = false
    
    private var lastAPUStatus: Register?
    
    private var audioOutput: AudioOutput? = nil
    
    // MARK: - Registers
    
    private var audioControlRegister: Register {
        get {
            // Construct the return from if audio is enabled plus bits created from the channel control registers
            
            let x: Register = (apuEnabled ? 0x80 : 0x00)
                                + 0x70      // All unused bits are returned as 1s
                                + (channelFour.isEnabled() ? 0x08 : 0x00)
                                + (channelThree.isEnabled() ? 0x04 : 0x00)
                                + (channelTwo.isEnabled() ? 0x02 : 0x00)
                                + (channelOne.isEnabled() ? 0x01 : 0x00)
            
            if lastAPUStatus == nil || x != lastAPUStatus {
                lastAPUStatus = x
            }
            
            return (apuEnabled ? 0x80 : 0x00)
                    + 0x70      // All unused bits are returned as 1s
                    + (channelFour.isEnabled() ? 0x08 : 0x00)
                    + (channelThree.isEnabled() ? 0x04 : 0x00)
                    + (channelTwo.isEnabled() ? 0x02 : 0x00)
                    + (channelOne.isEnabled() ? 0x01 : 0x00)
        }
        set (value) {
            // Only bit 7 matters, all the rest are ignored on writes
            
            if (value & 0x80 == 0x80) {
                // We need to make sure the APU is disabled
                enableAPU()
            } else {
                // We need to make sure the APU is disabled
                disableAPU()
            }
        }
    }
    
    private var soundPanningRegister: Register = 0
    
    private var masterVolumeRegister: Register {        // We're not going to bother with the cartridge sound/VIN since no one used that
        get {
            return (vinLeft ? 0x80 : 0x00)
                    + (leftVolume << 4)
                    + (vinRight ? 0x08 : 0x00)
                    + rightVolume
        }
        set(value) {
            vinLeft = (value & 0x80) == 0x80
            leftVolume = (value & 0x70) >> 4    // Bits 4-6
            vinRight = (value & 0x08) == 0x08
            rightVolume = value & 0x07          // Last 3 bits
        }
    }
    
    // MARK: - Constructor/destructor
    
    init() {
        channels = [channelOne, channelTwo, channelThree, channelFour]
        
        samples = .allocate(capacity: SAMPLE_COUNT)
        samples.initialize(repeating: 0.0, count: SAMPLE_COUNT)
        
        channelOne.apu = self
        channelTwo.apu = self
        channelThree.apu = self
        channelFour.apu = self
        
        audioOutput = AudioOutput(apu: self)
    }
    
    deinit {
        samples.deinitialize(count: SAMPLE_COUNT)
        samples.deallocate()
    }
    
    // MARK: - Public functions
    
    func reset() {
        // Set things to the boot state
        
        channels.forEach { c in c.reset() }
        
        frameSequencer = 0
        
        audioControlRegister = 0x77
        soundPanningRegister = 0xF3
        masterVolumeRegister = 0xF1        
    }
    
    func enableAPU() {
        guard !apuEnabled else {
            return
        }
        
        apuEnabled = true
        
        audioOutput?.start()
    }
    
    func disableAPU() {
        guard apuEnabled else {
            return
        }
        
        // TODO: Clear stuff when this is turned off, see PAN docs
        
        audioOutput?.stop()
        
        // Clear all registers but the master control register
        
        channels.forEach { c in c.disableAPU() }
        
        // Note: We CAN NOT write to audioControlRegister, that will cause infinite recursion
        
        apuEnabled = false              // The only thing in audioControlRegister
        frameSequencer = 0
        
        soundPanningRegister = 0x00
        masterVolumeRegister = 0x00
    }
    
    func notOnLengthTickCycle() -> Bool {
        /*
         * There is a fun little quirk of the GB where if a channel's length counter is enabled when it wasn't
         * during the time the frame sequencer would not have ticked a length counter clock an update to
         * the length counter happens even though it's technically wrong. So the audio channels need to know which
         * stage of things we're in.
         */
        
        return frameSequencer % 2 != 0
    }
    
    func collectAudio(into destination: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        // Local copies so we don't have to mess with atomics constantly
        
        let readPointer = sampleReader.load(ordering: .acquiring)
        let writePointer = sampleWriter.load(ordering: .acquiring)
        
        // Figure out how many samples we have.
        let samplesReady = ((writePointer - readPointer) + (writePointer < readPointer ? SAMPLE_COUNT : 0)) / 2
        let wrapped = (writePointer < readPointer) && (readPointer + frameCount * 2 > SAMPLE_COUNT)
        
        // Copy what we have
        
        if !wrapped {
            if samplesReady >= frameCount {
                let sourceStart = samples.advanced(by: readPointer)
                destination.baseAddress!.update(from: sourceStart, count: frameCount * 2)
                
                // If samplesReady == frameCount it's possible to end up RIGHT PAST THE END of the array. So wrap.
                sampleReader.store((readPointer + 2 * frameCount) % SAMPLE_COUNT, ordering: .releasing)
            } else {
                // We're short, copy what we have, fill the rest with 0.0
                
                let sourceStart = samples.advanced(by: readPointer)
                destination.baseAddress!.update(from: sourceStart, count: samplesReady * 2)
                destination.baseAddress!.update(repeating: 0.0, count: (frameCount - samplesReady) * 2)
                
                // If the writer is ahead of us, we don't need to worry about wrapping
                sampleReader.add(2 * samplesReady, ordering: .releasing)
            }
        } else {
            // Oh goody, this is harder
            
            let runOne = SAMPLE_COUNT - readPointer   // Both in array elements, not samples
            let runTwo = frameCount * 2 - runOne
            
            if samplesReady >= frameCount {
                let runOneStart = samples.advanced(by: readPointer)
                let runTwoStart = samples.advanced(by: 0)
                destination.baseAddress!.update(from: runOneStart, count: runOne)
                destination.baseAddress!.update(from: runTwoStart, count: runTwo)
                
                sampleReader.store((readPointer + 2 * frameCount) % SAMPLE_COUNT, ordering: .releasing)
            } else {
                // We're short, copy what we have, fill the rest with 0.0
                
                if runOne > samplesReady * 2 {
                    // Easiest case, between us and the end of the array is everything we have
                    
                    let sourceStart = samples.advanced(by: readPointer)
                    destination.baseAddress!.update(from: sourceStart, count: samplesReady * 2)
                    destination.baseAddress!.update(repeating: 0.0, count: (frameCount - samplesReady) * 2)

                    // We didn't make it to the end, don't worry about wrapping
                    sampleReader.add(2 * samplesReady, ordering: .releasing)
                } else {
                    // Harder case, between us and the end of the array is OK, the rest is too short
                    
                    let runOneStart = samples.advanced(by: readPointer)
                    let runTwoStart = samples.advanced(by: 0)
                    
                    destination.baseAddress!.update(from: runOneStart, count: runOne)
                    destination.baseAddress!.update(from: runTwoStart, count: samplesReady * 2 - runOne)
                    destination.baseAddress!.update(repeating: 0.0, count: (frameCount - samplesReady) * 2)
                    
                    sampleReader.store((readPointer + 2 * samplesReady) % SAMPLE_COUNT, ordering: .releasing)
                }
            }
        }
    }
    
    // MARK: - Tick functions
    
    func tick(_ ticks: Ticks) {
        // Tick each channel. This lets them book-keep so when we need to collect a sample we have what we need
        
        channels.forEach { c in c.tick(ticks) }
        
        // Is it time to get a new sample from the channels?
        
        ticksSinceLastSample += Float(ticks)
        
        if ticksSinceLastSample > TICKS_PER_SAMPLE {
            ticksSinceLastSample -= TICKS_PER_SAMPLE
                        
            let channelOneSample = channelOne.collectSample()
            let channelTwoSample = channelTwo.collectSample()
            let channelThreeSample = channelThree.collectSample()
            let channelFourSample = channelFour.collectSample()
            
            var leftSample: SoundSample = 0.0
            var rightSample: SoundSample = 0.0
            
            // Ok merge things the way the APU does
            
            if apuEnabled {
                // Use the panning register to put things in the right places
                
                if soundPanningRegister & 0x80 > 0 {
                    leftSample += channelFourSample
                }
                if soundPanningRegister & 0x40 > 0 {
                    leftSample += channelThreeSample
                }
                if soundPanningRegister & 0x20 > 0 {
                    leftSample += channelTwoSample
                }
                if soundPanningRegister & 0x10 > 0 {
                    leftSample += channelOneSample
                }
                if soundPanningRegister & 0x08 > 0 {
                    rightSample += channelFourSample
                }
                if soundPanningRegister & 0x04 > 0 {
                    rightSample += channelThreeSample
                }
                if soundPanningRegister & 0x02 > 0 {
                    rightSample += channelTwoSample
                }
                if soundPanningRegister & 0x01 > 0 {
                    rightSample += channelOneSample
                }
                
                // Normalize
                
                leftSample /= 4.0
                rightSample /= 4.0
                
                // Adjust for volume
                
                leftSample *= (SoundSample(leftVolume) + 1.0) / 8.0
                rightSample *= (SoundSample(rightVolume) + 1.0) / 8.0
                
                // Ensure we have space
                
                let reader = sampleReader.load(ordering: .acquiring)
                let current = sampleWriter.load(ordering: .acquiring)
                let nextWrite = (current + 2) % SAMPLE_COUNT
                
                guard nextWrite != reader else {
                    // We want to maintain at least one element between the writer and the reader.
                    // Otherwise we can't tell full (current = reader, we caught up to them) from
                    // when things are empty (current = reader, they caught up to us)
                    
                    return
                }
                
                // Store them, left first
                
                samples[current] = leftSample
                samples[current + 1] = rightSample
                
                sampleWriter.store(nextWrite, ordering: .releasing)
            }
        }
    }
    
    func divTick() {
        // We have to do a couple of tasks at different frequencies based on div ticks        
        // Length counts happen on even cycles
        
        if frameSequencer % 2 == 0 {
            tickLengthCounters()
        }
        
        // On cycle 2 and 6 (when the frameSequencer counter ends in 0b10) we do the sweep function
        
        if frameSequencer == 2 || frameSequencer == 6 {
            tickSweep()
        }
        
        // On cycle 7 we do the volume envelopes
        
        if frameSequencer == 7 {
            tickVolumeEnvelope()
        }
        
        // Increase the counter but prevent it from hitting 8 or more
        
        frameSequencer = (frameSequencer + 1) % 8
    }
    
    // MARK: - Private functions
    
    private func tickLengthCounters() {
        channels.forEach { c in c.tickLengthCounter() }
    }
    
    private func tickSweep() {
        channelOne.tickSweep()
    }
    
    private func tickVolumeEnvelope() {
        channels.forEach { c in c.tickVolumeEnvelope() }
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        switch address {
            case CHANNEL_ONE_RANGE:
                return channelOne.readRegister(address)
            case CHANNEL_TWO_RANGE:
                return channelTwo.readRegister(address)
            case CHANNEL_THREE_RANGE:
                return channelThree.readRegister(address)
            case CHANNEL_FOUR_RANGE:
                return channelFour.readRegister(address)
            case WAVE_PATTERN_RANGE:
                return channelThree.readRegister(address)
            case AUDIO_CONTROL:
                return audioControlRegister
            case SOUND_PANNING:
                return soundPanningRegister
            case MASTER_VOLUME:
                return masterVolumeRegister
            default:
                return 0xFF     // This location doesn't exist. Nice try.
        }
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        guard apuEnabled || address == AUDIO_CONTROL || WAVE_PATTERN_RANGE.contains(address) else {
            // Only the audio control register, the timer length registers, and the wave pattern can be written when the APU is off
            return
        }
        
        switch address {
            case CHANNEL_ONE_RANGE:
                return channelOne.writeRegister(address, value)
            case CHANNEL_TWO_RANGE:
                return channelTwo.writeRegister(address, value)
            case CHANNEL_THREE_RANGE:
                return channelThree.writeRegister(address, value)
            case CHANNEL_FOUR_RANGE:
                return channelFour.writeRegister(address, value)
            case WAVE_PATTERN_RANGE:
                return channelThree.writeRegister(address, value)
            case AUDIO_CONTROL:
                audioControlRegister = value
            case SOUND_PANNING:
                soundPanningRegister = value
            case MASTER_VOLUME:
                masterVolumeRegister = value
            default:
                return      // This location doesn't exist. Nice try.
        }
    }
}
