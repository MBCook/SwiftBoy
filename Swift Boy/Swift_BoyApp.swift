//
//  Swift_BoyApp.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import SwiftUI

@main
struct Swift_BoyApp: App {
    // MARK: - Our scene for our app
    
    var body: some Scene {
        WindowGroup {
            SwiftBoyView()
                .environmentObject(swiftBoy)
                .onDisappear {
                    NSApplication.shared.terminate(self)
                }
        }
    }
    
    // MARK: - Private variables we need to keep track of
    
    private var swiftBoy: SwiftBoy
    private var backgroundTask: Task<(), Never>!
    
    // MARK: - Public methods
    
    init() {
        // The file we want to load
   
//-        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/halt_bug.gb")
        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/cpu_instrs.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/instr_timing/instr_timing.gb")
//CGB        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/interrupt_time/interrupt_time.gb")
        
        do {
            // Create stuff
            
            let rom = try Data(contentsOf: romURL)
            let cartridge = try CartridgeHelper.loadROM(rom)
            let boy = try SwiftBoy(cartridge: cartridge)

            // Save a reference
            
            swiftBoy = boy
            
            // Start things running
            
            backgroundTask = Task.detached(priority: .userInitiated) {
                boy.run()
            }
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}
