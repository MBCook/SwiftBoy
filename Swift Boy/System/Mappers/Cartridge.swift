//
//  Mapper.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/10/22.
//

import Foundation

protocol Cartridge {
    // MARK: - Properties that people can read for more info if they want
    
    var totalROM: UInt32 { get }    // Total ROM in the cartridge (up to 8Mb/1MB)
    var totalRAM: UInt32 { get }    // Total RAM in the cartridge (up to 128Kb)
    
    // MARK: - The constructor our implementers must have, and a sanity check function they must provide
    
    init(romSize: UInt32, ramSize: UInt32, romData: Data)
    
    static func sanityCheckSizes(romSize: UInt32, ramSize: UInt32) -> (Bool, Bool)
    
    // MARK: - Methods for accessing RAM/ROM
    
    func readFromROM(_ address: Address) -> UInt8
    func readFromRAM(_ address: Address) -> UInt8
    
    func writeToROM(_ address: Address, _ value: UInt8)   // This is used to set internal settings of the bank controller by games
    func writeToRAM(_ address: Address, _ value: UInt8)
}
