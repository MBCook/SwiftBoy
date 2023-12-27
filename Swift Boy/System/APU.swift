//
//  APU.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/26/23.
//

import Foundation

private let SC1_SWEEP: Address = 0xFF10                     // SC1: Pluse and period sweep
private let SC1_LENGTH_DUTY: Address = 0xFF11
private let SC1_VOLUME_ENVELOPE: Address = 0xFF12
private let SC1_PERIOD_LOW: Address = 0xFF13
private let SC1_PERIOD_HIGH_CONTROL: Address = 0xFF14

private let SC2_LENGTH_DUTY: Address = 0xFF16               // SC2: Pulse
private let SC2_VOLUME_ENVELOPE: Address = 0xFF17
private let SC2_PERIOD_LOW: Address = 0xFF18
private let SC2_PERIOD_HIGH_CONTROL: Address = 0xFF19

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

private enum SweepDirection {
    case addition
    case subtraction
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
    private var _oneSweepPace: Register = 0
    private var _oneSweepDirection: SweepDirection = .addition
    private var _oneSweepStep: Register = 0
    private var oneSweep:  Register {
        get {
            return 0x80     // High bit unused, return 1 in that bit
                    + _oneSweepPace << 4
                    + (_oneSweepDirection == .subtraction ? 0x08 : 0x00)
                    + _oneSweepStep
        }
        set (value) {
            _oneSweepPace = (value & 0x7F) >> 4
            _oneSweepDirection = (value & 0x08 == 0x08) ? .subtraction : .addition
            _oneSweepStep = value & 0x07
            
            // TODO: If sweep pace is set to 0, there is special handling needed
        }
    }
    
    private var _oneDutyCycle: Register = 0
    private var _oneLengthTimer: Register = 0
    private var oneLengthAndDutyCycle: Register {
        get {
            return _oneDutyCycle << 6
                    + 0x3F  // The timer length is write only, so you get 1s back for the rest
        }
        set (value) {
            _oneDutyCycle = value >> 6
            _oneLengthTimer = value & 0x3F
        }
    }
    
    private var _oneVolume: Register = 0
    private var _oneEnvelopeDirection: Bool = false
    private var _oneEnvelopePace: Register = 0
    private var oneVolumeAndEnvelope: Register {
        get {
            return _oneVolume << 4          // TODO: Represents the volume the user TOLD us, not the CURRENT volume due to sweep
                    + (_oneEnvelopeDirection ? 0x08 : 0x00)
                    + _oneEnvelopePace
        }
        set (value) {
            _oneVolume = value >> 4
            _oneEnvelopeDirection = value & 0x08 == 0x08
            _oneEnvelopePace = value & 0x07
            
            _oneEnabled = value & 0xF8 != 0     // If you set the volume to 0 and direction 0, you've disabled the channel!
        }
    }
    
    private var _onePeriod: UInt16 = 0
    private var onePeriodLow: Register {
        get {
            return UInt8(_onePeriod & 0x00FF)
        }
        set (value) {
            _onePeriod = _onePeriod & 0xFF00 + UInt16(value)
        }
    }
    
    private var _onePeriodLengthEnable: Bool = false
    private var onePeriodHighAndControl: Register {
        get {
            return 0xF0                         // High bit is always set since it's not readable
                    + (_onePeriodLengthEnable ? 0x40 : 0x00)
                    + 0x38                      // These three bits aren't used either, so they're 1s
                    + UInt8(_onePeriod >> 8)    // Top 3 bits
        }
        set (value) {
            // TODO: Check for tigger!
            _onePeriodLengthEnable = value & 0x40 == 0x40
            _onePeriod = _onePeriod & 0x00FF + (UInt16(value) & 0x07) << 8      // Take the bottom 3 bits, put them in place on _onePeriod
        }
    }
    
    private var _oneEnabled: Bool = false
    
    private var _twoDutyCycle: Register = 0
    private var _twoLengthTimer: Register = 0
    private var twoLengthAndDutyCycle: Register {
        get {
            return _twoDutyCycle << 6
                    + 0x3F  // The timer length is write only, so you get 1s back for the rest
        }
        set (value) {
            _twoDutyCycle = value >> 6
            _twoLengthTimer = value & 0x3F
        }
    }
    
