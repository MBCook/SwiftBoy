//
//  Memory.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import Foundation

let TWO_KB: UInt32 = 0x2000
let EIGHT_KB: UInt32 = 0x2000
let THIRTY_TWO_KB: UInt32 = 0x8000
let ONE_MB: UInt32 = 0x100000
let TWO_MB: UInt32 = 0x200000

let RAM_BANK_MASK: Address = 0x1FFF  // The size of one RAM bank on the Game Boy for masking purposes

enum MemoryLocations {
    static let romRange: ClosedRange<Address> = 0x0000...0x7FFF
    static let romBankStart: Address = 0x4000
    
    static let videoRAMRange: ClosedRange<Address> = 0x8000...0x9FFF
    static let videoRAMHighBlock: Address = 0x9000
    static let videoRAMLowTileMap: Address = 0x9800
    static let videoRAMHighTileMap: Address = 0x9C00
    
    static let externalRAMRange: ClosedRange<Address> = 0xA000...0xBFFF
    
    static let workRAMRange: ClosedRange<Address> = 0xC000...0xDFFF
    
    static let objectAttributeMemoryRange: ClosedRange<Address> = 0xFE00...0xFE9F
    
    static let ioRegisterRange: ClosedRange<Address> = 0xFF00...0xFF4B  // Range is larget on CGB, up to 7F
    static let joypad: Address = 0xFF00
    static let serialData: Address = 0xFF01
    static let serialControl: Address = 0xFF02
    static let timerRegistersRange: ClosedRange<Address> = 0xFF04...0xFF07
    static let interruptFlags: Address = 0xFF0F
    static let audioRange: ClosedRange<Address> = 0xFF10...0xFF26
    static let lcdRegisterRange: ClosedRange<Address> = 0xFF40...0xFF4B
    static let dmaRegister: Address = 0xFF46
    
    static let highRAMRange: ClosedRange<Address> = 0xFF80...0xFFFE
    
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
    case joypad
    case audio
    case lcdRegisters
    case dmaRegister
    case highRAM
    case interruptController
    case unknown
}

protocol MemoryMappedDevice {
    func readRegister(_ address: Address) -> UInt8
    func writeRegister(_ address: Address, _ value: UInt8)
    func reset()
}

class Memory {
    
    // MARK: - Our private data
    
    private var cartridge: Cartridge!   // A representation of the game cartridge
    private var workRAM: Data!          // Built in RAM for program operation
    private var highRAM: Data!          // Tiny bit more RAM for programs to use, where the stack lives, and works during DMA
    private var ioRegisters: Data!      // Other registers we don't handle properly yet, act like they're normal RAM
    
    // We also need some other objects we'll redirect memory access to
    private let timer: MemoryMappedDevice
    private let interruptController: InterruptController
    private let ppu: PPU
    private let joypad: Joypad
    private let apu: APU
    
    // MARK: Public methods
    
    init(cartridge: Cartridge, timer: Timer, interruptController: InterruptController, ppu: PPU, joypad: Joypad, apu: APU) {
        // Save references to the other objects
        
        self.timer = timer
        self.interruptController = interruptController
        self.ppu = ppu
        self.joypad = joypad
        self.apu = apu
        
        // Load the game and reset our state
        
        loadGameAndReset(cartridge)
    }
    
    func reset() {
        // Allocate the various RAM banks built into the Game Boy
        
        workRAM = Data(count: Int(EIGHT_KB))
        highRAM = Data(count: 128)
        ioRegisters = Data(count: 76)
    }
    
    func loadGameAndReset(_ cartridge: Cartridge) {
        self.cartridge = cartridge
        
        reset()
    }
    
