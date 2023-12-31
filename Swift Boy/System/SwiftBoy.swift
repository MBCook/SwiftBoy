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
typealias Ticks = UInt8             // A tick is 1 cycle at 2^20th HZ (~1 MHz), which is the length of the shortest CPU instruction (e.g. nop)
typealias VolumeLevel = UInt8

let GAMEBOY_DOCTOR = false
let BLARGG_TEST_ROMS = false
let CONSOLE_DISPLAY = false

let CORRECT_FRAME_TIME_SECONDS = 1.0 / 60.0     // Aim for 60 frames per second
let FRAME_SAMPLE_COUNT = 60
let NANOSECONDS_IN_SECOND: Double = 1_000_000_000
let NANOSECONDS_IN_MILLISECOND: UInt64 = 1_000_000

class SwiftBoy: ObservableObject {
    // MARK: - Our private variables
    
    private var cpu: CPU
    private var memory: Memory
    private var timer: Timer
    private var interruptController: InterruptController
    private var ppu: PPU
    private var joypad: Joypad
    private var apu: APU
    
    private var logFile: FileHandle?
    
    private var screenCancellable: AnyCancellable!
    
    private var ticksUsed: Ticks
    private var paused: Bool
    private var frameCounter: Int
    
    private var frameTimes: [TimeInterval]!
    
    // MARK: - Our published variables
    
    @Published
    var screen: Image!
    
    // MARK: - Our public interface
    
    init(cartridge: Cartridge) throws {
        // Mark that we haven't run any instructions yet or done anything
        
        ticksUsed = 0
        frameCounter = 0
        paused = false
        frameTimes = Array(repeating: 1, count: FRAME_SAMPLE_COUNT)
        
        // Create the various objects we need and wire them up
        
        apu = APU()
        timer = Timer(apu: apu)
        joypad = Joypad()
        interruptController = InterruptController()
        
        let dmaController = DMAController()

        ppu = PPU(dmaController: dmaController)
        memory = Memory(cartridge: cartridge,
                        timer: timer,
                        interruptController: interruptController,
                        ppu: ppu,
                        joypad: joypad,
                        apu: apu)
        
        dmaController.setMemory(memory: memory)
        
        cpu = CPU(memory: memory, interruptController: interruptController)
        
        screen = renderFrame(nil)
        
        screenCancellable = ppu.$currentFrame.sink { [self] data in
            let frame = renderFrame(data)
            
            DispatchQueue.main.async {
                self.screen = frame
            }
        }
    }
    
    func pause() {
        print("Pausing")
        paused = true
    }
    
    func unpause() {
        print("Unpausing")
        paused = false
    }
    
    func reset() {
        // Since we're starting again, no ticks have occurred
        
        ticksUsed = 0
        frameCounter = 0
        paused = false
        frameTimes = Array(repeating: 1, count: FRAME_SAMPLE_COUNT)
        
        // Just call reset on all the objects and render a blank screen
        
        timer.reset()
        joypad.reset()
        apu.reset()
        interruptController.reset()
        ppu.reset()
        memory.reset()
        cpu.reset()
        
        screen = renderFrame(nil)
    }
    
    func loadGameAndReset(_ cartridge: Cartridge) {
        // Since we're starting again, no ticks have occurred
        
        ticksUsed = 0
        frameCounter = 0
        paused = false
        frameTimes = Array(repeating: 1, count: FRAME_SAMPLE_COUNT)
        
        // Just call reset on all the objects except memory, which gets the new cartridge, then render a blank screen
        
        timer.reset()
        joypad.reset()
        apu.reset()
        interruptController.reset()
        ppu.reset()
        memory.loadGameAndReset(cartridge)
        cpu.reset()
        
        screen = renderFrame(nil)
    }
    
    // The main runloop
    func run() async {
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
        
        // Inform the populace!
        
        print("Starting")
        
        while !paused {
            let frameStart = Date.now
            
            runForOneFrame()
            
            var frameIntervalSeconds = Date.now.timeIntervalSince(frameStart)  // Seconds since the frame started
            
            if frameIntervalSeconds < CORRECT_FRAME_TIME_SECONDS {
                let delayNanoseconds = UInt64((CORRECT_FRAME_TIME_SECONDS - frameIntervalSeconds) * NANOSECONDS_IN_SECOND)
                
                // The extra millisecond we take off gets us to almost exactly 60 FPs
                try! await Task.sleep(nanoseconds: delayNanoseconds - NANOSECONDS_IN_MILLISECOND)
                
                frameIntervalSeconds = Date.now.timeIntervalSince(frameStart)  // If we were running too fast, include the sleep
            }
            
            frameCounter &+= 1
            
            frameTimes[frameCounter % FRAME_SAMPLE_COUNT] = frameIntervalSeconds
            
            if frameCounter % 60 == 0 {
                printFrameStats()
            }
        }
    }
    
    // MARK: - Private methods
    
    private func printFrameStats() {
        let frameTimeSum = frameTimes.reduce(0, +)
        let frameTimeAverage = frameTimeSum / Double(FRAME_SAMPLE_COUNT)
        let minimumTime = frameTimes.min()! / frameTimeAverage * 100
        let maximumTime = frameTimes.max()! / frameTimeAverage * 100
        
        let fps = 1 / (frameTimeSum / Double(FRAME_SAMPLE_COUNT))
        let averageFrameTimeMS = frameTimeAverage * 1000
        
        print(String(format: "FPS: %.2f, Time: %.2fms, Min: %.2f%%, Max: %.2f%%", fps, averageFrameTimeMS, minimumTime, maximumTime))
    }
    
    private func runForOneFrame() {
        var vblankOccurred = false
        
        while !vblankOccurred {
            // First update the timer
            
            let timerInterrupt = timer.tick(ticksUsed)
            
            // If the timer wants an interrupt, trigger it
            
            if let timerInterrupt {
                interruptController.raiseInterrupt(timerInterrupt)
            }
            
            // Update the LCD controller status (it will update DMA controller for us)
            
            let lcdInterrupts = ppu.tick(ticksUsed)
            
            // If the LCD controller wants an interrupt, trigger it
            
            if let lcdInterrupts {
                lcdInterrupts.forEach { interruptController.raiseInterrupt($0) }
                
                if lcdInterrupts.contains(.vblank) {
                    // We stop after each VBlank so we can cap our framerate
                    // We'll actually excute one more instruction, but that's harmless
                    
                    vblankOccurred = true
                }
            }
            
            // Run the audio for one frame
            
            apu.tick(ticksUsed)
            
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
            } catch {
                if error is CPUErrors {
                    fatalError(error.localizedDescription)
                } else {
                    fatalError("An unknown error occurred: \(error.localizedDescription)")
                }
            }
        }
    }
    
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