    private var _twoVolume: Register = 0
    private var _twoEnvelopeDirection: Bool = false
    private var _twoEnvelopePace: Register = 0
    private var twoVolumeAndEnvelope: Register {
        get {
            return _twoVolume << 4          // TODO: Represents the volume the user TOLD us, not the CURRENT volume due to sweep
                    + (_twoEnvelopeDirection ? 0x08 : 0x00)
                    + _twoEnvelopePace
        }
        set (value) {
            _twoVolume = value >> 4
            _twoEnvelopeDirection = value & 0x08 == 0x08
            _twoEnvelopePace = value & 0x07
            
            _twoEnabled = value & 0xF8 != 0     // If you set the volume to 0 and direction 0, you've disabled the channel!
        }
    }
    
    private var _twoPeriod: UInt16 = 0
    private var twoPeriodLow: Register {
        get {
            return UInt8(_twoPeriod & 0x00FF)
        }
        set (value) {
            _twoPeriod = _twoPeriod & 0xFF00 + UInt16(value)
        }
    }
    
    private var _twoPeriodLengthEnable: Bool = false
    private var twoPeriodHighAndControl: Register {
        get {
            return 0xF0                         // High bit is always set since it's not readable
                    + (_twoPeriodLengthEnable ? 0x40 : 0x00)
                    + 0x38                      // These three bits aren't used either, so they're 1s
                    + UInt8(_twoPeriod >> 8)    // Top 3 bits
        }
        set (value) {
            // TODO: Check for tigger!
            _twoPeriodLengthEnable = value & 0x40 == 0x40
            _twoPeriod = _twoPeriod & 0x00FF + (UInt16(value) & 0x07) << 8      // Take the bottom 3 bits, put them in place on _twoPeriod
        }
    }
    
    private var _twoEnabled: Bool = false
    
    private var _threeEnabled: Bool = false
    private var threeDACEnable: Register {
        get {
            return _threeEnabled ? 0xFF : 0x7F      // High bit is if we're enabled, the rest are always 1
        }
        set (value) {
            _threeEnabled = value & 0x80 == 0x80
        }
    }
    
    private var _threeLengthTimer: Register = 0
    private var threeLengthTimer: Register {
        get {
            return 0xFF     // You can't read this back
        }
        set (value) {
            _threeLengthTimer = value
        }
    }
    
    private var _threeOutputLevel: Register = 0
    private var threeOutputLevel: Register {
        get {
            return 0b10011111 + (_threeOutputLevel << 5)    // All ignored bits are 1s
        }
        set (value) {
            _threeOutputLevel = (value & 0x7F) >> 5
        }
    }
    
    private var _threePeriod: UInt16 = 0
    private var threePeriodLow: Register {
        get {
            return UInt8(_threePeriod & 0x00FF)
        }
        set (value) {
            _threePeriod = _threePeriod & 0xFF00 + UInt16(value)
        }
    }
    
    private var _threePeriodLengthEnable: Bool = false
    private var threePeriodHighAndControl: Register {
        get {
            return 0xF0                         // High bit is always set since it's not readable
                    + (_threePeriodLengthEnable ? 0x40 : 0x00)
                    + 0x38                      // These three bits aren't used either, so they're 1s
                    + UInt8(_threePeriod >> 8)    // Top 3 bits
        }
        set (value) {
            // TODO: Check for tigger!
            _threePeriodLengthEnable = value & 0x40 == 0x40
            _threePeriod = _threePeriod & 0x00FF + (UInt16(value) & 0x07) << 8      // Take the bottom 3 bits, put them in place on _threePeriod
        }
    }
    
    private var _wavePatternNibbleIndex: Register = 0
    private var wavePattern: [Register] = [Register](repeating: 0, count: 16)   // TODO: Special access rules for reading!
    
    private var _fourLength: Register = 0
    private var fourLength: Register {
        get {
            return 0xC0 + _fourLength   // Top bits are always 1
        }
        set (value) {
            _fourLength = value & 0x3F  // Skip the top two bits
        }
    }
    
    private var _fourVolume: Register = 0
    private var _fourEnvelopeDirection: Bool = false
    private var _fourEnvelopePace: Register = 0
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
            
