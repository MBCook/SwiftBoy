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

class WaveChannel: MemoryMappedDevice {
    private var enabled: Bool = false
    private var dacEnabled: Bool = false
    
    private var initialLengthTimer: Register = 0
    private var actualLengthTimer: Register = 0
    
    private var outputLevel: Register = 0
    private var period: UInt16 = 0
    private var periodLengthEnable: Bool = false
    
    private var wavePatternNibble: Register = 0
    private var wavePatternBuffer: Register = 0
    
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
            initialLengthTimer = value
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
                    + (periodLengthEnable ? 0x40 : 0x00)
                    + 0x3F                      // Next 3 aren't used, last 3 are read-only so return 1
        }
        set (value) {
            periodLengthEnable = value & 0x40 == 0x40
            
            let lowBits = period & 0x00FF
            let highBits = (UInt16(value) & 0x07) << 8  // We're setting the top 3 bits, bottom 8 come from existing value
            
            period = highBits + lowBits
            
            if (value & 0x80) == 0x80 {
                trigger()
            }
        }
    }
    
    private var wavePattern: [Register] = [Register](repeating: 0, count: 16)
    
    
    // MARK: - Public functions
    
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
    
    func isEnabled() -> Bool {
        return enabled
    }
    
    // MARK: - Tick functions
    
    func tick(_ ticks: Ticks) {
        // TODO: This
    }
    
    // MARK: - Channel specific functions
    
    func trigger() {
        guard dacEnabled else {
            return
        }
        
        // Reset where to load the next nibble from but DON'T clear the buffer
        
        wavePatternNibble = 0
        
        
        
        // TODO: Fill this in
    }
    
    func disable() {
        
    }
    
    func enableDAC() {
        guard !dacEnabled else {
            return
        }
        
        dacEnabled = true
    }
    
    func disableDAC() {
        guard dacEnabled else {
            return
        }
        
        disable()
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
