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

private let DUTY_CYCLES: Array<Array<Float16>> = [
    [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, -1.0],
    [-1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, -1.0],
    [-1.0, 1.0, 1.0, 1.0, 1.0, -1.0, -1.0, -1.0],
    [-1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, 1.0]
]

class PulseWithPeriodSweep: AudioChannel {
    // MARK: - Private variables
    
    private var sweepEnabled: Bool = false
    private var sweepPace: Register = 0
    private var sweepPaceZero: Bool = false
    private var sweepDirection: SweepDirection = .addition
    private var sweepStep: Register = 0
    private var sweepPaceCountdown: UInt8 = 0               // Only reset on sweep/trigger, NOT PACE UPDATE
    private var negativeSweepSinceLastTrigger: Bool = false
    
    private var dutyCycle: Register = 0
    private var dutyStep: Register = 0
    private var firstCycleSinceRestart = true
    private var lastDutyCycleAdjustedForVolume: Float16 = 0.0

    private let lengthCounter: AudioLengthCounter
    
    private var initialVolume: Register = 0
    private var actualVolume: Register = 0
    
    private var envelopeDirection: Bool = false
    private var shadowEnvelopeDirection: Bool = false
    private var envelopePace: Register = 0
    private var shadowEnvelopePace: Register = 0
    private var envelopeTicks: Register = 0
    
    private var period: RegisterPair = 0
    private var shadowPeriod: RegisterPair = 0
    
    private var periodCounter: UInt16 = 0
    
    private var enabled: Bool = false
    private var dacEnabled: Bool = false
    
    private var channelSweeps = false
    
    private var lastSample: Float16 = 0
    private var impulseSinceLastSample: Float16 = 0
    
    var apu: APU? = nil
    
    // MARK: - Constructor
    
    init(channelSweeps: Bool) {
        self.lengthCounter = AudioLengthCounter(64)
        self.lengthCounter.disableChannel = { self.disableChannel() }
        
        self.channelSweeps = channelSweeps
    }
    
    // MARK: - Registers
    
    private var sweepRegister: Register {
        get {
            return 0x80     // High bit unused, return 1 in that bit
                    + (sweepPaceZero ? 0 : sweepPace << 4)
                    + (sweepDirection == .subtraction ? 0x08 : 0x00)
                    + sweepStep
        }
        set (value) {
            let oldSweep = sweepDirection
            
            sweepPace = (value & 0x7F) >> 4
            sweepDirection = (value & 0x08 == 0x08) ? .subtraction : .addition
            sweepStep = value & 0x07
            
            if sweepPace == 0 {
                sweepPace = 8           // The GameBoy keeps the timer running, but treats a 0 as an 8
                sweepPaceZero = true    // So we can keep track of the fact it was really zero
            } else {
                sweepPaceZero = false
            }
            
            if sweepDirection == .addition && oldSweep == .subtraction && negativeSweepSinceLastTrigger {
                // This causes the channel to be disabled for some reason
                disableChannel()
            }
        }
    }
    
