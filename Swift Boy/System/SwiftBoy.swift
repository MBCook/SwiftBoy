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
typealias Ticks = UInt8             // A tick is 1 cycle at 2^20th HZ (~1 MHz), which is the length of the shortest CPU instruction (e.g. nop)
typealias VolumeLevel = UInt8
typealias SoundSample = Float32

typealias AsyncFrameCallback = @Sendable (Data?) async -> Void
typealias FrameCallback = @Sendable (Data?) -> Void

let GAMEBOY_DOCTOR = false
let BLARGG_TEST_ROMS = true
let CONSOLE_DISPLAY = false

let CORRECT_FRAME_TIME_SECONDS = 1.0 / 60.0     // Aim for 60 frames per second
let FRAME_SAMPLE_COUNT = 60
let NANOSECONDS_IN_SECOND: Double = 1_000_000_000
let NANOSECONDS_IN_MILLISECOND: UInt64 = 1_000_000

actor SwiftBoy {
    // MARK: - Our private variables
    
    private var cpu: CPU
    private var memory: Memory
    private var timer: Timer
    private var interruptController: InterruptController
    private var ppu: PPU
    private var joypad: Joypad
    private var apu: APU
    
    private var logFile: FileHandle?
    
    private var ticksUsed: Ticks
    private var paused: Bool
    private var frameCounter: Int
    
    private var frameTimes: [TimeInterval]!
    
    private var onFrame: AsyncFrameCallback
    
    // MARK: - Our public interface
    
    init(cartridge: Cartridge, onFrame: @escaping AsyncFrameCallback) throws {
        // Mark that we haven't run any instructions yet or done anything
        
        ticksUsed = 0
        frameCounter = 0
        paused = false
        frameTimes = Array(repeating: 1, count: FRAME_SAMPLE_COUNT)
        self.onFrame = onFrame
        
        // Create the various objects we need and wire them up
        
        apu = APU()
        timer = Timer(apu: apu)
        joypad = Joypad()
        interruptController = InterruptController()
        
        let dmaController = DMAController()

        apu.reset()
        ppu = PPU(dmaController: dmaController, onFrame: {frame in
            Task {
                await onFrame(frame)
            }
        })
        memory = Memory(cartridge: cartridge,
                        timer: timer,
                        interruptController: interruptController,
                        ppu: ppu,
                        joypad: joypad,
                        apu: apu)
        
        dmaController.setMemory(memory: memory)
        
        cpu = CPU(memory: memory, interruptController: interruptController)
    }
    
    func pause() {
        print("Pausing")
        paused = true
    }
    
    func unpause() {
        print("Unpausing")
        paused = false
    }
    
    func reset() async {
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
        
        await onFrame(nil)  // To signal a screen reset
    }
    
    func loadGameAndReset(_ cartridge: Cartridge) async {
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
        
        await onFrame(nil)  // To signal a screen reset
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
            let path = "/Users/michael/Documents/ROMs/GB/gameboy-doctor-master/myrun.txt"
            
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
            
//            if frameCounter % 60 == 0 {
//                printFrameStats()
//            }
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
}
