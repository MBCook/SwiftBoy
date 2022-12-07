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
        
        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/01-special.gb")
//x        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/02-interrupts.gb")
//+        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/03-op sp,hl.gb")
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
            let memory = try Memory(romLocation: romURL)
            
            // Create a CPU
            
            let cpu = CPU(memory: memory)
            
            cpu.run()
        } catch {
            print("Error occured: \(error.localizedDescription)")
        }
    }
}
