//
//  Memory.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import Foundation

class Memory {
    // For now we'll just allocate the full address space and start it at 0x00
    var memory: Data // [UInt8] = Array.init(repeating: 0x00, count: 0xFFFF)
    
    init() {
        memory = Data(count: 0xFFFF)
    }
    
    init(romLocation: URL) throws {
        memory = try Data(contentsOf: romLocation)
        memory.append(contentsOf: Array.init(repeating: 0x00, count: 0xFFFF - memory.count + 1))
    }
    
    subscript(index: UInt16) -> UInt8 {
        get {
            // These will get more complicated later
            
            if GAMEBOY_DOCTOR && index == 0xFF44 {
                // For the Gameboy Doctor to help us test things, the LCD's LY register needs to always read 0x90
                return 0x90
            } else {
                return memory[Int(index)]
            }
        }
        set(value) {
            // These will get more complicated later
            
            if (BLARGG_TEST_ROMS || GAMEBOY_DOCTOR) && index == 0xFF02 && value == 0x81 {
                // The Blargg test roms (and Gameboy Doctor) write a byte to 0xFF01 and then 0x81 to 0xFF02 to print it to the serial line.
                // This duplicates what's printed to the screen. Since we don't have the screen setup, that's handy.
                
                print(String(cString: [memory[0xFF01], 0x00]), terminator: "")
            } else {
                memory[Int(index)] = value
            }
        }
    }
}
