//
//  AudioLengthCounter.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/30/23.
//

import Foundation

class AudioLengthCounter {
    // MARK: - Public variables
    
    var initalLength: Register {
        get {
            abort()         // No one should ever read this
        }
        set (value) {
            counter = value
            
            if counter == 0 {
                disableChannel!()
            }
        }
    }
    var enabled: Bool = false
    var disableChannel: (() -> Void)? = nil
    
    // MARK: - Private variables
    
    private var counter: Register = 0
    private let maxTimerValue: Register
    
    // MARK: - Public methods
    
    init(_ maxTimerValue: Register) {
        self.maxTimerValue = maxTimerValue
    }
    
    func tickLengthCounter() {
        // If we're not enabled, don't do anything
        
        guard enabled else {
            return
        }
        
        // Decrement the timer but don't let it go below 0
        
        if counter > 0 {
            counter -= 1
        }
        
        // If we're at zero now, we need to trigger our channel to be disabled through the callback
        
        if counter == 0 {
            disableChannel!()
        }
    }
    
    func enableTimer() {
        enabled = true
    }
    
    func disableTimer() {
        enabled = false
    }
    
    func trigger() {
        // If the length counter is 0, reset it to the max
        
        if counter == 0 {
            counter = maxTimerValue
        }
    }
}
