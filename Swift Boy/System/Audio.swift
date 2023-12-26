//
//  Audio.swift
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

private let DIRECTION_BIT: UInt8 = 0x08
private let DIRECTION_ADDITION: UInt8 = 0
private let DIRECTION_SUBTRACTION: UInt8 = 1
private let LFSR_WIDTH: UInt8 = 0x08

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

private let TWELVE_POINT_FIVE_DUTY_CYCLE: [UInt8] = [0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x00,
                                                     0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x00]
private let TWENTY_FIVE_DUTY_CYCLE: [UInt8] = [0x00, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x00,
                                               0x00, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x00]
private let FIFTY_DUTY_CYCLE: [UInt8] = [0x00, 0x0F, 0x0F, 0x0F, 0x0F, 0x00, 0x00, 0x00,
                                         0x00, 0x0F, 0x0F, 0x0F, 0x0F, 0x00, 0x00, 0x00]
private let SEVENTY_FIVE_DUTY_CYCLE: [UInt8] = [0x0F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F,
                                                0x0F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F]

private enum WavePatternVolume {
    static let mute: UInt8 = 0x00
    static let full: UInt8 = 0x01
    static let half: UInt8 = 0x02
    static let quarter: UInt8 = 0x03
}

class Audio: MemoryMappedDevice {
    private var oneSweep: Register = 0
    private var oneLengthAndDutyCycle: Register = 0
    private var oneVolumeAndEnvelop: Register = 0
    private var onePeriodLow: Register = 0
    private var onePeriodAndHighControl: Register = 0
    
    private var twoLengthAndDutyCycle: Register = 0
    private var twoVolumeAndEnvelop: Register = 0
    private var twoPeriodLow: Register = 0
    private var twoPeriodAndHighControl: Register = 0
    
    private var threeDACEnable: Register = 0
    private var threeLengthTimer: Register = 0
    private var threeOutputLevel: Register = 0
    private var threePeriodLow: Register = 0
    private var threePeriodHighAndControl: Register = 0
    private var wavePattern: [Register] = [Register](repeating: 0, count: 16)
    
    private var fourLength: Register = 0
    private var fourVolumeAndEnvelope: Register = 0
    private var fourFrequencyAndRandomness: Register = 0
    private var fourControl: Register = 0
    
    private var audioEnabled: Bool = false
    private var audioControl: Register {
        get {
            // Construct the return from if audio is enabled plus bits created from the channel control registers
            
            return (audioEnabled ? 0x80 : 0x00)
                    + 0x70      // All unused bits are returned as 1s
                    + (onePeriodAndHighControl & Control.trigger == Control.trigger ? 0x01 : 0x00)
                    + (twoPeriodAndHighControl & Control.trigger == Control.trigger ? 0x02 : 0x00)
                    + (threeDACEnable & Control.trigger == Control.trigger ? 0x04 : 0x00)
                    + (fourControl & Control.trigger == Control.trigger ? 0x08 : 0x00)
        }
        set (value) {
            let turningOn = (value & 0x80) == 0x80
            
            audioEnabled = turningOn
            
            if (!turningOn) {
                // TODO: Clear stuff when this is turned off, see PAN docs
            }
        }
    }
    
    private var soundPanning: Register = 0
    
    private var leftVolume: Register = 0
    private var rightVolume: Register = 0
    private var masterVolume: Register {        // We're not going to bother with the cartridge sound/VIN since no one used that
        get {
            return (leftVolume << 4) + rightVolume
        }
        set(value) {
            leftVolume = (value & 0x70) >> 4    // Bits 4-6
            rightVolume = value & 0x07          // Last 3 bits
        }
    }
    
    func reset() {
        // Set things to the boot state
        
        oneSweep = 0x80
        oneLengthAndDutyCycle = 0xBF
        oneVolumeAndEnvelop = 0xF3
        onePeriodLow = 0xFF
        onePeriodAndHighControl = 0xBF
        
        twoLengthAndDutyCycle = 0x3F
        twoVolumeAndEnvelop = 0x00
        twoPeriodLow = 0xFF
        twoPeriodAndHighControl = 0xBF
        
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
    
    func tick(_ ticks: Ticks) {
        // TODO: This
    }
    
    func clearAllButMaster() {
        // Clear all registers but the master control register
        
        oneSweep = 0x00
        oneLengthAndDutyCycle = 0x00
        oneVolumeAndEnvelop = 0x00
        onePeriodLow = 0x00
        onePeriodAndHighControl = 0x00
        
        twoLengthAndDutyCycle = 0x00
        twoVolumeAndEnvelop = 0x00
        twoPeriodLow = 0x00
        twoPeriodAndHighControl = 0x00
        
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
    
    func readRegister(_ address: Address) -> UInt8 {
        // TODO: This
        return 0
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        // TODO: This
    }
}