    private var lengthAndDutyCycleRegister: Register {
        get {
            return dutyCycle << 6
                    + 0x3F  // The timer length is write only, so you get 1s back for the rest
        }
        set (value) {
            dutyCycle = value >> 6
            lengthCounter.initalLength = value & 0x3F
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
    
    // MARK: - AudioChannel protocol functions
    
    func reset() {
        // Set things to the boot state
        
        if channelSweeps {
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
        periodCounter = 0
        shadowPeriod = period
        sweepPaceCountdown = sweepPace
        
        firstCycleSinceRestart = true
        
        lastSample = 0.0
        impulseSinceLastSample = 0.0
        lastDutyCycleAdjustedForVolume = 0.0
        
        envelopeTicks = 0
        shadowEnvelopePace = envelopePace
        shadowEnvelopeDirection = envelopeDirection
    }
    
    func disableAPU() {        
        disableDAC()
        
        sweepRegister = 0x00
        lengthAndDutyCycleRegister = 0x00
        volumeAndEnvelopeRegister = 0x00
        periodLowRegister = 0x00
        periodHighAndControlRegister = 0x00
        
        dutyStep = 0
    }
    
    func disableChannel() {
        guard enabled else {
            return
        }
        
        enabled = false
        lastDutyCycleAdjustedForVolume = 0.0
    }
    
    func isEnabled() -> Bool {
        return enabled
    }
    
    func tick(_ ticks: Ticks) {
        guard enabled else {
            return
        }
        
        for _ in 1...ticks {
            periodCounter += 1
            
            if periodCounter >= 0x0800 {
                var lastDutyCycleOutput = lastDutyCycleAdjustedForVolume
                
                if firstCycleSinceRestart {
                    // The very first cycle is always no output, no matter what
                    
                    lastDutyCycleOutput = 0.0
                    firstCycleSinceRestart = false
                }
                
                // It overflowed. Reset it and tick the duty step.
                
                periodCounter = period
                dutyStep = (dutyStep + 1) % 8
                
                // Since we changed steps, collect impulse
                
                var newDutyCycleOutput = DUTY_CYCLES[Int(dutyCycle)][Int(dutyStep)]
                
                // Adjust for volume
                
                newDutyCycleOutput *= Float16(actualVolume) / 15.0
                
                // Calculate change and accrue it
                
                var impulseChange = newDutyCycleOutput - lastDutyCycleOutput
                
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
            
            actualVolume += UInt8(Int(actualVolume) + change)
            
            envelopeTicks = 0
        }
    }
    
    // MARK: - Public functions
    
    func tickSweep() {
        sweepPaceCountdown -= 1
        
        if sweepPaceCountdown == 0 {
            // Reset the counter
            
            sweepPaceCountdown = sweepPace
            
            if (sweepEnabled) {
                sweep(triggered: false)
            }
        }
    }
    
    func collectSample() -> Float16 {
        guard enabled else {
            return 0.0
        }
        
        lastSample += impulseSinceLastSample
        
        impulseSinceLastSample = 0.0
        
        return lastSample
    }
    
    // MARK: - Private functions
    
    private func calculateNextPeriod() -> RegisterPair {
        let denominator: RegisterPair = 1 << sweepStep      // 2 ^ sweepStep
        let fraction: RegisterPair = shadowPeriod / denominator
        
        if sweepDirection == .addition {
            return shadowPeriod + fraction
        } else {
            return shadowPeriod - fraction
        }
    }
    
    private func sweep(triggered: Bool) {
        // The logic for if we should calculate or if we should apply is touch
        
        let stepExists = sweepStep > 0
        let shouldCalculate = (triggered && stepExists) ||
                                (!triggered && !sweepPaceZero)
        let shouldApply = !triggered && !sweepPaceZero && stepExists
        
        guard shouldCalculate else {
            return
        }
        
        if sweepDirection == .subtraction {
            negativeSweepSinceLastTrigger = true
        }
        
        // Figure out the new period, handle it as appropriate
        
        let newPeriod = calculateNextPeriod()
        
        if newPeriod > 0x07FF {
            // If we would overflow, don't, disable the channel instead
            disableChannel()
        } else if shouldApply {
            period = newPeriod      // We swept, update the real period
            shadowPeriod = period   // And reload the shadown period
            
            // Figure out what the next period would be. If it will overflow, stop now
            
            if calculateNextPeriod() > 0x07FF {
                disableChannel()
            }
        }
    }
    
    private func trigger() {
        // Tell the timer we were triggered
        
        lengthCounter.trigger()
        
        // Don't do anything else if we're disabled
        
        guard dacEnabled else {
            return
        }
        
        // Enable the channel
        
        enabled = true
        
        // Note: The duty step IS NOT reset on trigger

        actualVolume = initialVolume
        envelopeTicks = 0
        shadowEnvelopePace = envelopePace
        shadowEnvelopeDirection = envelopeDirection
        
        // Sweep stuff
        
        if channelSweeps {
            negativeSweepSinceLastTrigger = false
            shadowPeriod = period
            sweepPaceCountdown = sweepPace
            sweepEnabled = !sweepPaceZero || sweepStep > 0
            
            if sweepStep > 0 {
                sweep(triggered: true)
            }
        }
        
        // Update the period counter from the period (keeping the loweset two bits becuase GB does)
        
        periodCounter = (period & 0xFFFC) + (periodCounter & 0x0003)
        
        // Sampling stuff
        
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
        
        // Disabling the DAC also disables the channel
        
        disableChannel()
        
        dacEnabled = false
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        if channelSweeps {
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
        if channelSweeps {
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

