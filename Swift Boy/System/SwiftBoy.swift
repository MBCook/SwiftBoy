//
//  SwiftBoy.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/7/22.
//

import Foundation
import SwiftUI
import Combine

typealias Address = UInt16
typealias Bitmask = UInt8
typealias Cycles = UInt8
typealias Register = UInt8
typealias RegisterPair = UInt16
typealias Ticks = UInt8

let GAMEBOY_DOCTOR = false
let BLARGG_TEST_ROMS = false
let CONSOLE_DISPLAY = false

class SwiftBoy: ObservableObject {
    // MARK: - Our private variables
    
    private var cpu: CPU
    private var memory: Memory
    private var timer: Timer
    private var interruptController: InterruptController
    private var ppu: PPU
    private var joypad: Joypad
    
    private var paused: Bool
    private var logFile: FileHandle?
    
    private var screenCancellable: AnyCancellable!
    
    // MARK: - Our published variables
    
    @Published
    var screen: Image!
    
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
        
        screen = renderFrame(nil)
        
        screenCancellable = ppu.$currentFrame.sink { [self] data in
            let frame = renderFrame(data)
            
            DispatchQueue.main.async {
                self.screen = frame
            }
        }
    }
    
    func pause() {
        paused = true
    }
    
    func reset() {
        // Just call reset on all the objects and render a blank screen
        
        timer.reset()
        joypad.reset()
        interruptController.reset()
        ppu.reset()
        memory.reset()
        cpu.reset()
        
        screen = renderFrame(nil)
    }
    
    func loadGameAndReset(_ cartridge: Cartridge) {
        // Just call reset on all the objects except memory, which gets the new cartridge, then render a blank screen
        
        timer.reset()
        joypad.reset()
        interruptController.reset()
        ppu.reset()
        memory.loadGameAndReset(cartridge)
        cpu.reset()
        
        screen = renderFrame(nil)
    }
    
    // The main runloop
    func run() {
        // Make sure the log file will be closed if it exists
        
        defer {
            if let logFile {
                try! logFile.close()
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
    
    // MARK: - Private methods
    
    private func renderFrame(_ data: Data?) -> Image {
        guard data != nil else {
            return Image("Blank")
        }
        
        // Ok, we've got stuff to render to an image
        
        return Image(size: CGSize(width: PIXELS_WIDE, height: PIXELS_TALL), opaque: true, colorMode: .nonLinear) { gc in
            // Palette is called TU GBP Clean from https://github.com/trashuncle/Gameboy_Palettes
            
            let palette = [
                CGColor(red: 0xF0 / 256.0, green: 0xFE / 256.0, blue: 0xF8 / 256.0, alpha: 1.0),    // White
                CGColor(red: 0xB0 / 256.0, green: 0xC2 / 256.0, blue: 0xAD / 256.0, alpha: 1.0),    // Light
                CGColor(red: 0x9B / 256.0, green: 0xA4 / 256.0, blue: 0x95 / 256.0, alpha: 1.0),    // Dark
                CGColor(red: 0x37 / 256.0, green: 0x41 / 256.0, blue: 0x35 / 256.0, alpha: 1.0)     // Black
            ]
            
            // Do the drawing
            
            gc.withCGContext { context in
                for y in 0..<PIXELS_TALL {
                    for x in 0..<PIXELS_WIDE {
                        let start = y * PIXELS_WIDE
                        context.setFillColor(palette[Int(data![start + x])])
                        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
        }
    }
}
