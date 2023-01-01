//
//  MBC1.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/11/22.
//

import Foundation

private enum AddressMode {
    case romMode
    case ramMode
}

private enum BankingMode {
    case simple
    case advanced
}

class MBC1: Cartridge {
    // MARK: - Our private data
    
    private var rom: Data           // The actual ROM data
    private var romBank: UInt8      // Which ROM bank is currently selected
    private var romMask: UInt32     // The mask to mask ROM addresses with (based on total size)
    
    private var ramEnabled: Bool    // Is RAM turned on?
    private var ram: Data?          // If we have RAM, it's here
    private var ramBank: UInt8      // Which RAM bank is currently selected
    private var ramMask: UInt16     // The mask to mask RAM addresses with (based on total size)
    
    private var addressMode: AddressMode    // Should the RAM bank be used as upper address bits for ROM
    private var bankingMode: BankingMode    // Can they remap bank 0?
    
    // MARK: - Out public properties (setters are private)
    
    private(set) var totalROM: UInt32
    private(set) var totalRAM: UInt32
    
    // MARK: - Cartridge methods
    
    required init(romSize: UInt32, ramSize: UInt32, romData: Data) {
        // Record our ROM/RAM sizes and data
        
        totalROM = romSize
        totalRAM = ramSize
        rom = romData
        
        romMask = romSize - 1
        
        // Allocate RAM if it exists
        
        if ramSize > 0 {
            ram = Data(count: Int(ramSize))
            
            ramMask = UInt16(ramSize) - 1   // Total RAM size shouldn't be big enough for this to be a problem due to sanity check
        } else {
            ramMask = 0     // Doesn't matter, no one will access RAM
        }
        
        // Default banks are 0 for RAM and 1 for ROM and RAM disabled, and ROM mode addressing
        
        romBank = 1
        ramBank = 0
        ramEnabled = false
        bankingMode = .simple
        addressMode = .romMode
    }
    
    static func sanityCheckSizes(romSize: UInt32, ramSize: UInt32) -> (Bool, Bool) {
        let romGood = romSize <= TWO_MB     // Gotta be 2 MB or less, only four RAM options
        let ramGood = ramSize == 0 || ramSize == TWO_KB || ramSize == EIGHT_KB || ramSize == THIRTY_TWO_KB  // Only valid sizes
        
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
        
        return ram![calculateRAMAddress(address)]
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
            let fiveBit = value & 0b00011111    // We only want the lower 5 bits
            
            // You can't select bank 0, you get one if you try
            
            romBank = value == 0 ? 1 : fiveBit
            
            // Always add in the high bits if that mode is turned on
            
            romBank += (addressMode == .romMode ? ramBank << 5 : 0)
        case 0x4000...0x5FFF:
            // Set the two bits for the RAM bank or upper ROM bank select bits
            
            ramBank = value & 0x03
        case 0x6000...0x7FFF:
            // Banking mode select
            
            bankingMode = value & 0x01 == 0x01 ? .advanced : .simple
        default:
            fatalError("Cartridge should not have been given address 0x\(toHex(address)) to write to")
        }
    }
    
    func writeToRAM(_ address: Address, _ value: UInt8) {
        guard ram != nil && ramEnabled else {
            // No RAM? Or RAM disabled? No write.
            return
        }
        
        // OK, write to RAM at the correct address
        
        ram![calculateRAMAddress(address)] = value
    }
    
    // MARK: - Bank calculation helper methods
    
    private func calculateRAMAddress(_ globalAddress: Address) -> Int {
        // So what we do depends on the banking mode
        
        // First adjust the address to be based on a base of 0x0000 instead of 0xA000 (take it out of the global address space)
        
        var ramAddress = globalAddress - MemoryLocations.externalRAMRange.lowerBound
        
        // Mask it to the size of one bank, just in case
        
        ramAddress = ramAddress & RAM_BANK_MASK
        
        // If we're in advanced banking mode we need to get the upper bits of the address from the ramBank variable
        
        if bankingMode == .advanced {
            ramAddress |= UInt16(ramBank) << 5
        }
        
        // Finally we need to mask it based on our RAM size, just in case anyone is doing something weird
        
        ramAddress &= ramMask
        
        // Now realAddress holds the correct index into our ram object
        
        return Int(ramAddress)
    }
    
    private func calculateROMAddress(_ globalAddress: Address) -> Int {
        // What we do depends on if they're looking at the first bank or second bank of ROM
        
        if globalAddress < MemoryLocations.romBankStart {
            // The low bank is almost always a straight conversion of bank 0, but there is a chance it's not
            
            var romAddress = UInt32(globalAddress)
            
            if bankingMode == .advanced {
                // In advanced mode, we have to apply the ramBank as the 19th and 20th bits of the address
                // This allows remapping this space to banks $20, $40, and $60 (if the cart is that big)
                
                romAddress |= UInt32(ramBank) << 19
            }
            
            // Mask off any bits that are too high based on our size
            
            return Int(romAddress & romMask)
        } else {
            // OK, our address is in the upper bank. Let's start by correcting that offset down to 0
            
            var romAddress = UInt32(globalAddress - MemoryLocations.romBankStart)
            
            // Add in the bits that com from the ROM bank
            
            romAddress |= UInt32(romBank) << 14
            
            // Unlike the lower bank, we always apply the higher bits from the ramBank register
            
            romAddress |= UInt32(ramBank) << 19
            
            // Mask off any bits that are too high based on our size
            
            return Int(romAddress & romMask)
        }
    }
}
