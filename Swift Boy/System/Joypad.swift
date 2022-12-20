//
//  Joypad.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/18/22.
//

import Foundation
import GameController

private enum JoypadBits {
    static let actionButtons: Bitmask = 0x20
    static let directionButtons: Bitmask = 0x10
    static let downStart: Bitmask = 0x08
    static let upSelect: Bitmask = 0x04
    static let leftB: Bitmask = 0x02
    static let rightA: Bitmask = 0x01
}

class Joypad: MemoryMappedDevice {
    
    // MARK: - Our private data
    
    // NOTE: Joypad stuff is all active low. We'll keep everything normal (true = on) and alter our input/output to what a Game Boy does
    
    private var upButton = false                        // The state of each button
    private var downButton = false
    private var leftButton = false
    private var rightButton = false
    private var bButton = false
    private var aButton = false
    private var selectButton = false
    private var startButton = false
    
    private var actionSelected = false                  // If they're trying to find anything
    private var directionSelected = false
    
    private var buttonPressedSinceLastTick = false      // Used to track if we need to do a joypad interrupt
    
    // MARK: - Public interface
    
    init() {
        // Tell the OS to start watching for game controllers
        
        GCController.startWirelessControllerDiscovery()
        
        // Let's just say everything is unpressed
        
        reset()
    }
    
    func reset() {
        // Just initialize everything as unpressed (false)
        
        upButton = false
        downButton = false
        leftButton = false
        rightButton = false
        bButton = false
        aButton = false
        selectButton = false
        startButton = false
        
        actionSelected = false
        directionSelected = false
        
        buttonPressedSinceLastTick = false
    }
    
    func tick(_ ticks: Ticks) -> InterruptSource? {
        // We only care that time moved to trigger interrupts
        
        if buttonPressedSinceLastTick {
            buttonPressedSinceLastTick = false
            
            return .joypad
        } else {
            return nil
        }
    }
    
    // MARK: - Private functions
    
    private func readJoystick() {
        if let controller = GCController.current?.extendedGamepad {
            // The right kind of controller is connected. Update the states of the buttons they asked for
            
            if directionSelected {
                updateButton(&upButton, to: controller.dpad.up.isPressed)
                updateButton(&downButton, to: controller.dpad.down.isPressed)
                updateButton(&leftButton, to: controller.dpad.left.isPressed)
                updateButton(&rightButton, to: controller.dpad.right.isPressed)
            } else if actionSelected {
                updateButton(&selectButton, to: controller.buttonOptions?.isPressed ?? false)   // If there is no options button, uh oh
                updateButton(&startButton, to: controller.buttonMenu.isPressed)
                updateButton(&bButton, to: controller.buttonA.isPressed)    // Apple used Xbox names, which is backwards of Nintendo
                updateButton(&aButton, to: controller.buttonB.isPressed)
            }
        }
    }
    
    private func updateButton(_ button: inout Bool, to: Bool) {
        if button == false && to == true {
            // A button was pressed, signal an interrupt on the next tick
            
            buttonPressedSinceLastTick = true
        }
        
        // Save the new state
        
        button = to
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        switch address {
        case MemoryLocations.joypad:
            // When they read this register, they want the actual results.
            // So if one of the select bits is on we'll read the state of the joystick right now.
            
            if actionSelected || directionSelected {
                readJoystick()
            }
            
            // They want the state of everything. Build it up and then invert it so it looks the way ROMs expect
            
            var result = UInt8(0x00)
            
            result |= actionSelected ? JoypadBits.actionButtons : 0
            result |= directionSelected ? JoypadBits.directionButtons : 0
            
            if actionSelected && directionSelected {
                // This is invalid for a normal Game Boy, but games use it to talk to the Super Game Boy
                // We'll ignore it and set all direction bits to off as if they didn't assert eithr direction or action
            } else if actionSelected {
                result |= startButton ? JoypadBits.downStart : 0
                result |= selectButton ? JoypadBits.upSelect : 0
                result |= bButton ? JoypadBits.leftB : 0
                result |= aButton ? JoypadBits.rightA : 0
            } else if directionSelected {
               result |= downButton ? JoypadBits.downStart : 0
               result |= upButton ? JoypadBits.upSelect : 0
               result |= leftButton ? JoypadBits.leftB : 0
               result |= rightButton ? JoypadBits.rightA : 0
           }
            
            return result ^ 0xFF    // To flip all the bits from how we work (active high) to how ROMs expect it (active low)
        default:
            fatalError("The joypad should not have been asked for memory address 0x\(toHex(address))")
        }
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        switch address {
        case MemoryLocations.joypad:
            // We only care about the two control bits, so we'll read those
            
            actionSelected = value & JoypadBits.actionButtons == 0          // 0 means selected, not 1
            directionSelected = value & JoypadBits.directionButtons == 0
        default:
            fatalError("The joypad should not have been asked to set memory address 0x\(toHex(address))")
        }
    }
}
