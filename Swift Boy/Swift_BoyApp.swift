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
   
//?        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/halt_bug.gb")
    //let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/cpu_instrs.gb")
//?        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/instr_timing/instr_timing.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/02-interrupts.gb")
        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/03-op sp,hl.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/04-op r,imm.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/05-op rp.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/06-ld r,r.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/07-jr,jp,call,ret,rst.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/08-misc instrs.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/09-op r,r.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/10-bit ops.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/11-op a,(hl).gb")
        
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
