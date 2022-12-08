//
//  Interrupts.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/7/22.
//

import Foundation

enum InterruptSource: Bitmask, CaseIterable {
case vblank = 0x01
case lcdStat = 0x02
case timer = 0x04
case serial = 0x08
case joypad = 0x10
}

class InterruptController: MemoryMappedDevice {
    // Private variables
    
    private var globalEnable: Bool
    private var enabledInterrupts: Register
    private var raisedInterrupts: Register
    
    private let INTERRUPT_HANDLER_BASE: Address = 0x0040
    
    // MARK: - Our public interface
    
    init() {
        globalEnable = false
        enabledInterrupts = 0x00
        raisedInterrupts = 0x00
    }
    
    // If an interrupt needs servicing, this marks things correclty and returns the address to jump to
    func handleNextInterrupt() -> Address? {
        guard globalEnable else {
            // Interrupts are disabled, nothing to do
            
            return nil
        }
        
        guard enabledInterrupts & raisedInterrupts > 0x00 else {
            // Any raised interrupts aren't enabled, so there is no work to do
            
            return nil
        }
        
        // OK, cycle through the enabled interrupts in priority order (that above) and see if they triggered
        
        for bit in InterruptSource.allCases {
            if bit.rawValue & enabledInterrupts & raisedInterrupts > 0 {
                // Found it! Clear the bit, then return the address of the interupt handler to jump to
                
                print("Interrupt \(bit) needs servicing.")
                
                raisedInterrupts -= bit.rawValue    // Clears the bit
                globalEnable = false                // Disable interrupts while things are being serviced
                
                return INTERRUPT_HANDLER_BASE + 8 * UInt16(bit.rawValue >> 1)   // Handlers start at the base each is 8 bytes
            }
        }
        
        // We should never get down here
        
        fatalError("Enabled interrupts was \(toHex(enabledInterrupts)) and " +
                   "raised interrupts was \(toHex(raisedInterrupts)) but they had no bits in common?")
    }
    
    func raiseInterrupt(_ source: InterruptSource) {
        // Set the given bit to 1 to indicate the interrupt has been raised
        raisedInterrupts |= source.rawValue
    }
    
    func disableInterrupts() {
        print("Disabling interrupts")
        globalEnable = false
    }
    
    func enableInterrupts() {
        print("Enabling interrupts")
        globalEnable = true
    }
    
    // MARK: MemoryMappedDevice protocol methods
    
    func readRegister(_ address: Address) -> UInt8 {
        switch address {
        case MemoryLocations.interruptEnable.rawValue:
            return enabledInterrupts
        case MemoryLocations.interruptFlags.rawValue:
            return raisedInterrupts
        default:
            fatalError("The interrupt controller should not have been asked for memory address 0x\(toHex(address))")
        }
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        switch address {
        case MemoryLocations.interruptEnable.rawValue:
            enabledInterrupts = value
        case MemoryLocations.interruptFlags.rawValue:
            raisedInterrupts = value
        default:
            fatalError("The interrupt controller should not have been asked to set memory address 0x\(toHex(address))")
        }
    }
}
