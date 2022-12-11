//
//  Memory.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import Foundation

let EIGHT_KB: UInt32 = 0x2000

enum MemoryLocations: Address {
    case romStart = 0x0000
    case romBankStart = 0x4000
    case romEnd = 0x7FFF
    
    case videoRAMStart = 0x8000
    case videoRAMEnd = 0x9FFF
    
    case externalRAMStart = 0xA000
    case externalRAMBankStart = 0xB000
    case externalRAMEnd = 0xBFFF
    
    case workRAMStart = 0xC000
    case workRAMEnd = 0xDFFF
    
    case objectAttributeMemoryStart = 0xFE00
    case objectAttributeMemoryEnd = 0xFE9F
    
    case ioRegisterStart = 0xFF00
    
    case timerRegistersStart = 0xFF04
    case timerRegistersEnd = 0xFF07
    
    case interruptFlags = 0xFF0F
    
    case ioRegisterEnd = 0xFF7F
    
    case highRAMStart = 0xFF80
    case highRAMEnd = 0xFFFE
    
    case interruptEnable = 0xFFFF
}

private enum MemorySection {
    case rom
    case videoRAM
    case externalRAM
    case workRAM
    case objectAttributeMemory
    case timerRegisters
    case ioRegisters
    case highRAM
    case interruptEnable
    case other
}

protocol MemoryMappedDevice {
    func readRegister(_ address: Address) -> UInt8
    func writeRegister(_ address: Address, _ value: UInt8)
}

class Memory {
    
    // MARK: - Our private data
    
    private var cartridge: Cartridge    // A representation of the game cartridge
    private var videoRAM: Data                  // Built in RAM to hold sprites and tiles
    private var workRAM: Data                   // Built in RAM for program operation
    private var highRAM: Data                   // Tiny bit more RAM for programs to use, where the stack lives, and works during DMA
    private var oamRAM: Data                    // TODO: Until a proper video system exists
    private var ioRegisters: Data               // Other registers we don't handle properly yet, act like they're normal RAM
    
    // We also need some other objects we'll redirect memory access to
    private var timer: MemoryMappedDevice
    private var interruptController: InterruptController
    
    // MARK: Public methods
    
    init(cartridge: Cartridge, timer: Timer, interruptController: InterruptController) {
        // Allocate the various RAM banks built into the Game Boy
        
        videoRAM = Data(count: Int(EIGHT_KB))
        workRAM = Data(count: Int(EIGHT_KB))
        highRAM = Data(count: 128)
        oamRAM = Data(count: 160)
        ioRegisters = Data(count: 128)
        
        // Save references to the other objects
        
        self.cartridge = cartridge
        self.timer = timer
        self.interruptController = interruptController
    }
    
    subscript(index: Address) -> UInt8 {
        get {
            // Quick debug test
            
            if GAMEBOY_DOCTOR && index == 0xFF40 {
                // For the Gameboy Doctor to help us test things, the LCD's LY register needs to always read 0x90
                return 0x90
            }
            
            // Categorize the read
            
            let section = categorizeAddress(index)
            
            // Route it to the right place
            
            switch section {
            case .rom:
                return cartridge.readFromROM(index)
            case .videoRAM:
                return videoRAM[Int(index - MemoryLocations.videoRAMStart.rawValue)]
            case .externalRAM:
                return cartridge.readFromRAM(index)
            case .workRAM:
                return workRAM[Int(index - MemoryLocations.workRAMStart.rawValue)]
            case .objectAttributeMemory:
                return oamRAM[Int(index - MemoryLocations.objectAttributeMemoryStart.rawValue)]
            case .ioRegisters:
                return ioRegisters[Int(index - MemoryLocations.ioRegisterStart.rawValue)]
            case .timerRegisters:
                return timer.readRegister(index)
            case .highRAM:
                return highRAM[Int(index - MemoryLocations.highRAMStart.rawValue)]
            case .interruptEnable:
                return interruptController.readRegister(index)
            default:
                return 0xFF // Reading anywhere else gets you an open bus (0xFF)
            }
        }
        set(value) {
            // Quick debug test
            
            if (BLARGG_TEST_ROMS || GAMEBOY_DOCTOR) && index == 0xFF02 && value == 0x81 {
                // The Blargg test roms (and Gameboy Doctor) write a byte to 0xFF01 and then 0x81 to 0xFF02 to print it to the serial line.
                // This duplicates what's printed to the screen. Since we don't have the screen setup, that's handy.
                
                print(String(cString: [ioRegisters[0xFF02 - Int(MemoryLocations.ioRegisterStart.rawValue)], 0x00]), terminator: "")
                
                return
            }
            
            // Categorize the write
            
            let section = categorizeAddress(index)
            
            // Route it to the right place
            
            switch section {
            case .rom:
                cartridge.writeToROM(index, value)
            case .videoRAM:
                videoRAM[Int(index - MemoryLocations.videoRAMStart.rawValue)] = value
            case .externalRAM:
                cartridge.writeToRAM(index, value)
            case .workRAM:
                workRAM[Int(index - MemoryLocations.workRAMStart.rawValue)] = value
            case .objectAttributeMemory:
                oamRAM[Int(index - MemoryLocations.objectAttributeMemoryStart.rawValue)] = value
            case .ioRegisters:
                ioRegisters[Int(index - MemoryLocations.ioRegisterStart.rawValue)] = value
            case .timerRegisters:
                timer.writeRegister(index, value)
            case .highRAM:
                highRAM[Int(index - MemoryLocations.highRAMStart.rawValue)] = value
            case .interruptEnable:
                interruptController.writeRegister(index, value)
            default:
                // We'll do nothing
                return
            }
        }
    }
    
    // MARK: - Private helper methods
    
    private func categorizeAddress(_ address: Address) -> MemorySection {
        switch address {
        case MemoryLocations.romStart.rawValue...MemoryLocations.romEnd.rawValue:
            return .rom
        case MemoryLocations.videoRAMStart.rawValue...MemoryLocations.videoRAMEnd.rawValue:
            return .videoRAM
        case MemoryLocations.externalRAMStart.rawValue...MemoryLocations.externalRAMStart.rawValue:
            return .externalRAM
        case MemoryLocations.workRAMStart.rawValue...MemoryLocations.workRAMEnd.rawValue:
            return .workRAM
        case MemoryLocations.objectAttributeMemoryStart.rawValue...MemoryLocations.objectAttributeMemoryEnd.rawValue:
            return .objectAttributeMemory
        case MemoryLocations.timerRegistersStart.rawValue...MemoryLocations.timerRegistersEnd.rawValue:
            return .timerRegisters
        case MemoryLocations.ioRegisterStart.rawValue...MemoryLocations.ioRegisterEnd.rawValue:
            return .ioRegisters
        case MemoryLocations.highRAMStart.rawValue...MemoryLocations.highRAMEnd.rawValue:
            return .highRAM
        case MemoryLocations.interruptEnable.rawValue:
            return .interruptEnable
        default:
            return .other
        }
    }
}
