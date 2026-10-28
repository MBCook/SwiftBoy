//
//  EmulatorAudio.swift
//  Swift Boy
//
//  Created by Michael Cook on 10/27/26.
//

import Foundation
import AVKit

class AudioOutput {
    private let apu: APU
    private let audioEngine = AVAudioEngine()
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: true)!
    private let sourceNode: AVAudioSourceNode
    
    init(apu: APU) {
        self.apu = apu
        
        sourceNode = AVAudioSourceNode(format: audioFormat, renderBlock: {isSilence, _, frameCount, outputData in
            // Get ourselves a pointer
            
            guard let rawBuffer = outputData.pointee.mBuffers.mData else {
                isSilence.pointee = true
                return noErr
            }            

            // Make a buffer out of it
            
            let samples = UnsafeMutableBufferPointer(
                start: rawBuffer.assumingMemoryBound(to: Float32.self),
                count: Int(frameCount) * 2
            )
            
            // Copy the data
            
            apu.collectAudio(into: samples, frameCount: Int(frameCount))
            
            // Mark we added audio
            
            isSilence.pointee = false
            
            return noErr
        })
        
        let mixer = audioEngine.mainMixerNode
        
        audioEngine.attach(sourceNode)
        try! audioEngine.connectNode(sourceNode, to: mixer, format: nil)
        
        audioEngine.prepare()
    }
    
    func start() {
        try! audioEngine.start()
    }
    
    func stop() {
        audioEngine.stop()
    }
}
