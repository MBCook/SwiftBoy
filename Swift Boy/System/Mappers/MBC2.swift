//
//  MBC2.swift
//  Swift Boy
//
//  Created by Michael Cook on 11/01/26.
//

import Foundation

class MBC2: Cartridge {
    // MARK: - Our private data
    
    private var rom: Data           // The actual ROM data
    private var romBank: UInt8      // Which ROM bank is currently selected
    private let romMask: UInt32     // The mask to mask ROM addresses with (based on total size)
    
    private var ramEnabled: Bool    // Is RAM turned on?
    private var ram: Data           // We have RAM, it's here
    private let ramMask: UInt16     // The mask to mask RAM addresses with (based on total size)
    
    // MARK: - Out public properties (setters are private)
    
    private(set) var totalROM: UInt32
    private(set) var totalRAM: UInt32
    
    // MARK: - Cartridge methods
    
    required init(romSize: UInt32, ramSize: UInt32, romData: Data) {
        // Record our ROM/RAM sizes and data
        
        totalROM = romSize
        totalRAM = 256          // Fixed and not selectable, cartridge header is ignored
        rom = romData
        
        romMask = romSize - 1
        
        // Allocate RAM, it always exists
        
        ram = Data(count: Int(totalRAM))
        
        ramMask = UInt16(totalRAM) - 1  // Total RAM size shouldn't be big enough for this to be a problem due to sanity check
    
        // Default banks are 0 for RAM and 1 for ROM and RAM disabled, and ROM mode addressing
        
        romBank = 1
        ramEnabled = false
    }
    
    static func sanityCheckSizes(romSize: UInt32, ramSize: UInt32) -> (Bool, Bool) {
        let romGood = romSize <= TWO_HUNDRED_FIFTY_SIX_KB   // 256 KB or less
        let ramGood = true                  // Ignored, the size is fixed at 256 bytes
        
        return (romGood, ramGood)
    }
    
    func readFromROM(_ address: Address) -> UInt8 {
        // OK, read from ROM at the correct address
        
        return rom[calculateROMAddress(address)]
    }
    
    func readFromRAM(_ address: Address) -> UInt8 {
        guard ramEnabled else {
            // If RAM isn't enabled, it's open bus (0xFF)
            
            return 0xFF
        }
        
        // OK, read from RAM at the correct address
        
        let byte = ram[calculateRAMAddress(address)]
        
        return 0xF0 + (0x0F & byte)     // Only lower 4 bits are actually stored
    }
    
    func writeToROM(_ address: Address, _ value: UInt8) {
        if address >= 0x0000 && address <= 0x3FFF {
            // The lowest bit of the upper address byte is 0 means we're controling RAM, otherwise ROM
            
            if address & 0x0100 == 0x0000 {
                // RAM control
                
                ramEnabled = value & 0x0F == 0x0A   // The magic value to enable RAM ends in 'A'
            } else {
                // ROM control
                
                romBank = value & 0x0F
                
                if romBank == 0 {
                    romBank = 1     // No selecting bank 0, that's always available elsewhere
                }
            }
        } else if address >= 0x4000 && address <= 0x7FFF {
            // Ignored
            return
        } else {
            fatalError("Cartridge should not have been given address 0x\(toHex(address)) to write to")
        }
    }
    
    func writeToRAM(_ address: Address, _ value: UInt8) {
        guard ramEnabled else {
            // RAM disabled? No write.
            return
        }
        
        // OK, write to RAM at the correct address
        
        ram[calculateRAMAddress(address)] = value
    }
    
    // MARK: - Bank calculation helper methods
    
    private func calculateRAMAddress(_ globalAddress: Address) -> Int {
        // So what we do depends on the banking mode
        
        // First adjust the address to be based on a base of 0x0000 instead of 0xA000 (take it out of the global address space)
        
        var ramAddress = globalAddress - MemoryLocations.externalRAMRange.lowerBound
        
        // Mask it to the size of one bank, just in case
        
        ramAddress = ramAddress & RAM_BANK_MASK
        
        // Finally we need to mask it based on our RAM size, just in case anyone is doing something weird
        
        ramAddress &= ramMask
        
        // Now realAddress holds the correct index into our ram object
        
        return Int(ramAddress)
    }
    
    private func calculateROMAddress(_ globalAddress: Address) -> Int {
        // What we do depends on if they're looking at the first bank or second bank of ROM
        
        if globalAddress < MemoryLocations.romBankStart {
            // The low bank is almost always a straight conversion of bank 0, but there is a chance it's not
            
            let romAddress = UInt32(globalAddress)
            
            // Mask off any bits that are too high based on our size
            
            return Int(romAddress & romMask)
        } else {
            // OK, our address is in the upper bank. Let's start by correcting that offset down to 0
            
            var romAddress = UInt32(globalAddress - MemoryLocations.romBankStart)
            
            // Add in the bits that com from the ROM bank
            
            romAddress |= UInt32(romBank) << 14
            
            // Mask off any bits that are too high based on our size
            
            return Int(romAddress & romMask)
        }
    }
}
