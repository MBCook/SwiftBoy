//
//  Swift_BoyApp.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import SwiftUI

@MainActor
@main
struct Swift_BoyApp: App {
    // MARK: - Our scene for our app
    
    var body: some Scene {
        WindowGroup {
            SwiftBoyView()
                .environmentObject(display)
                .onDisappear {
                    NSApplication.shared.terminate(self)
                }
        }
    }
    
    // MARK: - Private variables we need to keep track of
    
    private var display: EmulatorDisplay
    private var swiftBoy: SwiftBoy
    private var backgroundTask: Task<(), Never>!
    
    // MARK: - Public methods
    
    init() {
        // The file we want to load

        let romURL: URL
        
//        romURL = URL(filePath: "/Users/michael/Downloads/mooneye/manual-only/sprite_priority.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/GB/Dr. Mario.gb")
        romURL = URL(filePath: "/Users/michael/Downloads/GB/Kirby.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/GB/Super Mario Land.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/GB/Tetris.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/GB/Adventure Island.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/GB/Balloon Fight.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/GB/Bubble Bobble.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/GB/Link's Awakening.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/GB/Pokemon Yellow.gb")
        
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/cpu_instrs.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/instr_timing/instr_timing.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/dmg_sound/rom_singles/01-registers.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/dmg_sound/rom_singles/02-len ctr.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/dmg_sound/rom_singles/03-trigger.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/dmg_sound/rom_singles/04-sweep.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/dmg_sound/rom_singles/05-sweep details.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/dmg_sound/rom_singles/06-overflow on trigger.gb")
        
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/mem_timing/mem_timing.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/mem_timing/individual/01-read_timing.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/mem_timing/individual/02-write_timing.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/mem_timing/individual/03-modify_timing.gb")
//        romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/oam_bug/oam_bug.gb")
        
        do {
            // Create stuff
            
            let rom = try Data(contentsOf: romURL)
            let cartridge = try CartridgeHelper.loadROM(rom)
            
            display = EmulatorDisplay()
            
            let displayReference = display
            
            swiftBoy = try SwiftBoy(cartridge: cartridge, onFrame: {frame in
                await displayReference.showFrame(frame)
            })

            // Start things running
            
            backgroundTask = Task(priority: .userInitiated) {[self] in
                await swiftBoy.run()
            }
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}