    subscript(index: Address) -> UInt8 {
        get {
            // Categorize the read
            
            let section = categorizeAddress(index)

            // During DMA you can only access high RAM
            
            guard !ppu.dmaInProgress() || section == .highRAM else {
                return 0xFF     // Open bus, you wouldn't have been able to read anything at that address
            }

            // Route it to the right place (order doesn't matter, the classifier took care of that)
            
            switch section {
            case .rom:
                return cartridge.readFromROM(index)
            case .videoRAM, .objectAttributeMemory, .lcdRegisters, .dmaRegister:
                return ppu.readRegister(index)
            case .timerRegisters:
                return timer.readRegister(index)
            case .ioRegisters:
                return ioRegisters[Int(index - MemoryLocations.ioRegisterRange.lowerBound)]
            case .joypad:
                return joypad.readRegister(index)
            case .audio:
                return apu.readRegister(index)
            case .externalRAM:
                return cartridge.readFromRAM(index)
            case .workRAM:
                return workRAM[Int(index - MemoryLocations.workRAMRange.lowerBound)]
            case .highRAM:
                return highRAM[Int(index - MemoryLocations.highRAMRange.lowerBound)]
            case .interruptController:
                return interruptController.readRegister(index)
            case .unknown:
                return 0xFF // Reading anywhere else gets you an open bus (0xFF)
            }
        }
        set(value) {
            if (BLARGG_TEST_ROMS || GAMEBOY_DOCTOR) && index == MemoryLocations.serialControl && value == 0x81 {
                // The Blargg test roms (and Gameboy Doctor) write a byte to 0xFF01 and then 0x81 to 0xFF02 to print it to the serial line.
                // This duplicates what's printed to the screen. Since we don't have the screen setup, that's handy.
                
                print(String(cString: [ioRegisters[Int(MemoryLocations.serialData - MemoryLocations.ioRegisterRange.lowerBound)],
                                       0x00]), terminator: "")
                
                return
            }
            
            // Categorize the write
            
            let section = categorizeAddress(index)
            
            // During DMA you can only access high RAM
            
            guard !ppu.dmaInProgress() || section == .highRAM else {
                return  // During DMA you can't write to that address
            }
            
            // Route it to the right place (order doesn't matter, the classifier took care of that)
            
            switch section {
            case .rom:
                cartridge.writeToROM(index, value)
            case .videoRAM, .objectAttributeMemory, .lcdRegisters, .dmaRegister:
                ppu.writeRegister(index, value)
            case .externalRAM:
                cartridge.writeToRAM(index, value)
            case .workRAM:
                workRAM[Int(index - MemoryLocations.workRAMRange.lowerBound)] = value
            case .timerRegisters:
                timer.writeRegister(index, value)
            case .ioRegisters:
                ioRegisters[Int(index - MemoryLocations.ioRegisterRange.lowerBound)] = value
            case .joypad:
                joypad.writeRegister(index, value)
            case .audio:
                apu.writeRegister(index, value)
            case .highRAM:
                highRAM[Int(index - MemoryLocations.highRAMRange.lowerBound)] = value
            case .interruptController:
                interruptController.writeRegister(index, value)
            case .unknown:
                // We'll do nothing
                return
            }
        }
    }
    
    // MARK: - Private helper methods
    
    private func categorizeAddress(_ address: Address) -> MemorySection {
        // Note that overall ranges (like I/O registers) must come AFTER more specific entries (like joystick or video registers)
        
        switch address {
        
        case MemoryLocations.timerRegistersRange:
            return .timerRegisters
        case MemoryLocations.joypad:
            return .joypad
        case MemoryLocations.dmaRegister:
            return .dmaRegister
        case MemoryLocations.lcdRegisterRange:
            return .lcdRegisters
        case MemoryLocations.audioRange:
            return .audio
        case MemoryLocations.interruptEnable, MemoryLocations.interruptFlags:
            return .interruptController
        case MemoryLocations.ioRegisterRange:
            return .ioRegisters
        case MemoryLocations.romRange:
            return .rom
        case MemoryLocations.videoRAMRange:
            return .videoRAM
        case MemoryLocations.externalRAMRange:
            return .externalRAM
        case MemoryLocations.workRAMRange:
            return .workRAM
        case MemoryLocations.objectAttributeMemoryRange:
            return .objectAttributeMemory
        case MemoryLocations.highRAMRange:
            return .highRAM
        default:
            return .unknown
        }
    }
}
