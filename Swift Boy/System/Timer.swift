//
//  Timer.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/7/22.
//

import Foundation

enum TimerControlBits {
    static let enabled: Bitmask = 0x04
    static let clockDivIs1024: Bitmask = 0x00   // 4096 hz
    static let clockDivIs16: Bitmask = 0x01     // 262144 hz
    static let clockDivIs64: Bitmask = 0x02     // 65536 hz
    static let clockDivIs256: Bitmask = 0x03    // 16384 hz
}

class Timer: MemoryMappedDevice {
    // MARK: - Our private data
    
    private var lastDivRegisterIncrement: UInt16 = 0        // The last time the DIV register was incremented
    private var lastTimerRegisterIncrement: UInt16 = 0      // The last time the counter was incremented
    
    private var apu: APU
    
    private let TICKS_PER_DIV: UInt16 = 256
    private let CLOCK_DIVISOR_MASK: UInt8 = 0x03
    
    private let DIV_REGISTER: Address = 0xFF04
    private let TIMER_COUNTER_REGISTER: Address = 0xFF05
    private let TIME_MODULO_REGISTER: Address = 0xFF06
    private let TIMER_CONTROL_REGISTER: Address = 0xFF07
    
    // MARK: - Our registers
    
    private var divRegister: Register = 0
    private var timerCounter: Register = 0
    private var timerModulo: Register = 0
    private var timerControl: Register = 0
    
    // MARK: - Public interface
    
    init(apu: APU) {
        // Store a reference to the APU
        
        self.apu = apu
        
        // Initialize things to their startup value
        
        reset()
    }
    
    func reset() {
        // Do what a real gameboy does. DIV starts at 0xAB, TAC starts at 0xF8
        
        lastDivRegisterIncrement = 0
        lastTimerRegisterIncrement = 0
        divRegister = 0xAB
        timerCounter = 0
        timerModulo = 0
        timerControl = 0xF8
    }    
    
    func tick(_ ticks: Ticks) -> InterruptSource? {
        // Handle each part of the clock independently. First the div register, which is always counting up.
        
        lastDivRegisterIncrement = lastDivRegisterIncrement + UInt16(ticks)
        
        if lastDivRegisterIncrement >= TICKS_PER_DIV {
            let oldDiv = divRegister            // Save the old value
            let newDiv = divRegister &+ 1       // Wrap the value around if it overflows
            
            // Increment the div register
            
            divRegister = newDiv
            
            // If bit 4 went from a 1 to a 0, tick the APU
            
            if (oldDiv & 0x10 == 0x10) && (newDiv & 0x10 == 0) {
                apu.divTick()
            }
            
            // Don't forget any extra if the last instruction took too long
            
            lastDivRegisterIncrement -= TICKS_PER_DIV
        }
        
        // Do we need to update the timer? Only if the time enable bit is on
        
        guard timerControl & TimerControlBits.enabled != 0 else {
            // Timer is off, do nothing
            
            return nil
        }
        
        // Get our divisor. "Clock" refers to CPU clock (~4 MHz), not ticks (~ 1MHz). So we divide by an extra 4 since we count in ticks.
        
        let divisor: UInt16
        
        switch timerControl & CLOCK_DIVISOR_MASK {
        case TimerControlBits.clockDivIs1024:
            divisor = 256
        case TimerControlBits.clockDivIs16:
            divisor = 4
        case TimerControlBits.clockDivIs64:
            divisor = 16
        case TimerControlBits.clockDivIs256:
            divisor = 64
        default:
            // Xcode can't seem to figure out we have all possible cases of 2 bits
            fatalError("Unable to find a case for time control value 0x\(toHex(timerControl))!")
        }
        
        // See if we need to increment the timer
        
        lastTimerRegisterIncrement = lastTimerRegisterIncrement + UInt16(ticks)
        
        var interruptNeeded = false
        
        while lastTimerRegisterIncrement >= divisor {
            // A timer register increment has occured. Adjust our counter.
            
            lastTimerRegisterIncrement -= divisor   // We can't get over divisor
            
            // Time to increment the timer, be prepared for an overflow
            
            if timerCounter == 0xFF {       // Time to reset
                // We need to raise an interrput (0xFF + 1 would have rolled over)
                
                timerCounter = timerModulo              // Resert the timer to the modulo value
            
                interruptNeeded = true
            } else {
                // Not time for the interrupt yet, so just increase the timer counter
                
                timerCounter += 1
            }
        }
        
        // Raise the interrupt if we overflowed
        
        return interruptNeeded ? InterruptSource.timer : nil
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        switch address {
        case DIV_REGISTER:
            return divRegister
        case TIMER_COUNTER_REGISTER:
            return timerCounter
        case TIME_MODULO_REGISTER:
            return timerModulo
        case TIMER_CONTROL_REGISTER:
            return timerControl
        default:
            fatalError("The timer should not have been asked for memory address 0x\(toHex(address))")
        }
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        switch address {
            case DIV_REGISTER:
                if divRegister & 0x10 == 0x10 {
                    // If the div register's bit 4 changed from 1 to 0, we need to tick the APU's clock
                    apu.divTick()
                }
                
                divRegister = 0                 // All writes to this register reset it to 0
                lastDivRegisterIncrement = 0    // Gotta reset this too so the first tick isn't too short
            case TIMER_COUNTER_REGISTER:
                timerCounter = value
            case TIME_MODULO_REGISTER:
                timerModulo = value
            case TIMER_CONTROL_REGISTER:
                if timerControl & CLOCK_DIVISOR_MASK != value & CLOCK_DIVISOR_MASK {
                    // They changed the timer rate, reset the internal counter and timer counter
                    
                    lastTimerRegisterIncrement = 0
                    timerCounter = timerModulo
                }
                timerControl = value
            default:
                fatalError("The timer should not have been asked to set memory address 0x\(toHex(address))")
        }
    }
}
