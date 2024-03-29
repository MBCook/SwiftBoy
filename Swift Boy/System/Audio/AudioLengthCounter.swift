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
            // Setting it to X (say 15) sets the timer to maxValue - X
            // So for a max of 64 and set to 60, counter = 4 and will hit zero in 4 length counter ticks
            // This also has the effect where setting it 0 sets it to the max, which matches the hardware
            
            counter = maxTimerValue - UInt16(value)
        }
    }
    var equalsZero: Bool {
        get {
            return counter == 0
        }
    }
    
    var enabled: Bool = false
    var disableChannel: (() -> Void)? = nil
    
    // MARK: - Private variables
    
    private var counter: RegisterPair = 0       // Needs to be big enough to hold 256
    private let maxTimerValue: RegisterPair     // Same
    
    // MARK: - Public methods
    
    init(_ maxTimerValue: RegisterPair) {
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
        
        // If we're at zero now, we need to disabled the channel through the callback
        
        if counter == 0 {
            disableChannel!()
        }
    }
    
    func setToMaxAndDecrement() {
        counter = maxTimerValue - 1;
    }
    
    func performExtraDecrement(andDisableIfZero: Bool) {
        if counter > 0 {
            counter -= 1
        }
        
        if andDisableIfZero && counter == 0 {
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
        if counter == 0 {
            // If the length counter is 0, reset it to the max
            // We do this even if the length counter is disabled when the trigger happens
        
            counter = maxTimerValue
        }
    }
}
