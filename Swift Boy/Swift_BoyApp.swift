//
//  Swift_BoyApp.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import SwiftUI

@main
struct Swift_BoyApp: App {
    // TODO: This gets ignored if there is a main function, so we'll need to remove Main when we're ready to go GUI
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
    
    static func main() {
        // The file we want to load
   
//-        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/halt_bug.gb")
        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/cpu_instrs.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/instr_timing/instr_timing.gb")
//CGB        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/interrupt_time/interrupt_time.gb")
        
        // Create memory with that rom
        
        do {
            let rom = try Data(contentsOf: romURL)
            let cartridge = try CartridgeHelper.loadROM(rom)
            let swiftBoy = try SwiftBoy(cartridge: cartridge)

            swiftBoy.run()
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}
