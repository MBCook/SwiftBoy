//
//  NoMapper.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/10/22.
//

import Foundation

class NoMapper: Cartridge {
    // MARK: Our private data
    
    private var rom: Data       // The actual ROM data
    private var ram: Data?      // If we have 8 KB of RAM, it's here
    
    // MARK: - Public properties
    
    let totalROM: UInt32 = THIRTY_TWO_KB    // We only support 32 KB of ROM
    private(set) var totalRAM: UInt32
    
    // MARK: - Cartridge methods
    
    required init(romSize: UInt32, ramSize: UInt32, romData: Data) {
        // We only have one ROM size, we can ignore that
        // We don't care about RAM size, only if it exists
        
        if ramSize > 0 {
            ram = Data(count: Int(ramSize))
        }
        
        rom = romData
        totalRAM = ramSize
    }
    
    static func sanityCheckSizes(romSize: UInt32, ramSize: UInt32) -> (Bool, Bool) {
        let romGood = romSize == THIRTY_TWO_KB                      // We only support 32 KB
        let ramGood = ramSize == 0x0000 || ramSize == EIGHT_KB      // Only two possible RAM sizes
        
        return (romGood, ramGood)
    }
    
    func readFromROM(_ address: Address) -> UInt8 {
        return rom[Int(address)]
    }
    
    func readFromRAM(_ address: Address) -> UInt8 {
        return ram?[Int(address - MemoryLocations.externalRAMRange.lowerBound)] ?? 0xFF
    }
    
    func writeToROM(_ address: Address, _ value: UInt8) {
        // Never does anything, no internal variables to track
    }
    
    func writeToRAM(_ address: Address, _ value: UInt8) {
        // Who cares if they write to RAM that's not that? We don't.
        
        if var ram {
            ram[Int(address - MemoryLocations.externalRAMRange.lowerBound)] = value
        }
    }
}