            _fourEnabled = value & 0xF8 != 0     // If you set the volume to 0 and direction 0, you've disabled the channel!
        }
    }
    private var _fourClockShift: Register = 0
    private var _fourLowLFSRWidth: Bool = false
    private var _fourClockDivider: Register = 0
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
    
    private var _fourLengthEnable: Bool = false
    private var fourControl: Register {
        get {
            return 0xF0                         // High bit is always set since it's not readable
                    + (_fourLengthEnable ? 0x40 : 0x00)
                    + 0x1F                      // Bottom bits aren't used either
        }
        set (value) {
            // TODO: Check for tigger!
            _fourLengthEnable = value & 0x40 == 0x40
        }
    }
    
    private var _fourEnabled: Bool = false
    private var _fourLFSR: UInt16 = 0
    
    private var _audioEnabled: Bool = false
    private var audioControl: Register {
        get {
            // Construct the return from if audio is enabled plus bits created from the channel control registers
            
            return (_audioEnabled ? 0x80 : 0x00)
                    + 0x70      // All unused bits are returned as 1s
                    + (_fourEnabled ? 0x08 : 0x00)
                    + (_threeEnabled ? 0x04 : 0x00)
                    + (_twoEnabled ? 0x02 : 0x00)
                    + (_oneEnabled ? 0x01 : 0x00)
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
    
    private var _leftVolume: Register = 0
    private var _rightVolume: Register = 0
    private var masterVolume: Register {        // We're not going to bother with the cartridge sound/VIN since no one used that
        get {
            return (_leftVolume << 4) + _rightVolume
        }
        set(value) {
            _leftVolume = (value & 0x70) >> 4    // Bits 4-6
            _rightVolume = value & 0x07          // Last 3 bits
        }
    }
    
    func reset() {
        // Set things to the boot state
        
        oneSweep = 0x80
        oneLengthAndDutyCycle = 0xBF
        oneVolumeAndEnvelope = 0xF3
        onePeriodLow = 0xFF
        onePeriodHighAndControl = 0xBF
        
        twoLengthAndDutyCycle = 0x3F
        twoVolumeAndEnvelope = 0x00
        twoPeriodLow = 0xFF
        twoPeriodHighAndControl = 0xBF
        
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
    
    func clearAllButMaster() {
        // Clear all registers but the master control register
        
        oneSweep = 0x00
        oneLengthAndDutyCycle = 0x00
        oneVolumeAndEnvelope = 0x00
        onePeriodLow = 0x00
        onePeriodHighAndControl = 0x00
        
        twoLengthAndDutyCycle = 0x00
        twoVolumeAndEnvelope = 0x00
        twoPeriodLow = 0x00
        twoPeriodHighAndControl = 0x00
        
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
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        switch address {
        case SC1_SWEEP:
            return oneSweep
        case SC1_LENGTH_DUTY:
            return oneLengthAndDutyCycle
        case SC1_VOLUME_ENVELOPE:
            return oneVolumeAndEnvelope
        case SC1_PERIOD_LOW:
            return onePeriodLow
        case SC1_PERIOD_HIGH_CONTROL:
            return onePeriodHighAndControl
        case SC2_LENGTH_DUTY:
            return twoLengthAndDutyCycle
        case SC2_VOLUME_ENVELOPE:
            return twoVolumeAndEnvelope
        case SC2_PERIOD_LOW:
            return twoPeriodLow
        case SC2_PERIOD_HIGH_CONTROL:
            return twoPeriodHighAndControl
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
        case SC1_SWEEP:
            oneSweep = value
        case SC1_LENGTH_DUTY:
            oneLengthAndDutyCycle = value
        case SC1_VOLUME_ENVELOPE:
            oneVolumeAndEnvelope = value
        case SC1_PERIOD_LOW:
            onePeriodLow = value
        case SC1_PERIOD_HIGH_CONTROL:
            onePeriodHighAndControl = value
        case SC2_LENGTH_DUTY:
            twoLengthAndDutyCycle = value
        case SC2_VOLUME_ENVELOPE:
            twoVolumeAndEnvelope = value
        case SC2_PERIOD_LOW:
            twoPeriodLow = value
        case SC2_PERIOD_HIGH_CONTROL:
            twoPeriodHighAndControl = value
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
