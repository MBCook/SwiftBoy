//
//  Memory.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import Foundation

class Memory {
    // For now we'll just allocate the full address space and start it at 0x00
    var memory: [UInt8] = Array.init(repeating: 0x00, count: 0xFFFF)
    
    subscript(index: UInt16) -> UInt8 {
        get {
            // These will get more complicated later
            return memory[Int(index)]
        }
        set(value) {
            // These will get more complicated later
            memory[Int(index)] = value
        }
    }
}
