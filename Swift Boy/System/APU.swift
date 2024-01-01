//
//  APU.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/26/23.
//

import Foundation

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

class APU: MemoryMappedDevice {
    // MARK: - Private variables
    
    private var divAPUCycles: Register = 0
    
    private var channelOne: PulseWithPeriodSweep = PulseWithPeriodSweep(enableSweep: true)
    private var channelTwo: PulseWithPeriodSweep = PulseWithPeriodSweep(enableSweep: false)
    private var channelThree: WaveChannel = WaveChannel()
    private var channelFour: NoiseChannel = NoiseChannel()
    
    private let channels: [AudioChannel]
    
    private var apuEnabled: Bool = false
    
    private var leftVolume: Register = 0
    private var rightVolume: Register = 0
    
    // We don't support VIN, but need to track these in case a games care
    
    private var vinLeft: Bool = false
    private var vinRight: Bool = false
    
    private var lastAPUStatus: Register?
    
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
                print("APU status is now 0x" + toHex(x));
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
    
    // MARK: - Constructor
    
    init() {
        channels = [channelOne, channelTwo, channelThree, channelFour]
    }
    
    // MARK: - Public functions
    
    func reset() {
        // Set things to the boot state
        
        channels.forEach { c in c.reset() }
        
        divAPUCycles = 0
        
        audioControlRegister = 0x77
        soundPanningRegister = 0xF3
        masterVolumeRegister = 0xF1        
    }
    
    func enableAPU() {
        guard !apuEnabled else {
            return
        }
        
        apuEnabled = true
        
        print("APU now enabled")
        
        // TODO: Other stuff?
    }
    
    func disableAPU() {
        guard apuEnabled else {
            return
        }
        
        print("APU now disabled")
        
        // TODO: Clear stuff when this is turned off, see PAN docs
        
        // Clear all registers but the master control register
        
        channels.forEach { c in c.disableAPU() }
        
        // Note: We CAN NOT write to audioControlRegister, that will cause infinite recursion
        
        apuEnabled = false              // The only thing in audioControlRegister
        divAPUCycles = 0
        
        soundPanningRegister = 0x00
        masterVolumeRegister = 0x00
    }
    
    // MARK: - Tick functions
    
    func tick(_ ticks: Ticks) {
        // TODO: This? Or does divTick do everything we need?
        
        channels.forEach { c in c.tick(ticks) }
    }
    
    func divTick() {
        // We have to do a couple of tasks at different frequencies based on div ticks
        // First let the channels do whatever they want
        
        channels.forEach { c in c.tickAPU() }
        
        // Length counts happen on even cycles
        
        if divAPUCycles % 2 == 0 {
            tickLengthCounters()
        }
        
        // On cycle 2 and 6 (when the divAPUCycles counter ends in 0b10) we do the sweep function
        
        if divAPUCycles == 2 || divAPUCycles == 6 {
            tickSweep()
        }
        
        // On cycle 7 we do the volume envelopes
        
        if divAPUCycles == 7 {
            tickVolumeEnvelope()
        }
        
        // Increase the counter but prevent it from hitting 8 or more
        
        divAPUCycles = (divAPUCycles + 1) % 8
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
