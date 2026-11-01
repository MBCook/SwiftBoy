//
//  MBC3.swift
//  Swift Boy
//
//  Created by Michael Cook on 11/01/26.
//

import Foundation

class MBC3: Cartridge {
    // MARK: - Our private data
    
    private var rom: Data           // The actual ROM data
    private var romBank: UInt8      // Which ROM bank is currently selected
    private let romMask: UInt32     // The mask to mask ROM addresses with (based on total size)
    
    private var ramEnabled: Bool    // Is RAM turned on?
    private var ram: Data           // We have RAM, it's here
    private var ramBank: UInt8      // Which bank we're looking at
    private let ramMask: UInt16     // The mask to mask RAM addresses with (based on total size)
    
    // NOTE: We don't support the RTC stuff
    
    // MARK: - Out public properties (setters are private)
    
    private(set) var totalROM: UInt32
    private(set) var totalRAM: UInt32
    
    // MARK: - Cartridge methods
    
    required init(romSize: UInt32, ramSize: UInt32, romData: Data) {
        // Record our ROM/RAM sizes and data
        
        totalROM = romSize
        totalRAM = ramSize // Fixed and not selectable
        rom = romData
        
        romMask = romSize - 1
        
        // Allocate RAM, it always exists
        
        ram = Data(count: Int(totalRAM))
        
        if totalRAM > 0 {
            ramMask = UInt16(totalRAM) - 1  // Total RAM size shouldn't be big enough for this to be a problem due to sanity check
        } else {
            ramMask = 0
        }
    
        // Default banks are 0 for RAM and 1 for ROM and RAM disabled, and ROM mode addressing
        
        romBank = 1
        ramBank = 0
        ramEnabled = false
    }
    
    static func sanityCheckSizes(romSize: UInt32, ramSize: UInt32) -> (Bool, Bool) {
        let romGood = romSize <= TWO_MB     // Gotta be 2 MB or less
        let ramGood = ramSize <= THIRTY_TWO_KB && ramSize != SIXTEEN_KB  // Only valid sizes
        
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
        
        return ram[calculateRAMAddress(address)]
    }
    
    func writeToROM(_ address: Address, _ value: UInt8) {
        switch address {
            case 0x0000...0x1FFF:
                // Controls if RAM is enabled or not (we'll ignore it if there is no RAM)
                
                if totalRAM > 0 {
                    ramEnabled = value & 0x0F == 0x0A   // Lower nibble has to be A for some reason in the GB hardware
                }
            case 0x2000...0x3FFF:
                // Set ROM bank number
                romBank = value & 0x7F  // Keep 7 bits
                
                if romBank == 0 {
                    romBank = 1
                }
            case 0x4000...0x5FFF:
                // Set the 3 bits for the RAM bank, bit 4 for RTC register
                
                if value > 0x07 {
                    // They're trying to use RTC, we don't actually support that
                    // But we need to disable RAM
                    
                    ramEnabled = false
                } else {
                    ramBank = value     // Already clamped to a good value by the if
                }
            default:
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
        
        // Adjust for the selected bank
        ramAddress |= UInt16(ramBank) * UInt16(EIGHT_KB)
        
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
