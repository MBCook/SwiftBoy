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
    
    private var lastDivRegisterIncrement: UInt8         // The last time the DIV register was incremented
    private var lastTimerRegisterIncrement: UInt16      // The last time the counter was incremented
    private var stopMode: Bool                          // Do we stop the timers?
    
    private let TICKS_PER_DIV = 64
    private let CLOCK_DIVISOR_MASK: UInt8 = 0x03
    
    private let DIV_REGISTER: Address = 0xFF04
    private let TIMER_COUNTER_REGISTER: Address = 0xFF05
    private let TIME_MODULO_REGISTER: Address = 0xFF06
    private let TIMER_CONTROL_REGISTER: Address = 0xFF07
    
    // MARK: - Our registers
    
    private var divRegister: Register
    private var timerCounter: Register
    private var timerModulo: Register
    private var timerControl: Register
    
    // MARK: - Public interface
    
    init() {
        // Just initialize everything to 0x00, that's what the hardware does
        
        lastDivRegisterIncrement = 0
        lastTimerRegisterIncrement = 0
        divRegister = 0
        timerCounter = 0
        timerModulo = 0
        timerControl = 0
        stopMode = false
    }
    
    func enterStopMode() {
        stopMode = true
        divRegister = 0
    }
    
    func tick(_ ticks: Ticks) -> InterruptSource? {
        // Handle ticks of the clock
        
        guard !stopMode else {
            // Don't do anything in stop mode
            
            return nil
        }
            
        // Handle each part of the clock independently. First the div register, which is always counting up.
        
        lastDivRegisterIncrement = lastDivRegisterIncrement + ticks
        
        if lastDivRegisterIncrement >= TICKS_PER_DIV {
            // We need to increment the div register
            
            divRegister &+= 1       // Register needs to be able to wrap around
            
            lastDivRegisterIncrement %= 64      // Don't forget any extra if the last instruction took too long
        }
        
        // Do we need to update the timer? Only if the time enable bit is on
        
        guard timerControl & TimerControlBits.enabled != 0 else {
            // Timer is off, do nothing
            
            return nil
        }
        
        // Get our divisor
        
        let divisor: UInt16
        
        switch timerControl & CLOCK_DIVISOR_MASK {
        case TimerControlBits.clockDivIs1024:
            divisor = 1024
        case TimerControlBits.clockDivIs16:
            divisor = 16
        case TimerControlBits.clockDivIs64:
            divisor = 64
        case TimerControlBits.clockDivIs256:
            divisor = 256
        default:
            // Xcode can't seem to figure out we have all possible cases of 2 bits
            fatalError("Unable to find a case for time control value 0x\(toHex(timerControl))!")
        }
        
        // See if we need to increment the timer
        
        lastTimerRegisterIncrement = lastTimerRegisterIncrement + UInt16(ticks)
        
        if lastTimerRegisterIncrement > divisor {
            // Time to increment the timer, be prepared for an overflow
            
            if timerCounter == 0xFF {       // Time to reset
                // We need to raise an interrput (0xFF + 1 would have rolled over)
                
                timerCounter = timerModulo      // Resert the timer to the modulo value
                lastTimerRegisterIncrement = 0  // Start the counting intervals from 0 again
                
                return InterruptSource.timer
            } else {
                timerCounter += 1
            }
        }
        
        return nil
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
            divRegister = 0                 // All writes to this register reset it to 0
            lastDivRegisterIncrement = 0    // Gotta reset this too so the first tick isn't too short
        case TIMER_COUNTER_REGISTER:
            timerCounter = value
        case TIME_MODULO_REGISTER:
            timerModulo = value
        case TIMER_CONTROL_REGISTER:
            timerControl = value
        default:
            fatalError("The timer should not have been asked to set memory address 0x\(toHex(address))")
        }
    }
}
