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

class NoiseChannel: MemoryMappedDevice {
    // MARK: - Private variables
    
    private var initialLengthTimer: Register = 0
    private var actualLengthTimer: Register = 0
    
    private var volume: Register = 0
    private var envelopeDirection: Bool = false
    private var envelopePace: Register = 0
    
    private var clockShift: Register = 0
    private var clockDivider: Register = 0
    
    private var lengthEnable: Bool = false
    
    private var enabled: Bool = false
    private var dacEnabled: Bool = false
    
    private var lowLFSRWidth: Bool = false
    private var lfsr: RegisterPair = 0
    
    // MARK: - Registers
    
    private var lengthRegister: Register {
        get {
            return 0xC0 + initialLengthTimer   // Top bits are always 1
        }
        set (value) {
            initialLengthTimer = value & 0x3F  // Skip the top two bits
        }
    }
    
    private var volumeAndEnvelopeRegister: Register {
        get {
            return volume << 4          // TODO: Represents the volume the user TOLD us, not the CURRENT volume due to sweep
                    + (envelopeDirection ? 0x08 : 0x00)
                    + envelopePace
        }
        set (value) {
            volume = value >> 4
            envelopeDirection = value & 0x08 == 0x08
            envelopePace = value & 0x07
            
            let enableDACSetting = value & 0xF8 != 0   // If all the top bits are 0, the DAC is disabled
            
            if (enableDACSetting) {
                enableDAC()
            } else {
                disableDAC()
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
            return 0xF0                         // High bit is always set since it's not readable
                    + (lengthEnable ? 0x40 : 0x00)
                    + 0x1F                      // Bottom bits aren't used either
        }
        set (value) {
            lengthEnable = value & 0x40 == 0x40
            
            if (value & 0x80) == 0x80 {
                trigger()
            }
        }
    }
    
    // MARK: - Public functions
    
    func reset() {
        // Set things to the boot state
        
        lengthRegister = 0xFF
        volumeAndEnvelopeRegister = 0x00
        frequencyAndRandomnessRegister = 0x00
        controlRegister = 0xBF
    }
    
    func apuDisabled() {
        lengthRegister = 0x00
        volumeAndEnvelopeRegister = 0x00
        frequencyAndRandomnessRegister = 0x00
        controlRegister = 0x00
    }
    
    func isEnabled() -> Bool {
        return enabled
    }
    
    // MARK: - Tick functions
    
    func tick(_ ticks: Ticks) {
        // TODO: This
    }
    
    func tickNoise() -> VolumeLevel {
        let bitZero = lfsr & 0x0001
        let bitOne = (lfsr & 0x0002) >> 1
        let equals = bitZero == bitOne  // XNOR operation
        
        // If they're equal, set bit 15. It should always be clear before this due the the right shift.
        
        lfsr = lfsr + (equals ? 0x8000 : 0x0000)
        
        // Do the same to bit 7 if we're in low LFSR width mode (have to clear it just in case)
        
        if (lowLFSRWidth) {
            lfsr = (lfsr & 0xFF7F) + (equals ? 0x0080 : 0x0000)
        }
        
        // Bit 0 will be the return (clear = silent, set = volume in channel 4 volume/envelope register)
        
        let output = lfsr & 0x0001
        
        lfsr >>= 1
        
        return output == 0x0001 ? volume : 0x00
    }
    
    // MARK: - Channel specific functions
    
    func trigger() {
        guard dacEnabled else {
            return
        }
        
        // Reset the LFSR to all 1s
        
        lfsr = 0xFFFF
        
        // TODO: Fill this in
    }
    
    func disableChannelFour() {
        
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
        
        disableChannelFour()
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
