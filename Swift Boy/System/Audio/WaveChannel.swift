//
//  WaveChannel.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/27/23.
//

import Foundation

// This is used for channel 3, the wave channel

private let SC3_DAC_ENABLE: Address = 0xFF1A
private let SC3_LENGTH: Address = 0xFF1B
private let SC3_OUTPUT_LEVEL: Address = 0xFF1C
private let SC3_PERIOD_LOW: Address = 0xFF1D
private let SC3_PERIOD_HIGH_CONTROL: Address = 0xFF1E

private let WAVE_PATTERN_RANGE: ClosedRange<Address> = 0xFF30...0xFF3F

private enum WavePatternVolume {
    static let mute: UInt8 = 0x00
    static let full: UInt8 = 0x01
    static let half: UInt8 = 0x02
    static let quarter: UInt8 = 0x03
}

class WaveChannel: AudioChannel {
    private var enabled: Bool = false
    private var dacEnabled: Bool = false
    
    private let lengthCounter: AudioLengthCounter
    
    private var actualVolume: Register = 0
    private var volumeChanged: Bool = false
    
    private var period: UInt16 = 0
    private var periodCounter: UInt16 = 0
    
    private var wavePatternNibble: Register = 0
    
    private var wavePattern: [Register] = [Register](repeating: 0, count: 16)
    
    private var lastWaveOutputAdjustedForVolume: Float16 = 0.0
    
    private var lastSample: Float16 = 0.0
    private var impulseSinceLastSample: Float16 = 0.0
    
    var apu: APU? = nil
    
    // MARK: - Registers
    
    private var dacEnableRegister: Register {
        get {
            return dacEnabled ? 0xFF : 0x7F   // High bit is if the DAC is enabled
        }
        set (value) {
            let enableDACSetting = value & 0x80 == 0x80
            
            if (enableDACSetting) {
                enableDAC()
            } else {
                disableDAC()
            }
        }
    }
    
    private var lengthTimerRegister: Register {
        get {
            return 0xFF     // You can't read this back
        }
        set (value) {
            lengthCounter.initalLength = value
        }
    }
    
    private var outputLevelRegister: Register {
        get {
            return 0b10011111 + (actualVolume << 5)    // All ignored bits are 1s
        }
        set (value) {
            actualVolume = (value & 0x7F) >> 5
            volumeChanged = true
        }
    }
    
    private var periodLowRegister: Register {
        get {
            return 0xFF     // Write only register, so always returns 0xFF
        }
        set (value) {
            period = period & 0xFF00 + UInt16(value)
        }
    }
    
    private var periodHighAndControlRegister: Register {
        get {
            return 0x80                         // High bit is always set since it's not readable
                    + (lengthCounter.enabled ? 0x40 : 0x00)
                    + 0x3F                      // Next 3 aren't used, last 3 are read-only so return 1
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
            
            period = period & 0x00FF + (UInt16(value) & 0x07) << 8      // Take the bottom 3 bits, put them in place on Period
            
            if triggering {
                trigger()
            }
        }
    }
    
    // MARK: - Constructor
    
    init() {
        self.lengthCounter = AudioLengthCounter(256)
        self.lengthCounter.disableChannel = { self.disableChannel() }
    }
    
    // MARK: - AudioChannel protocol functions
    
    func reset() {
        // Set things to the boot state
        
        dacEnableRegister = 0x7F
        lengthTimerRegister = 0xFF
        outputLevelRegister = 0x9F
        periodLowRegister = 0xFF
        periodHighAndControlRegister = 0xBF

        wavePattern = [Register](repeating: 0, count: 16)
        wavePatternNibble = 0
        periodCounter = 0
        
        volumeChanged = false
        
        lastSample = 0.0
        impulseSinceLastSample = 0.0
        
        lastWaveOutputAdjustedForVolume = 0.0
    }
    
    func disableAPU() {
        dacEnableRegister = 0x00
        lengthTimerRegister = 0x00
        outputLevelRegister = 0x00
        periodLowRegister = 0x00
        periodHighAndControlRegister = 0x00
        
        wavePatternNibble = 0
        periodCounter = 0
        
        lastWaveOutputAdjustedForVolume = 0.0
    }
    
    func disableChannel() {
        guard enabled else {
            return
        }
        
        enabled = false
    }
    
    func isEnabled() -> Bool {
        return enabled
    }
    
