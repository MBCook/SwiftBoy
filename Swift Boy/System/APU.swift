//
//  APU.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/26/23.
//

import Foundation

private let CHANNEL_ONE_RANGE: ClosedRange<Address> = 0xFF10...0xFF14
private let CHANNEL_TWO_RANGE: ClosedRange<Address> = 0xFF16...0xFF19

private let SC3_DAC_ENABLE: Address = 0xFF1A                // SC3: Wave output
private let SC3_LENGTH: Address = 0xFF1B
private let SC3_OUTPUT_LEVEL: Address = 0xFF1C
private let SC3_PERIOD_LOW: Address = 0xFF1D
private let SC3_PERIOD_HIGH_CONTROL: Address = 0xFF1E
private let WAVE_PATTERN_RANGE: ClosedRange<Address> = 0xFF30...0xFF3F

private let SC4_LENGTH: Address = 0xFF20                    // SC4: Noise
private let SC4_VOLUME_ENVELOPE: Address = 0xFF21
private let SC4_FREQUENCY_RANDOMNESS: Address = 0xFF22
private let SC4_CONTROL: Address = 0xFF23

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

private enum Control {
    static let trigger: UInt8 = 0x80        // Also used for DAC enable for channel 3
    static let lengthEnable: UInt8 = 0x40
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

private enum WavePatternVolume {
    static let mute: UInt8 = 0x00
    static let full: UInt8 = 0x01
    static let half: UInt8 = 0x02
    static let quarter: UInt8 = 0x03
}

class APU: MemoryMappedDevice {
    // MARK: - Private variables
    
    private var channelOne: PulseWithPeriodSweep = PulseWithPeriodSweep(enableSweep: true)
    private var channelTwo: PulseWithPeriodSweep = PulseWithPeriodSweep(enableSweep: false)
    
    private var _threeEnabled: Bool = false
    private var _threeDACEnabled: Bool = false
    private var _threeInitialLengthTimer: Register = 0
    private var _threeActualLengthTimer: Register = 0
    private var _threeOutputLevel: Register = 0
    private var _threePeriod: UInt16 = 0
    private var _threePeriodLengthEnable: Bool = false
    
    private var _wavePatternNibbleIndex: Register = 0
    private var _wavePatternBuffer: Register = 0
    
    private var _fourInitialLengthTimer: Register = 0
    private var _fourActualLengthTimer: Register = 0
    private var _fourVolume: Register = 0
    private var _fourEnvelopeDirection: Bool = false
    private var _fourEnvelopePace: Register = 0
    private var _fourClockShift: Register = 0
    private var _fourLowLFSRWidth: Bool = false
    private var _fourClockDivider: Register = 0
    private var _fourLengthEnable: Bool = false
    private var _fourEnabled: Bool = false
    private var _fourDACEnabled: Bool = false
    private var _fourLFSR: UInt16 = 0
    
    private var _audioEnabled: Bool = false
    
    private var _leftVolume: Register = 0
    private var _rightVolume: Register = 0
    
    // MARK: - Registers
    
    private var threeDACEnable: Register {
        get {
            return _threeDACEnabled ? 0xFF : 0x7F   // High bit is if the DAC is enabled
        }
        set (value) {
            let enableDAC = value & 0x80 == 0x80
            
            if (enableDAC) {
                enableChannelThreeDAC()
            } else {
                disableChannelThreeDAC()
            }
        }
    }
    
    private var threeLengthTimer: Register {
        get {
            return 0xFF     // You can't read this back
        }
        set (value) {
            _threeInitialLengthTimer = value
        }
    }
    
    private var threeOutputLevel: Register {
        get {
            return 0b10011111 + (_threeOutputLevel << 5)    // All ignored bits are 1s
        }
        set (value) {
            _threeOutputLevel = (value & 0x7F) >> 5
        }
    }
    
    private var threePeriodLow: Register {
        get {
            return UInt8(_threePeriod & 0x00FF)
        }
        set (value) {
            _threePeriod = _threePeriod & 0xFF00 + UInt16(value)
        }
    }
    
    private var threePeriodHighAndControl: Register {
        get {
            return 0xF0                         // High bit is always set since it's not readable
                    + (_threePeriodLengthEnable ? 0x40 : 0x00)
                    + 0x38                      // These three bits aren't used either, so they're 1s
                    + UInt8(_threePeriod >> 8)    // Top 3 bits
        }
        set (value) {
            _threePeriodLengthEnable = value & 0x40 == 0x40
            
            let lowBits = _threePeriod & 0x00FF
            let highBits = (UInt16(value) & 0x07) << 8  // We're setting the top 3 bits, bottom 8 come from existing value
            
            _threePeriod = highBits + lowBits
            
            if (value & Control.trigger) == Control.trigger {
                triggerChannelThree()
            }
        }
    }
    
