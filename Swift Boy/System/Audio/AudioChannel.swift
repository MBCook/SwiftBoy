//
//  AudioChannel.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/30/23.
//

import Foundation

protocol AudioChannel: MemoryMappedDevice {
    var apu: APU? { get set }
    
    func reset()
    func disableAPU()
    func disableChannel()
    
    func isEnabled() -> Bool
    
    func tick(_ ticks: Ticks)
    
    func tickAPU()
    func tickLengthCounter()
    func tickVolumeEnvelope()
}
