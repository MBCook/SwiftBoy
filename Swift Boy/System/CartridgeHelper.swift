//
//  Cartridge.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/10/22.
//

import Foundation

enum CartridgeErrors: Error {
    case BadROMSize(expected: UInt32, found: UInt32)
    case UnsupportedCartridgeType(_ type: UInt8)
    case UnsupportedROMSize(_ code: UInt8)
    case UnsupportedRAMSize(_ code: UInt8)
}

extension CartridgeErrors: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .BadROMSize(expected, found):
            return "Bad ROM size found. It was \(found) when we expected it to be \(expected) bytes."
        case let .UnsupportedCartridgeType(type):
            return "Unsupported mapper type on cartridge: 0x\(toHex(type))"
        case let .UnsupportedROMSize(code):
            return "Unsupported ROM size code on cartridge: 0x\(toHex(code))"
        case let .UnsupportedRAMSize(code):
            return "Unsupported RAM size code on cartridge: 0x\(toHex(code))"
        }
    }
}

class CartridgeHelper {
    private static let HEADER_CARTRIDGE_TYPE = 0x0147
    private static let HEADER_ROM_SIZE = 0x0148
    private static let HEADER_RAM_SIZE = 0x0149
    
    static func loadROM(_ rom: Data) throws -> Cartridge {
        print("Loading cartridge data...")
        
        // Get some data from the ROM
        
        let type = rom[HEADER_CARTRIDGE_TYPE]
        let romCode = rom[HEADER_ROM_SIZE]
        let ramCode = rom[HEADER_RAM_SIZE]
        let totalROM = try findROMSize(romCode)
        let totalRAM = try findRAMSize(ramCode)
        
        print("\tHeader says type 0x\(toHex(type)), ROM: \(totalROM) bytes, RAM: \(totalRAM) bytes")
        
        // Figure out what class hanles our cartridge type
        
        var cartridge: Cartridge.Type
        
        switch type {
        case 0x00:
            cartridge = NoMapper.self
        default:
            throw CartridgeErrors.UnsupportedCartridgeType(type)
        }
        
        // Check that cartridge type matches the RAM/ROM sizes specified
        
        guard totalROM == rom.count else {
            throw CartridgeErrors.BadROMSize(expected: totalROM, found: UInt32(rom.count))
        }
        
        try sanityCheckSizes(cartridge.sanityCheckSizes(romSize: totalROM, ramSize: totalRAM), romCode: romCode, ramCode: ramCode)
        
        // If everything is good instatiate the right cartridge object
        
        return cartridge.init(romSize: totalROM, ramSize: totalRAM, romData: rom)
    }
    
    private static func sanityCheckSizes(_ tuple: (Bool, Bool), romCode: UInt8, ramCode: UInt8) throws {
        let (romGood, ramGood) = tuple
        
        if !romGood {
            throw CartridgeErrors.UnsupportedROMSize(romCode)
        } else if !ramGood {
            throw CartridgeErrors.UnsupportedROMSize(ramCode)
        }
    }
    
    private static func findROMSize(_ size: UInt8) throws -> UInt32 {
        guard size < 0x09 else {
            throw CartridgeErrors.UnsupportedROMSize(size)
        }
        
        return 0x8000 * (1 << size)     // The size is the number of 32k (0x8000) banks of ROM there are
    }
    
    private static func findRAMSize(_ size: UInt8) throws -> UInt32 {
        switch size {
        case 0x00:
            return 0        // None
        case 0x02:
            return 0x2000   // 8 Kb
        case 0x03:
            return 0x8000   // 32 Kb
        case 0x04:
            return 0x20000  // 128 Kb
        case 0x05:
            return 0x10000  // 64 Kb
        default:
            throw CartridgeErrors.UnsupportedROMSize(size)
        }
    }
}