    func tick(_ ticks: Ticks) {
        guard enabled else {
            return
        }
        
        for _ in 1...ticks {
            periodCounter += 2      // Runs twice as fast as the square wave channels
            
            if periodCounter >= 0x0800 {
                // Advance the pointer
                
                wavePatternNibble = (wavePatternNibble + 1) % 32
                
                // Save what we had last
                
                let lastWaveOutput = lastWaveOutputAdjustedForVolume
                
                // It overflowed. Reset it and tick the duty step.
                
                periodCounter = period
                
                // Get that new nibble
                
                var nibble = Int(wavePattern[Int(wavePatternNibble) / 2])
                
                if wavePatternNibble % 2 == 0 {
                    // High nibble, get what we want
                    
                    nibble = nibble >> 4
                } else {
                    // Low nibble, mask out the high stuff
                    
                    nibble = nibble & 0x0F
                }
                
                // Calculate the output
                
                let newWaveOutput = currentNibbleToSample()
                
                lastWaveOutputAdjustedForVolume = newWaveOutput
                
                // Calculate change and accrue it
                
                impulseSinceLastSample += newWaveOutput - lastWaveOutput
            } else if volumeChanged {
                // Change the sample we're outputting
                
                volumeChanged = false
                
                // Temporarily hold the last value we put out
                
                let lastWaveOutput = lastWaveOutputAdjustedForVolume
                
                // Re-calculate the output
                
                let newWaveOutput = currentNibbleToSample()
                
                lastWaveOutputAdjustedForVolume = newWaveOutput
                
                // Calculate change and accrue it
                
                impulseSinceLastSample += newWaveOutput - lastWaveOutput
            }
        }
    }
    
    
    func tickLengthCounter() {
        lengthCounter.tickLengthCounter()
    }
    
    func tickVolumeEnvelope() {
        // Not a feature, ignored
    }
    
    func collectSample() -> Float16 {
        guard enabled else {
            return 0.0
        }
        
        lastSample += impulseSinceLastSample
        
        impulseSinceLastSample = 0.0
        
        return lastSample
    }
    
    // MARK: - Channel specific functions
    
    private func currentNibbleToSample() -> Float16 {
        // First get the nibble
        
        var nibble = Int(wavePattern[Int(wavePatternNibble) / 2])
        
        if wavePatternNibble % 2 == 0 {
            // High nibble, get what we want
            
            nibble = nibble >> 4
        } else {
            // Low nibble, mask out the high stuff
            
            nibble = nibble & 0x0F
        }
        
        // Now we adjust for volume. It's done at this stage and not in floats
        
        nibble = switch actualVolume {
            case 0: nibble                      // Mute, but it's irrelevant as we handle it later
            case 1: nibble                      // 100% volume
            case 2: nibble >> 1                 // 50% volume
            case 3: nibble >> 2                 // 25% volume
            default: fatalError("Unreachable")
        }
    
        // We have our value, now we need to turn it into our float range.
        // The values are stange. 0 means "1.0" and 15 means "-1.0".
        
        var output = Float16(nibble) / 15.0     // 0 to 1.0 is 1.0 to -1.0
        output = output * 2.0                   // 0 to 2.0 is 1.0 to -1.0
        output = output - 1.0                   // -1.0 to 1.0 is 1.0 to -1.0
        output *= -1.0                          // Finally correct
        
        if actualVolume == 0 {
            // This is where we mute for real
            output = 0.0
        }
        
        return output
    }
    
    private func trigger() {
        // Tell the timer we were triggered
        
        lengthCounter.trigger()
        
        // Don't do anything else if we're disabled
        
        guard dacEnabled else {
            return
        }
        
        // Don't do anything else if we're disabled
        
        // Reset where to load the next nibble from but DON'T clear the buffer
        
        wavePatternNibble = 0   // Really starts at nibble 1, not 0. But we increment first thing so this is right
        
        periodCounter = 0
        
        volumeChanged = false
        
        // Enable the channel
        
        enabled = true
        
        // Reset the period
        
        periodCounter = period
        
        // This channel does not reset the output on trigger, it holds what was last until the next change
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
            case SC3_DAC_ENABLE:
                return dacEnableRegister
            case SC3_LENGTH:
                return lengthTimerRegister
            case SC3_OUTPUT_LEVEL:
                return outputLevelRegister
            case SC3_PERIOD_LOW:
                return periodLowRegister
            case SC3_PERIOD_HIGH_CONTROL:
                return periodHighAndControlRegister
            case WAVE_PATTERN_RANGE:
                let index = Int(address - WAVE_PATTERN_RANGE.lowerBound)
                let indexMatchesAPU = index == (wavePatternNibble >> 1)     // Convert nibbles to bytes
                
                // You can only read your byte if the audio hardware is reading it or channel 3 is off
                return (!enabled || indexMatchesAPU) ? wavePattern[index] : 0xFF
            default:
                return 0xFF     // This location doesn't exist. Nice try.
        }
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        switch address {
            case SC3_DAC_ENABLE:
                dacEnableRegister = value
            case SC3_LENGTH:
                lengthTimerRegister = value
            case SC3_OUTPUT_LEVEL:
                outputLevelRegister = value
            case SC3_PERIOD_LOW:
                periodLowRegister = value
            case SC3_PERIOD_HIGH_CONTROL:
                periodHighAndControlRegister = value
            case WAVE_PATTERN_RANGE:
                let index = Int(address - WAVE_PATTERN_RANGE.lowerBound)
                let indexMatchesAPU = index == (wavePatternNibble >> 1)     // Convert nibbles to bytes
                
                // You can only wruite your byte if the audio hardware is reading it or channel 3 is off
                if !enabled || indexMatchesAPU {
                    wavePattern[index] = value
                }
            default:
                return      // This location doesn't exist. Nice try.
        }
    }
}
