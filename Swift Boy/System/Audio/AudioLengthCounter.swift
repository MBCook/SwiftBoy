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
    
    var enabled: Bool = false
    var disableChannel: (() -> Void)? = nil
    
    var channelNumber: Int = 0
    
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
            
            print("Channel", channelNumber, "now at", counter)
        }
        
        // If we're at zero now, we need to trigger our channel to be disabled through the callback
        
        if counter == 0 {
            print("\t\tChannel", channelNumber, "length counter has hit 0, calling disable()")
            disableChannel!()
        }
    }
    
    func enableTimer() {
        print("\t\tChannel", channelNumber, " length counter being enabled")
        enabled = true
    }
    
    func disableTimer() {
        print("\t\tChannel", channelNumber, " length counter being disabled")
        enabled = false
    }
    
    func trigger() {
        guard enabled else {
            print("\t\tChannel", channelNumber, " was not enabled, ignoring trigger")
            return
        }
        
        // If the length counter is 0, reset it to the max
        
        if counter == 0 {
            print("\t\tChannel", channelNumber, "triggered with counter at 0, resetting to ", maxTimerValue)
            counter = maxTimerValue
        }
    }
}
