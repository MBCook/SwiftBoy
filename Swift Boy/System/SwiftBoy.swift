//
//  SwiftBoy.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/7/22.
//

import Foundation

typealias Address = UInt16
typealias Bitmask = UInt8
typealias Cycles = UInt8
typealias Register = UInt8
typealias RegisterPair = UInt16
typealias Ticks = UInt8

let GAMEBOY_DOCTOR = false
let BLARGG_TEST_ROMS = true

class SwiftBoy {
    // MARK: - Our private variables
    
    private var cpu: CPU
    private var memory: Memory
    private var timer: Timer
    private var interruptController: InterruptController
    private var ppu: PPU
    private var joypad: Joypad
    
    private var logFile: FileHandle?
    
    private var paused: Bool
    
    // MARK: - Our public interface
    
    init(cartridge: Cartridge) throws {
        // Create the various objects we need and wire them up
        
        timer = Timer()
        joypad = Joypad()
        interruptController = InterruptController()
        
        let dmaController = DMAController()
        
        ppu = PPU(dmaController: dmaController)
        memory = Memory(cartridge: cartridge, timer: timer, interruptController: interruptController, ppu: ppu, joypad: joypad)
        
        dmaController.setMemory(memory: memory)
        
        cpu = CPU(memory: memory, interruptController: interruptController)
        
        paused = false
    }
    
    func pause() {
        paused = true
    }
    
    func reset() {
        // Just call reset on all the objects
        
        timer.reset()
        joypad.reset()
        interruptController.reset()
        ppu.reset()
        memory.reset()
        cpu.reset()
    }
    
    func loadGameAndReset(_ cartridge: Cartridge) {
        // Just call reset on all the objects except memory, which gets the new cartridge
        
        timer.reset()
        joypad.reset()
        interruptController.reset()
        ppu.reset()
        memory.loadGameAndReset(cartridge)
        cpu.reset()
    }
    
    // The main runloop
    func run() {
        // Make sure the log file will be closed if it exists
        
        defer {
            if logFile != nil {
                try! logFile!.close()
            }
        }
        
        // Setup the log file if we're in Gameboy Doctor mode
        
        if GAMEBOY_DOCTOR {
            let path = "/Users/michael/Downloads/gameboy-doctor-master/myrun.txt"
            
            do {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
            } catch {
                fatalError(error.localizedDescription)
            }
            
            FileManager.default.createFile(atPath: path, contents: nil)
                
            
            logFile = FileHandle(forWritingAtPath: path)
        }
        
        // We were asked to run, so paused needs to be false
        
        paused = false
        
        // Inform the populace!
        
        print("Starting")
        
        var ticksUsed: Cycles = 0
        
        while true {
            // First update the timer
            
            let timerInterrupt = timer.tick(ticksUsed)
            
            // If the timer wants an interrupt, trigger it
            
            if let timerInterrupt {
                interruptController.raiseInterrupt(timerInterrupt)
            }
            
            // Update the LCD controller status (it will update DMA controller for us)
            
            let lcdInterrupt = ppu.tick(ticksUsed)
            
            // If the LCD controller wants an interrupt, trigger it
            
            if let lcdInterrupt {
                interruptController.raiseInterrupt(lcdInterrupt)
            }
            
            // Print some debug stuff if in Gameboy Doctor mode
            
            if GAMEBOY_DOCTOR {
                do {
                    try logFile!.write(contentsOf: cpu.generateDebugLogLine().data(using: .utf8)!)
                } catch {
                    print("Error writing to log file! \(error.localizedDescription)")
                    exit(1)
                }
            }
            
            // We about to do the next instruction. Don't do that if we need to pause
            
            if paused {
                print("Pausing")
                return
            }
            
            // Ok then, we need to execute the next opcode
            
            do {
                ticksUsed = try cpu.executeInstruction()
            } catch {
                if error is CPUErrors {
                    fatalError(error.localizedDescription)
                } else {
                    fatalError("An unknown error occurred: \(error.localizedDescription)")
                }
            }
        }
    }
}
