//
//  NoiseChannel.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/27/23.
//

import Foundation

private let SC4_LENGTH: Address = 0xFF20
private let SC4_VOLUME_ENVELOPE: Address = 0xFF21
private let SC4_FREQUENCY_RANDOMNESS: Address = 0xFF22
private let SC4_CONTROL: Address = 0xFF23

class NoiseChannel: AudioChannel {
    // MARK: - Private variables
    
    private let lengthCounter: AudioLengthCounter
    
    private var lastNoiseBit: Bool = false
    private var lastOutputAdjustedForVolume: SoundSample = 0.0
    
    private var initialVolume: Register = 0
    private var actualVolume: Register = 0
    private var volumeChanged: Bool = false
    
    private var envelopeDirection: Bool = false
    private var shadowEnvelopeDirection: Bool = false
    private var envelopePace: Register = 0
    private var shadowEnvelopePace: Register = 0
    private var envelopeTicks: Register = 0
    
    private var clockShift: Register = 0
    private var clockDivider: Register = 0
    private var clockTicks: Int = 0
    
    private var enabled: Bool = false
    private var dacEnabled: Bool = false
    
    private var lowLFSRWidth: Bool = false
    private var lfsr: RegisterPair = 0
    
    private var firstCycleSinceRestart = true
    private var lastNoiseAdjustedForVolume: SoundSample = 0.0
    
    private var lastSample: SoundSample = 0.0
    private var impulseSinceLastSample: SoundSample = 0.0
    
    var apu: APU? = nil
    
    // MARK: - Registers
    
    private var lengthRegister: Register {
        get {
            return 0xFF     // Write only register, so always returns 0xFF
        }
        set (value) {
            lengthCounter.initalLength = value & 0x3F   // Skip the top two bits
        }
    }
    
    private var volumeAndEnvelopeRegister: Register {
        get {
            return initialVolume << 4
                    + (envelopeDirection ? 0x08 : 0x00)
                    + envelopePace
        }
        set (value) {
            initialVolume = value >> 4
            envelopeDirection = value & 0x08 == 0x08
            envelopePace = value & 0x07
            
            let enableDACSetting = value & 0xF8 != 0   // If all the top bits are 0, the DAC is disabled
            
            if (enableDACSetting) {
                enableDAC()
            } else {
                disableDAC()
            }
            
            // For extra craziness, on the original gameboy writting $08 increments the actual volume by 1, wrapping around
            // Not the initial volume, but what it actually is currently in the shadown register
            
            if value == 0x08 && shadowEnvelopeDirection == true && shadowEnvelopePace == 0 {
                // They hit the conditions
                
                actualVolume = (actualVolume + 1) % 16
                volumeChanged = true
            }
        }
    }
    
    private var frequencyAndRandomnessRegister: Register {
        get {
            return clockShift << 4
                    + (lowLFSRWidth ? 0x08 : 0x00)
                    + clockDivider
        }
        set (value) {
            clockShift = value >> 4
            lowLFSRWidth = value & 0x08 == 0x08
            clockDivider = value & 0x07
        }
    }
    
    private var controlRegister: Register {
        get {
            return 0x80                         // High bit is always set since it's not readable
                    + (lengthCounter.enabled ? 0x40 : 0x00)
                    + 0x3F                      // Bottom bits aren't used either
        }
        set (value) {
            let shouldEnableLengthCounter = value & 0x40 == 0x40
            let triggering = value & 0x80 == 0x80
            
            if apu!.notOnLengthTickCycle() {
                // Extra length clocking occurs when you write to this register during this window
                
                if !lengthCounter.enabled && shouldEnableLengthCounter && !lengthCounter.equalsZero {
                    // If the length counter is being enabled and it wasn't before, the counter isn't at 0 do an extra decrement
                    
                    lengthCounter.performExtraDecrement(andDisableIfZero: !triggering)  // Don't disable if we're not triggering
                }
                
                // If the channel is triggered and the counter is changed to enabled and length was 0 set length to MAX - 1
                
                if (triggering && shouldEnableLengthCounter && lengthCounter.equalsZero) {
                    lengthCounter.setToMaxAndDecrement()
                }
            }
            
            lengthCounter.enabled = shouldEnableLengthCounter
            
            if triggering {
                trigger()
            }
        }
    }
    
    // MARK: - Constructor
    
    init() {
        self.lengthCounter = AudioLengthCounter(64)
        self.lengthCounter.disableChannel = { self.disableChannel() }
    }
    
    // MARK: - AudioChannel protocol functions
    
    func reset() {
        // Set things to the boot state
        
        lengthRegister = 0xFF
        volumeAndEnvelopeRegister = 0x00
        frequencyAndRandomnessRegister = 0x00
        controlRegister = 0xBF
        
        volumeChanged = false
        
        lastSample = 0.0
        impulseSinceLastSample = 0.0
        lastOutputAdjustedForVolume = 0.0
        
        envelopeTicks = 0
        shadowEnvelopePace = envelopePace
        shadowEnvelopeDirection = envelopeDirection
        
        firstCycleSinceRestart = true
    }
    
    func disableAPU() {
        lengthRegister = 0x00
        volumeAndEnvelopeRegister = 0x00
        frequencyAndRandomnessRegister = 0x00
        controlRegister = 0x00
    }
    
    func disableChannel() {
        enabled = false        
        lastOutputAdjustedForVolume = 0.0
    }
    
    func isEnabled() -> Bool {
        return enabled
    }
    
