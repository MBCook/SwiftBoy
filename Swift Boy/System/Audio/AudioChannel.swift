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
    
    func tickLengthCounter()
    func tickVolumeEnvelope()
    
    // A single sample is the accumulated change for ~1/44100th of a second, -1 to 1, full volume
    func collectSample() -> Float16
}
