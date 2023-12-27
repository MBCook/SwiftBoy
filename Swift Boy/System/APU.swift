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

private let WRITABLE_WHILE_APU_DISABLED: [Address] = [0xFF11, 0xFF16, 0xFF1B, 0xFF20, 0xFF26]

private let AUDIO_CONTROL: Address = 0xFF26
private let SOUND_PANNING: Address = 0xFF25
private let MASTER_VOLUME: Address = 0xFF24

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
    
    private var channelOne: PulseWithPeriodSweep = PulseWithPeriodSweep(enableSweep: true)
    private var channelTwo: PulseWithPeriodSweep = PulseWithPeriodSweep(enableSweep: false)
    private var channelThree: WaveChannel = WaveChannel()
    private var channelFour: NoiseChannel = NoiseChannel()
    
    private var apuEnabled: Bool = false
    
    private var leftVolume: Register = 0
    private var rightVolume: Register = 0
    
    // MARK: - Registers
    
    private var audioControlRegister: Register {
        get {
            // Construct the return from if audio is enabled plus bits created from the channel control registers
            
            return (apuEnabled ? 0x80 : 0x00)
                    + 0x70      // All unused bits are returned as 1s
                    + (channelFour.isEnabled() ? 0x08 : 0x00)
                    + (channelThree.isEnabled() ? 0x04 : 0x00)
                    + (channelTwo.isEnabled() ? 0x02 : 0x00)
                    + (channelOne.isEnabled() ? 0x01 : 0x00)
        }
        set (value) {
            // Only bit 7 matters, all the rest are ignored on writes
            
            let turningOn = (value & 0x80) == 0x80
            
            apuEnabled = turningOn
            
            if (!turningOn) {
                // TODO: Clear stuff when this is turned off, see PAN docs
                
                apuDisabled()
            }
        }
    }
    
    private var soundPanningRegister: Register = 0
    
    private var masterVolumeRegister: Register {        // We're not going to bother with the cartridge sound/VIN since no one used that
        get {
            return (leftVolume << 4) + rightVolume
        }
        set(value) {
            leftVolume = (value & 0x70) >> 4    // Bits 4-6
            rightVolume = value & 0x07          // Last 3 bits
        }
    }
    
    // MARK: - Public functions
    
    func reset() {
        // Set things to the boot state
        
        channelOne.reset()
        channelTwo.reset()
        channelThree.reset()
        channelFour.reset()
        
        audioControlRegister = 0x77
        soundPanningRegister = 0xF3
        masterVolumeRegister = 0xF1
    }
    
    func apuDisabled() {
        // Clear all registers but the master control register
        
        channelOne.apuDisabled()
        channelTwo.apuDisabled()
        channelThree.apuDisabled()
        channelFour.apuDisabled()
        
        audioControlRegister = 0x00
        soundPanningRegister = 0x00
        masterVolumeRegister = 0x00
    }
    
    // MARK: - Tick functions
    
    func tick(_ ticks: Ticks) {
        // TODO: This
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
        guard apuEnabled || WRITABLE_WHILE_APU_DISABLED.contains(address) else {
            // Only the audio control register and the timer length registers can be written when the APU is off
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
