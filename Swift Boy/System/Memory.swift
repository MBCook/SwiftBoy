//
//  Memory.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import Foundation

let EIGHT_KB: UInt32 = 0x2000

enum MemoryLocations {
    static let romStart: Address = 0x0000
    static let romBankStart: Address = 0x4000
    static let romEnd: Address = 0x7FFF
    
    static let videoRAMStart: Address = 0x8000
    static let videoRAMEnd: Address = 0x9FFF
    
    static let externalRAMStart: Address = 0xA000
    static let externalRAMBankStart: Address = 0xB000
    static let externalRAMEnd: Address = 0xBFFF
    
    static let workRAMStart: Address = 0xC000
    static let workRAMEnd: Address = 0xDFFF
    
    static let objectAttributeMemoryStart: Address = 0xFE00
    static let objectAttributeMemoryEnd: Address = 0xFE9F
    
    static let ioRegisterStart: Address = 0xFF00
    
    static let serialData: Address = 0xFF01
    static let serialControl: Address = 0xFF02
    static let timerRegistersStart: Address = 0xFF04
    static let timerRegistersEnd: Address = 0xFF07
    static let interruptFlags: Address = 0xFF0F
    
    static let lcdRegisterStart: Address = 0xFF40
    static let lcdYRegister: Address = 0xFF44
    static let lcdRegisterEnd: Address = 0xFF4B
    
    static let ioRegisterEnd: Address = 0xFF7F
    
    static let highRAMStart: Address = 0xFF80
    static let highRAMEnd: Address = 0xFFFE
    
    static let interruptEnable: Address = 0xFFFF
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
            
            if GAMEBOY_DOCTOR && index == MemoryLocations.lcdYRegister {
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
                return videoRAM[Int(index - MemoryLocations.videoRAMStart)]
            case .externalRAM:
                return cartridge.readFromRAM(index)
            case .workRAM:
                return workRAM[Int(index - MemoryLocations.workRAMStart)]
            case .objectAttributeMemory:
                return oamRAM[Int(index - MemoryLocations.objectAttributeMemoryStart)]
            case .ioRegisters:
                return ioRegisters[Int(index - MemoryLocations.ioRegisterStart)]
            case .timerRegisters:
                return timer.readRegister(index)
            case .highRAM:
                return highRAM[Int(index - MemoryLocations.highRAMStart)]
            case .interruptEnable:
                return interruptController.readRegister(index)
            default:
                return 0xFF // Reading anywhere else gets you an open bus (0xFF)
            }
        }
        set(value) {
            // Quick debug test
            
            if (BLARGG_TEST_ROMS || GAMEBOY_DOCTOR) && index == MemoryLocations.serialControl && value == 0x81 {
                // The Blargg test roms (and Gameboy Doctor) write a byte to 0xFF01 and then 0x81 to 0xFF02 to print it to the serial line.
                // This duplicates what's printed to the screen. Since we don't have the screen setup, that's handy.
                
                print(String(cString: [ioRegisters[Int(MemoryLocations.serialData - MemoryLocations.ioRegisterStart)], 0x00]), terminator: "")
                
                return
            }
            
            // Categorize the write
            
            let section = categorizeAddress(index)
            
            // Route it to the right place
            
            switch section {
            case .rom:
                cartridge.writeToROM(index, value)
            case .videoRAM:
                videoRAM[Int(index - MemoryLocations.videoRAMStart)] = value
            case .externalRAM:
                cartridge.writeToRAM(index, value)
            case .workRAM:
                workRAM[Int(index - MemoryLocations.workRAMStart)] = value
            case .objectAttributeMemory:
                oamRAM[Int(index - MemoryLocations.objectAttributeMemoryStart)] = value
            case .ioRegisters:
                ioRegisters[Int(index - MemoryLocations.ioRegisterStart)] = value
            case .timerRegisters:
                timer.writeRegister(index, value)
            case .highRAM:
                highRAM[Int(index - MemoryLocations.highRAMStart)] = value
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
        case MemoryLocations.romStart...MemoryLocations.romEnd:
            return .rom
        case MemoryLocations.videoRAMStart...MemoryLocations.videoRAMEnd:
            return .videoRAM
        case MemoryLocations.externalRAMStart...MemoryLocations.externalRAMStart:
            return .externalRAM
        case MemoryLocations.workRAMStart...MemoryLocations.workRAMEnd:
            return .workRAM
        case MemoryLocations.objectAttributeMemoryStart...MemoryLocations.objectAttributeMemoryEnd:
            return .objectAttributeMemory
        case MemoryLocations.timerRegistersStart...MemoryLocations.timerRegistersEnd:
            return .timerRegisters
        case MemoryLocations.ioRegisterStart...MemoryLocations.ioRegisterEnd:
            return .ioRegisters
        case MemoryLocations.highRAMStart...MemoryLocations.highRAMEnd:
            return .highRAM
        case MemoryLocations.interruptEnable:
            return .interruptEnable
        default:
            return .other
        }
    }
}
