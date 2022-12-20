//
//  DMAController.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/16/22.
//

import Foundation

class DMAController: MemoryMappedDevice {
    
    // MARK: - Our private data
    
    private var memory: Memory!         // In reality will always be set, not setting is an invalid configuration, we need it to copy data
    private var lastSource: UInt8 = 0   // Where we last copied from (high byte)
    private var ticksLeft: UInt8 = 0    // How much longer the copy will continue for
    
    // MARK: - Public interface
    
    init() {
        // Just do a reset
        
        reset()
    }
    
    func reset() {
        // Put things back to a sane default
        
        lastSource = 0x00
        ticksLeft = 0
    }
    
    func setMemory(memory: Memory) {
        self.memory = memory
    }
    
    func dmaInProgress() -> Bool {
        return ticksLeft > 0
    }
    
    func tick(_ ticks: Ticks) {
        guard ticksLeft > 0 else {
            return
        }
        
        // Count down so we know when DMA is over
        
        if ticksLeft < ticks {
            ticksLeft = 0
        } else {
            ticksLeft -= ticks
        }
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        guard address == MemoryLocations.dmaRegister else {
            fatalError("The joypad should not have been asked to read memory address 0x\(toHex(address))")
        }
        
        return lastSource
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        guard address == MemoryLocations.dmaRegister else {
            fatalError("The joypad should not have been asked to set memory address 0x\(toHex(address))")
        }
        
        // When they write a value to our register, we copy 160 bytes from 0x(value)00 to 0xFE00
        
        lastSource = value
        
        // TODO: What happens on a Game Boy if an interrupt happens during DMA?
        // TODO: For now we're not going to let DMA read/write OAM during modes 2 (OAM scan) and 3 (drawing) or read video RAM during 3.
        
        // Copy all the data right now
        
        for lowerAddressByte: UInt16 in 0x00...0x9F {
            let destination = lowerAddressByte + MemoryLocations.objectAttributeMemoryRange.lowerBound
            let source = lowerAddressByte + UInt16(value << 8)
            
            memory![destination] = memory![source]
        }
        
        // Mark how much time is left.
        // NOTE: This must happen *after* the transfer, other wise our address blocking code would block our own reads/writes
        
        ticksLeft = 160
    }
}
