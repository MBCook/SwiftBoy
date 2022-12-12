//
//  LCDController.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/11/22.
//

import Foundation

class LCDController: MemoryMappedDevice {
    
    // MARK: - Our private data
    
    // TODO: Other registers
    private let LCD_Y_REGISTER: Address = 0xFF44
    private let DMA_REGISTER: Address = 0xFF46
    
    // MARK: - Our registers
    
    // TODO: Whatever goes here
    
    // MARK: - Public interface
    
    init() {
        // Nothing to do for now
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        switch address {
        case LCD_Y_REGISTER where GAMEBOY_DOCTOR:
            // For the Gameboy Doctor to help us test things, the LCD's LY register needs to always read 0x90
            return 0x90
        default:
            return 0x00     // TODO: This is just for now, pretend there are values
        }
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        switch address {
        default:
            // TODO: For now we do nothing
            return
        }
    }
}