    func tick(_ ticks: Ticks) {
        guard enabled else {
            return
        }
        
        for _ in 1...ticks {
            clockTicks += 1
            
            // Dividing by 4 takes care of this being in T-states not ticks
            let realDivisor: Int = clockDivider == 0 ? 8 : 16 * Int(clockDivider)
            let realShift: Int = clockShift == 0 ? 1 : 2 << (clockShift - 1)        // 0 means "no shift"
            
            let interval = (realDivisor * realShift) / 4
            
            if clockTicks >= interval {
                clockTicks = 0
                
                if firstCycleSinceRestart {
                    // The very first cycle is always no output, no matter what
                    
                    lastNoiseAdjustedForVolume = 0.0
                    firstCycleSinceRestart = false
                }
                
                advanceNoise()
                
                let newNoise = (lastNoiseBit ? 1.0 : -1.0) * SoundSample(actualVolume) / 15.0
                
                let impulseChange = newNoise - lastNoiseAdjustedForVolume
                lastNoiseAdjustedForVolume = newNoise
                
                impulseSinceLastSample += impulseChange
            } else if volumeChanged {
                // Because noise can change so slowly, we need to handle this
                
                volumeChanged = false
                
                let newNoise = (lastNoiseBit ? 1.0 : -1.0) * SoundSample(actualVolume) / 15.0
                
                let impulseChange = newNoise - lastNoiseAdjustedForVolume
                lastNoiseAdjustedForVolume = newNoise
                
                impulseSinceLastSample += impulseChange
            }
        }
    }
    
    func tickLengthCounter() {
        lengthCounter.tickLengthCounter()
    }
    
    func tickVolumeEnvelope() {
        // We have shadow registers becuase changes only take effect when the channel is triggered
        // Also no envelope changes if the pace is 0 or the channel isn't enabled
        guard enabled && shadowEnvelopePace > 0 else {
            return
        }
        
        envelopeTicks += 1
        
        if envelopeTicks >= shadowEnvelopePace {
            // Time to adjust the envelope
            
            if shadowEnvelopeDirection == false && actualVolume == 0 {
                // Can't lower volume that's already at 0
                // Let's stop ourselves from getting here again
                shadowEnvelopePace = 0
                return
            } else if shadowEnvelopeDirection && actualVolume == 15 {
                // Can't raise volume that's already at 15 (max)
                // Let's stop ourselves from getting here again
                shadowEnvelopePace = 0
                return
            }
            
            let change = shadowEnvelopeDirection ? 1 : -1
            
            actualVolume = UInt8(Int(actualVolume) + change)
            
            volumeChanged = true
            
            envelopeTicks = 0
        }
    }

    func collectSample() -> SoundSample {
        guard enabled else {
            return 0.0
        }
        
        lastSample += impulseSinceLastSample
        
        impulseSinceLastSample = 0.0
        
        return lastSample
    }
    
    // MARK: - Private functions
    
    private func advanceNoise() {
        let bitZero = lfsr & 0x0001
        let bitOne = (lfsr & 0x0002) >> 1
        let equals = bitZero == bitOne  // XNOR operation
        
        // If they're equal, set bit 15. It should always be clear before this due the the right shift.
        
        lfsr = lfsr | (equals ? 0x8000 : 0x0000)
        
        // Do the same to bit 7 if we're in low LFSR width mode (have to clear it just in case)
        
        if (lowLFSRWidth) {
            lfsr = (lfsr & 0xFF7F) + (equals ? 0x0080 : 0x0000)
        }
        
        // Bit 0 will be the return (clear = silent, set = volume in channel 4 volume/envelope register)
        
        lastNoiseBit = lfsr & 0x0001 > 0
        
        lfsr >>= 1
    }
    
    // MARK: - Channel specific functions
    
    private func trigger() {
        // Tell the timer we were triggered
        
        lengthCounter.trigger()
        
        // Don't do anything else if we're disabled
        
        guard dacEnabled else {
            return
        }
        
        // Reset the LFSR to all 1s
        
        lfsr = 0xFFFF
        
        clockTicks = 0
        
        // Enable the channel
        
        enabled = true

        actualVolume = initialVolume
        envelopeTicks = 0
        shadowEnvelopePace = envelopePace
        shadowEnvelopeDirection = envelopeDirection
        
        volumeChanged = false
        
        // Sample stuff
        
        lastSample = 0.0
        impulseSinceLastSample = 0.0
    }
    
    private func enableDAC() {
        guard !dacEnabled else {
            return
        }
        
        dacEnabled = true
    }
    
    private func disableDAC() {
        guard dacEnabled else {
            return
        }
        
        disableChannel()
        dacEnabled = false
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        switch address {
            case SC4_LENGTH:
                return lengthRegister
            case SC4_VOLUME_ENVELOPE:
                return volumeAndEnvelopeRegister
            case SC4_FREQUENCY_RANDOMNESS:
                return frequencyAndRandomnessRegister
            case SC4_CONTROL:
                return controlRegister
            default:
                return 0xFF     // This location doesn't exist. Nice try.
        }
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        switch address {
            case SC4_LENGTH:
                lengthRegister = value
            case SC4_VOLUME_ENVELOPE:
                volumeAndEnvelopeRegister = value
            case SC4_FREQUENCY_RANDOMNESS:
                frequencyAndRandomnessRegister = value
            case SC4_CONTROL:
                controlRegister = value
            default:
                return      // This location doesn't exist. Nice try.
        }
    }
}
