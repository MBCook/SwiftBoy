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
        
        //let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/03-op sp,hl.gb")
        let romURL = URL(filePath: "/Users/michael/Downloads/gb-test-roms-master/cpu_instrs/individual/04-op r,imm.gb")
        
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