    private var wavePattern: [Register] = [Register](repeating: 0, count: 16)
    
    private var fourLength: Register {
        get {
            return 0xC0 + _fourInitialLengthTimer   // Top bits are always 1
        }
        set (value) {
            _fourInitialLengthTimer = value & 0x3F  // Skip the top two bits
        }
    }
    
    private var fourVolumeAndEnvelope: Register {
        get {
            return _fourVolume << 4          // TODO: Represents the volume the user TOLD us, not the CURRENT volume due to sweep
                    + (_fourEnvelopeDirection ? 0x08 : 0x00)
                    + _fourEnvelopePace
        }
        set (value) {
            _fourVolume = value >> 4
            _fourEnvelopeDirection = value & 0x08 == 0x08
            _fourEnvelopePace = value & 0x07
            
            let enableDAC = value & 0xF8 != 0   // If all the top bits are 0, the DAC is disabled
            
            if (enableDAC) {
                enableChannelFourDAC()
            } else {
                disableChannelFourDAC()
            }
        }
    }
    
    private var fourFrequencyAndRandomness: Register {
        get {
            return _fourClockShift << 4
                    + (_fourLowLFSRWidth ? 0x08 : 0x00)
                    + _fourClockDivider
        }
        set (value) {
            _fourClockShift = value >> 4
            _fourLowLFSRWidth = value & 0x08 == 0x08
            _fourClockDivider = value & 0x07
        }
    }
    
    
    private var fourControl: Register {
        get {
            return 0xF0                         // High bit is always set since it's not readable
                    + (_fourLengthEnable ? 0x40 : 0x00)
                    + 0x1F                      // Bottom bits aren't used either
        }
        set (value) {
            _fourLengthEnable = value & 0x40 == 0x40
            
            if (value & Control.trigger) == Control.trigger {
                triggerChannelFour()
            }
        }
    }
    
    private var audioControl: Register {
        get {
            // Construct the return from if audio is enabled plus bits created from the channel control registers
            
            return (_audioEnabled ? 0x80 : 0x00)
                    + 0x70      // All unused bits are returned as 1s
                    + (_fourEnabled ? 0x08 : 0x00)
                    + (_threeEnabled ? 0x04 : 0x00)
                    + (channelTwo.isEnabled() ? 0x02 : 0x00)
                    + (channelOne.isEnabled() ? 0x01 : 0x00)
        }
        set (value) {
            // Only bit 7 matters, all the rest are ignored on writes
            
            let turningOn = (value & 0x80) == 0x80
            
            _audioEnabled = turningOn
            
            if (!turningOn) {
                // TODO: Clear stuff when this is turned off, see PAN docs
            }
        }
    }
    
    private var soundPanning: Register = 0
    
    private var masterVolume: Register {        // We're not going to bother with the cartridge sound/VIN since no one used that
        get {
            return (_leftVolume << 4) + _rightVolume
        }
        set(value) {
            _leftVolume = (value & 0x70) >> 4    // Bits 4-6
            _rightVolume = value & 0x07          // Last 3 bits
        }
    }
    
    // MARK: - Public functions
    
    func reset() {
        // Set things to the boot state
        
        channelOne.reset()
        channelTwo.reset()
        
        threeDACEnable = 0x7F
        threeLengthTimer = 0xFF
        threeOutputLevel = 0x9F
        threePeriodLow = 0xFF
        threePeriodHighAndControl = 0xBF
        wavePattern = [Register](repeating: 0, count: 16)
        
        fourLength = 0xFF
        fourVolumeAndEnvelope = 0x00
        fourFrequencyAndRandomness = 0x00
        fourControl = 0xBF
        
        audioControl = 0x77
        soundPanning = 0xF3
        masterVolume = 0xF1
    }
    
    func apuDisabled() {
        // Clear all registers but the master control register
        
        channelOne.apuDisabled()
        channelTwo.apuDisabled()
        
        threeDACEnable = 0x00
        threeLengthTimer = 0x00
        threeOutputLevel = 0x00
        threePeriodLow = 0x00
        threePeriodHighAndControl = 0x00
        
        fourLength = 0x00
        fourVolumeAndEnvelope = 0x00
        fourFrequencyAndRandomness = 0x00
        fourControl = 0x00
        
        audioControl = 0x00
        soundPanning = 0x00
    }
    
    // MARK: - Tick functions
    
    func tick(_ ticks: Ticks) {
        // TODO: This
    }
    
