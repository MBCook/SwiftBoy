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

let GAMEBOY_DOCTOR = true
let BLARGG_TEST_ROMS = false

class SwiftBoy {
    // MARK: - Our private variables
    
    private var cpu: CPU
    private var memory: Memory
    private var timer: Timer
    private var interruptController: InterruptController
    
    private var logFile: FileHandle?
    
    init(romLocation: URL) throws {
        timer = Timer()
        interruptController = InterruptController()
        memory = try Memory(romLocation: romLocation, timer: timer, interruptController: interruptController)
        cpu = CPU(memory: memory, interruptController: interruptController)
    }
    
    // The main runloop
    func run() -> Never {
        // Make sure the log file will be closed if it exists
        
        defer {
            if logFile != nil {
                try! logFile!.close()
            }
        }
        
        // Setup the log file if we're in Gameboy Doctor mode
        
        if GAMEBOY_DOCTOR {
            let path = "/Users/michael/Downloads/gameboy-doctor-master/myrun.txt";
            
            logFile = FileHandle(forWritingAtPath: path)
                        
        }
        
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
            
            // Print some debug stuff if in Gameboy Doctor mode
            
            if GAMEBOY_DOCTOR {
                do {
                    try logFile!.write(contentsOf: cpu.generateDebugLogLine().data(using: .utf8)!)
                } catch {
                    print("Error writing to log file! \(error.localizedDescription)")
                    exit(1)
                }
            }
            
            // Ok then, we need to execute the next opcode
            
            do {
                ticksUsed = try cpu.executeInstruction()
            } catch CPUErrors.InvalidInstruction(let op) {
                fatalError("Invalid instruction: \(toHex(op))")
            } catch CPUErrors.BadAddressForOpcode(let address) {
                fatalError("Invalid address for PC: \(toHex(address))")
            } catch CPUErrors.Stopped {
                print("CPU stopped by instruction, exiting")
                exit(0)
            } catch {
                fatalError("An unknown error occurred: \(error.localizedDescription)")
            }
        }
    }
}
