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

            let palette = [
                CGColor(red: 0xF0 / 256.0, green: 0xFE / 256.0, blue: 0xF8 / 256.0, alpha: 1.0),    // White
                CGColor(red: 0xB0 / 256.0, green: 0xC2 / 256.0, blue: 0xAD / 256.0, alpha: 1.0),    // Light
                CGColor(red: 0x9B / 256.0, green: 0xA4 / 256.0, blue: 0x95 / 256.0, alpha: 1.0),    // Dark
                CGColor(red: 0x37 / 256.0, green: 0x41 / 256.0, blue: 0x35 / 256.0, alpha: 1.0)     // Black
            ]

            // Do the drawing

            gc.withCGContext { context in
                for y in 0..<PIXELS_TALL {
                    for x in 0..<PIXELS_WIDE {
                        let start = y * PIXELS_WIDE
                        context.setFillColor(palette[Int(frame![start + x])])
                        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
        }
    }
}
