//
//  PulseWithPeriodSweep.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/27/23.
//

import Foundation

// This is used for channel 1 (with sweep) and 2 (without)

private let SC1_SWEEP: Address = 0xFF10                     // SC1: Pluse and period sweep
private let SC1_LENGTH_DUTY: Address = 0xFF11
private let SC1_VOLUME_ENVELOPE: Address = 0xFF12
private let SC1_PERIOD_LOW: Address = 0xFF13
private let SC1_PERIOD_HIGH_CONTROL: Address = 0xFF14

private let SC2_LENGTH_DUTY: Address = 0xFF16               // SC2: Pulse
private let SC2_VOLUME_ENVELOPE: Address = 0xFF17
private let SC2_PERIOD_LOW: Address = 0xFF18
private let SC2_PERIOD_HIGH_CONTROL: Address = 0xFF19

private enum SweepDirection {
    case addition
    case subtraction
}

class PulseWithPeriodSweep: AudioChannel {
    // MARK: - Private variables
    
    private var sweepPace: Register = 0
    private var sweepDirection: SweepDirection = .addition
    private var sweepStep: Register = 0
    
    private var dutyCycle: Register = 0
    private var dutyStep: Register = 0
    private var awaitingFirstTrigger: Bool = false
    private var onFirstTrigger: Bool = false

    private let lengthCounter: AudioLengthCounter
    
    private var volume: Register = 0
    
    private var envelopeDirection: Bool = false
    private var envelopePace: Register = 0
    
    private var period: RegisterPair = 0
    
    private var enabled: Bool = false
    private var dacEnabled: Bool = false
    
    private var enableSweep = false
    
    // MARK: - Constructor
    
    init(enableSweep: Bool) {
        self.lengthCounter = AudioLengthCounter(64)
        self.lengthCounter.disableChannel = { self.disableChannel() }
        self.lengthCounter.channelNumber = enableSweep ? 1 : 2
        
        self.enableSweep = enableSweep
    }
    
    // MARK: - Registers
    
    private var sweepRegister: Register {
        get {
            return 0x80     // High bit unused, return 1 in that bit
                    + sweepPace << 4
                    + (sweepDirection == .subtraction ? 0x08 : 0x00)
                    + sweepStep
        }
        set (value) {
            sweepPace = (value & 0x7F) >> 4
            sweepDirection = (value & 0x08 == 0x08) ? .subtraction : .addition
            sweepStep = value & 0x07
            
            // TODO: If sweep pace is set to 0, there is special handling needed
        }
    }
    
    private var lengthAndDutyCycleRegister: Register {
        get {
            return dutyCycle << 6
                    + 0x3F  // The timer length is write only, so you get 1s back for the rest
        }
        set (value) {
            dutyCycle = value >> 6
            
            if enableSweep {
                print("\tChannel 1 initial length being set to", value & 0x3F)
            } else {
                print("\tChannel 2 initial length being set to", value & 0x3F)
            }
            
            lengthCounter.initalLength = value & 0x3F
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
            if value & 0x40 == 0x40 {
                if enableSweep {
                    print("\tChannel 1 length counter being enabled")
                } else {
                    print("\tChannel 2 length counter being enabled")
                }
            }
            
            lengthCounter.enabled = value & 0x40 == 0x40
            period = period & 0x00FF + (UInt16(value) & 0x07) << 8      // Take the bottom 3 bits, put them in place on Period
            
            if value & 0x80 == 0x80 {
                trigger()
            }
        }
    }
    
    // MARK: - AudioChannel protocol functions
    
    func reset() {
        // Set things to the boot state
        
        if enableSweep {
            // Channel 1
            
            sweepRegister = 0x80
            lengthAndDutyCycleRegister = 0xBF
            volumeAndEnvelopeRegister = 0xF3
            periodLowRegister = 0xFF
            periodHighAndControlRegister = 0xBF
        } else {
            // Channel 2
            
            sweepRegister = 0x00
            lengthAndDutyCycleRegister = 0x3F
            volumeAndEnvelopeRegister = 0x00
            periodLowRegister = 0xFF
            periodHighAndControlRegister = 0xBF
        }
        
        dutyStep = 0
        
        awaitingFirstTrigger = true
        onFirstTrigger = false
    }
    
