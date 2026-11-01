//
//  EmulatorDisplay.swift
//  Swift Boy
//
//  Created by Michael Cook on 10/26/26.
//

import Foundation
import SwiftUI

@MainActor
final class EmulatorDisplay: ObservableObject {
    @Published private(set) var image = Image("Blank")

    func showFrame(_ frame: Data?) {
        guard frame != nil else {
            image = Image("Blank")
            return
        }

        // Ok, we've got stuff to render to an image

        image = Image(size: CGSize(width: PIXELS_WIDE, height: PIXELS_TALL), opaque: true, colorMode: .nonLinear) { gc in
            // Palette is called TU GBP Clean from https://github.com/trashuncle/Gameboy_Palettes
            // Colors are in order of white, light, dark, black
            
            let reds: [UInt8] = [0xF0, 0xB0, 0x9B, 0x37]
            let greens: [UInt8] = [0xFE, 0xC2, 0xA4, 0x41]
            let blues: [UInt8] = [0xF8, 0xAD, 0x95, 0x35]
            
            // Do the drawing

            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: PIXELS_WIDE,
                pixelsHigh: PIXELS_TALL,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 3 * PIXELS_WIDE,
                bitsPerPixel: 24
            )!
            
            var destination = bitmap.bitmapData!
            
            frame!.withUnsafeBytes { source in
                for i in 0..<PIXELS_TALL * PIXELS_WIDE {
                    let color = Int(frame![i])
                    
                    destination.pointee = reds[color]
                    destination = destination.advanced(by: 1)
                    destination.pointee = greens[color]
                    destination = destination.advanced(by: 1)
                    destination.pointee = blues[color]
                    destination = destination.advanced(by: 1)
                }
            }
            
            gc.withCGContext { context in
                context.interpolationQuality = .none
                context.translateBy(x: 0, y: CGFloat(PIXELS_TALL))
                context.scaleBy(x: 1, y: -1)
                context.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: PIXELS_WIDE, height: PIXELS_TALL))
            }
        }
    }
}
