//
//  Memory.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import Foundation

enum MemoryLocations: Address {
    case joypad = 0xFF00
    
    case timerRangeStart = 0xFF04
    case timerRangeEnd = 0xFF07
    
    case interruptFlags = 0xFF0F
    case interruptEnable = 0xFFFF
}

protocol MemoryMappedDevice {
    func readRegister(_ address: Address) -> UInt8
    func writeRegister(_ address: Address, _ value: UInt8)
}

class Memory {
    // For now we'll just allocate the full address space and start it at 0x00
    private var memory: Data // [UInt8] = Array.init(repeating: 0x00, count: 0xFFFF)
    
    // We also need some other objects we'll redirect memory access to
    private var timerDevice: MemoryMappedDevice
    
    init(romLocation: URL, timer: Timer) throws {
        memory = try Data(contentsOf: romLocation)
        memory.append(contentsOf: Array.init(repeating: 0x00, count: 0xFFFF - memory.count + 1))
        
        timerDevice = timer
    }
    
    subscript(index: UInt16) -> UInt8 {
        get {
            // These will get more complicated later
            
            switch index {
            case 0xFF44 where GAMEBOY_DOCTOR:
                // For the Gameboy Doctor to help us test things, the LCD's LY register needs to always read 0x90
                return 0x90
            case MemoryLocations.timerRangeStart.rawValue...MemoryLocations.timerRangeEnd.rawValue:
                return timerDevice.readRegister(index)
            default:
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
                switch index {
                case MemoryLocations.timerRangeStart.rawValue...MemoryLocations.timerRangeEnd.rawValue:
                    return timerDevice.writeRegister(index, value)
                default:
                    memory[Int(index)] = value
                }
            }
        }
    }
}