    func disableAPU() {        
        disableDAC()
        
        sweepRegister = 0x00
        lengthAndDutyCycleRegister = 0x00
        volumeAndEnvelopeRegister = 0x00
        periodLowRegister = 0x00
        periodHighAndControlRegister = 0x00
        
        dutyStep = 0
        
        awaitingFirstTrigger = true
        onFirstTrigger = false
    }
    
    func disableChannel() {
        guard enabled else {
            if enableSweep {
                print("\tChannel 1 was already disabled, ignoring")
            } else {
                print("\tChannel 2 was already disabled, ignoring")
            }
            
            return
        }
        
        // TODO: This
        
        if enableSweep {
            print("\tChannel 1 being disabled")
        } else {
            print("\tChannel 2 being disabled")
        }
        
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
    
    // MARK: - Public functions
    
    func tickSweep() {
        // TODO: This
    }
    
    // MARK: - Private functions
    
    private func trigger() {
        guard dacEnabled else {
            return
        }
        
        if enableSweep {
            print("\tChannel 1 triggered")
        } else {
            print("\tChannel 2 triggered")
        }
        
        // Track if we've been triggered at least once
        
        if awaitingFirstTrigger {
            // We got our first trigger!
            
            awaitingFirstTrigger = false
            onFirstTrigger = true
        }
        
        // Enable the channel
        
        enabled = true
        
        // Tell the timer we were triggered
        
        lengthCounter.trigger()
        
        // Reset the duty step index
        
        dutyStep = 0
        
        // TODO: Reload frequency timer
        // TODO: Reload envelope timer
        // TODO: Reload volume
        // TODO: Sweep stuff
        
    }
    
    private func enableDAC() {
        guard !dacEnabled else {
            return
        }
        
        if enableSweep {
            print("\tChannel 1 DAC enabled")
        } else {
            print("\tChannel 2 DAC enabled")
        }
        
        dacEnabled = true
    }
    
    private func disableDAC() {
        guard dacEnabled else {
            return
        }
        
        if enableSweep {
            print("\tChannel 1 DAC disabled")
        } else {
            print("\tChannel 2 DAC disabled")
        }
        
        // Disabling the DAC also disables the channel
        
        disableChannel()
        
        dacEnabled = false
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        if enableSweep {
            // We're at channel 1 addresses
            
            switch address {
            case SC1_SWEEP:
                return sweepRegister
            case SC1_LENGTH_DUTY:
                return lengthAndDutyCycleRegister
            case SC1_VOLUME_ENVELOPE:
                return volumeAndEnvelopeRegister
            case SC1_PERIOD_LOW:
                return periodLowRegister
            case SC1_PERIOD_HIGH_CONTROL:
                return periodHighAndControlRegister
            default:
                return 0xFF     // This location doesn't exist. Nice try.
            }
        } else {
            // We're at channel 2 addresses
            
            switch address {
            case SC2_LENGTH_DUTY:
                return lengthAndDutyCycleRegister
            case SC2_VOLUME_ENVELOPE:
                return volumeAndEnvelopeRegister
            case SC2_PERIOD_LOW:
                return periodLowRegister
            case SC2_PERIOD_HIGH_CONTROL:
                return periodHighAndControlRegister
            default:
                return 0xFF     // This location doesn't exist. Nice try.
            }
        }
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        if enableSweep {
            // We're at channel 1 addresses
            
            switch address {
            case SC1_SWEEP:
                sweepRegister = value
            case SC1_LENGTH_DUTY:
                lengthAndDutyCycleRegister = value
            case SC1_VOLUME_ENVELOPE:
                volumeAndEnvelopeRegister = value
            case SC1_PERIOD_LOW:
                periodLowRegister = value
            case SC1_PERIOD_HIGH_CONTROL:
                periodHighAndControlRegister = value
            default:
                return          // This location doesn't exist. Nice try.
            }
        } else {
            // We're at channel 2 addresses
            
            switch address {
            case SC2_LENGTH_DUTY:
                lengthAndDutyCycleRegister = value
            case SC2_VOLUME_ENVELOPE:
                volumeAndEnvelopeRegister = value
            case SC2_PERIOD_LOW:
                periodLowRegister = value
            case SC2_PERIOD_HIGH_CONTROL:
                periodHighAndControlRegister = value
            default:
                return          // This location doesn't exist. Nice try.
            }
        }
    }
}