    func tickNoise() -> VolumeLevel {
        let bitZero = _fourLFSR & 0x0001
        let bitOne = (_fourLFSR & 0x0002) >> 1
        let equals = bitZero == bitOne  // XNOR operation
        
        // If they're equal, set bit 15. It should always be clear before this due the the right shift.
        
        _fourLFSR = _fourLFSR + (equals ? 0x8000 : 0x0000)
        
        // Do the same to bit 7 if we're in low LFSR width mode (have to clear it just in case)
        
        if (_fourLowLFSRWidth) {
            _fourLFSR = (_fourLFSR & 0xFF7F) + (equals ? 0x0080 : 0x0000)
        }
        
        // Bit 0 will be the return (clear = silent, set = volume in channel 4 volume/envelope register)
        
        let output = _fourLFSR & 0x0001
        
        _fourLFSR >>= 1
        
        return output == 0x0001 ? _fourVolume : 0x00
    }
    
    // MARK: - Channel specific functions
    
    func triggerChannelThree() {
        guard _threeDACEnabled else {
            return
        }
        
        // Reset where to load the next nibble from but DON'T clear the buffer
        
        _wavePatternNibbleIndex = 0
        
        
        
        // TODO: Fill this in
    }
    
    func triggerChannelFour() {
        guard _fourDACEnabled else {
            return
        }
        
        // Reset the LFSR to all 1s
        
        _fourLFSR = 0xFFFF
        
        
        
        // TODO: Fill this in
    }
    
    func disableChannelThree() {
        
    }
    
    func disableChannelFour() {
        
    }
    
    func enableChannelThreeDAC() {
        guard !_threeDACEnabled else {
            return
        }
        
        _threeDACEnabled = true
    }
    
    func enableChannelFourDAC() {
        guard !_fourDACEnabled else {
            return
        }
        
        _fourDACEnabled = true
    }
    
    func disableChannelThreeDAC() {
        guard _threeDACEnabled else {
            return
        }
        
        disableChannelThree()
        _threeDACEnabled = false
    }
    
    func disableChannelFourDAC() {
        guard _fourDACEnabled else {
            return
        }
        
        disableChannelFour()
        _fourDACEnabled = false
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        switch address {
            case CHANNEL_ONE_RANGE:
                return channelOne.readRegister(address)
            case CHANNEL_TWO_RANGE:
                return channelTwo.readRegister(address)
            case SC3_DAC_ENABLE:
                return threeDACEnable
            case SC3_LENGTH:
                return threeLengthTimer
            case SC3_OUTPUT_LEVEL:
                return threeOutputLevel
            case SC3_PERIOD_LOW:
                return threePeriodLow
            case SC3_PERIOD_HIGH_CONTROL:
                return threePeriodHighAndControl
            case WAVE_PATTERN_RANGE:
                let index = Int(address - WAVE_PATTERN_RANGE.lowerBound)
                let indexMatchesAPU = index == (_wavePatternNibbleIndex >> 1)     // Convert nibbles to bytes
                
                // You can only read your byte if the audio hardware is reading it or channel 3 is off
                return (!_threeEnabled || indexMatchesAPU) ? wavePattern[index] : 0xFF
            case SC4_LENGTH:
                return fourLength
            case SC4_VOLUME_ENVELOPE:
                return fourVolumeAndEnvelope
            case SC4_FREQUENCY_RANDOMNESS:
                return fourFrequencyAndRandomness
            case SC4_CONTROL:
                return fourControl
            case AUDIO_CONTROL:
                return audioControl
            case SOUND_PANNING:
                return soundPanning
            case MASTER_VOLUME:
                return masterVolume
            default:
                return 0xFF     // This location doesn't exist. Nice try.
        }
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        switch address {
            case CHANNEL_ONE_RANGE:
                return channelOne.writeRegister(address, value)
            case CHANNEL_TWO_RANGE:
                return channelTwo.writeRegister(address, value)
            case SC3_DAC_ENABLE:
                threeDACEnable = value
            case SC3_LENGTH:
                threeLengthTimer = value
            case SC3_OUTPUT_LEVEL:
                threeOutputLevel = value
            case SC3_PERIOD_LOW:
                threePeriodLow = value
            case SC3_PERIOD_HIGH_CONTROL:
                threePeriodHighAndControl = value
            case WAVE_PATTERN_RANGE:
                let index = Int(address - WAVE_PATTERN_RANGE.lowerBound)
                let indexMatchesAPU = index == (_wavePatternNibbleIndex >> 1)     // Convert nibbles to bytes
                
                // You can only wruite your byte if the audio hardware is reading it or channel 3 is off
                if !_threeEnabled || indexMatchesAPU {
                    wavePattern[index] = value
                }
            case SC4_LENGTH:
                fourLength = value
            case SC4_VOLUME_ENVELOPE:
                fourVolumeAndEnvelope = value
            case SC4_FREQUENCY_RANDOMNESS:
                fourFrequencyAndRandomness = value
            case SC4_CONTROL:
                fourControl = value
            case AUDIO_CONTROL:
                audioControl = value
            case SOUND_PANNING:
                soundPanning = value
            case MASTER_VOLUME:
                masterVolume = value
            default:
                return      // This location doesn't exist. Nice try.
        }
    }
}
