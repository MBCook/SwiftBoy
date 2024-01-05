//
//  WaveChannel.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/27/23.
//

import Foundation

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
    
    private var outputLevel: Register = 0
    private var period: UInt16 = 0
    
    private var wavePatternNibble: Register = 0
    private var wavePatternBuffer: Register = 0
    
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
            return 0b10011111 + (outputLevel << 5)    // All ignored bits are 1s
        }
        set (value) {
            outputLevel = (value & 0x7F) >> 5
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
            
            if apu!.notOnLengthTickCycle() && !lengthCounter.enabled && shouldEnableLengthCounter {
                lengthCounter.extraDecrementBug(channelTriggered: triggering)
            }
            
            lengthCounter.enabled = shouldEnableLengthCounter
            period = period & 0x00FF + (UInt16(value) & 0x07) << 8      // Take the bottom 3 bits, put them in place on Period
            
            if triggering {
                trigger()
            }
        }
    }
    
    private var wavePattern: [Register] = [Register](repeating: 0, count: 16)
    
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
        wavePatternBuffer = 0
    }
    
    func disableAPU() {
        dacEnableRegister = 0x00
        lengthTimerRegister = 0x00
        outputLevelRegister = 0x00
        periodLowRegister = 0x00
        periodHighAndControlRegister = 0x00
        
        wavePatternNibble = 0
        wavePatternBuffer = 0
    }
    
    func disableChannel() {
        // TODO: This
        
        enabled = false
    }
    
    func isEnabled() -> Bool {
        return enabled
    }
    
    func tick(_ ticks: Ticks) {
        // TODO: This
    }
    
    func tickAPU() {
        // TODO: This
    }
    
    func tickLengthCounter() {
        lengthCounter.tickLengthCounter()
    }
    
    func tickVolumeEnvelope() {
        // TODO: This
    }
    
    // MARK: - Channel specific functions
    
    private func trigger() {
        guard dacEnabled else {
            return
        }
        
        // Reset where to load the next nibble from but DON'T clear the buffer
        
        wavePatternNibble = 0
        
        // Enable the channel
        
        enabled = true
        
        // Tell the timer we were triggered
        
        lengthCounter.trigger()
        
        // TODO: Fill this in
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
