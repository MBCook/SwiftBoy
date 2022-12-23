//
//  PPU.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/11/22.
//

import Foundation

private let LCD_CONTROL: Address = 0xFF40
private let LCD_STATUS: Address = 0xFF41
private let VIEWPORT_Y: Address = 0xFF42
private let VIEWPORT_X: Address = 0xFF43
private let LCD_Y_COORDINATE: Address = 0xFF44
private let LCD_Y_COMPARE: Address = 0xFF45
private let DMA_REGISTER: Address = 0xFF46
private let BACKGROUND_PALETTE: Address = 0xFF47
private let SPRITE_PALETTE_ZERO: Address = 0xFF48
private let SPRITE_PALETTE_ONE: Address = 0xFF49
private let WINDOW_Y: Address = 0xFF4A
private let WINDOW_X: Address = 0xFF4B

private let OAM_ENTRIES: UInt8 = 4
private let BYTES_PER_OAM = 4
private let OAM_Y_POSITION: UInt8 = 0
private let OAM_X_POSITION: UInt8 = 1
private let OAM_TILE_INDEX: UInt8 = 2
private let OAM_ATTRIBUTES: UInt8 = 3

private enum LCDControl {
    static let lcdEnable: UInt8 = 0x80
    static let windowTilemapArea: UInt8 = 0x40
    static let windowEnable: UInt8 = 0x20
    static let bgWindowTileDataArea: UInt8 = 0x10
    static let bgTilemapArea: UInt8 = 0x08
    static let objectSize: UInt8 = 0x04
    static let objectEnable: UInt8 = 0x02
    static let bgWindowEnable: UInt8 = 0x01
}

private enum LCDStatus {
    static let yCompareInterruptSource: UInt8 = 0x40
    static let oamInterruptSource: UInt8 = 0x20
    static let vBankInterruptSource: UInt8 = 0x10
    static let hBlankInterruptSource: UInt8 = 0x08
    static let yCompareStatus: UInt8 = 0x04
}

private enum LCDMode {
    static let horizontablBlank: UInt8 = 0x00
    static let verticalBlank: UInt8 = 0x01
    static let searchingOAM: UInt8 = 0x02
    static let drawingToLCD: UInt8 = 0x03
    
    static let oamBlockedStatus: ClosedRange = LCDMode.searchingOAM...LCDMode.drawingToLCD  // The statuses where OAM is blocked
}

private enum LCDColors {
    static let white: UInt8 = 0x00
    static let lightGray: UInt8 = 0x01
    static let darkGray: UInt8 = 0x02
    static let black: UInt8 = 0x03
}

private enum OAMAttributes {
    static let backgroundWindowOverObject: UInt8 = 0x80
    static let yFlip: UInt8 = 0x40
    static let xFlip: UInt8 = 0x20
    static let paletteNumber: UInt8 = 0x10
}

private typealias ColorIndex = UInt8
private typealias FinalColor = UInt8
private typealias OAMOffset = UInt8
private typealias TileMapOffset = UInt16
private typealias ColumnNumber = UInt8
private typealias LineNumber = UInt8
private typealias PixelCoordinate = Int16       // We have to deal with negative numbers and numbers over 127, so UInt8 and Int8 won't work

class PPU: MemoryMappedDevice {
    
    // MARK: - Our private data
    
    private var videoRAM: Data!                 // Built in RAM to hold sprites and tiles
    private var oamRAM: Data!                   // RAM that controls sprite/timemap display
    
    private var ppuMode: Register = 0           // Current PPU mode
    private var ticksIntoLine: UInt16 = 0
    
    private var dmaController: DMAController    // The DMA controller only exists to help the PPU by moving data fast
    
    // MARK: - Our registers
    
    private var lcdControl: Register = 0
    private var _lcdStatus: Register = 0        // The REAL LCD status register
    private var lcdStatus: Register {           // The fake one to handle making reads and writes easy
        get {
            // We don't really store the current mode in the register, so add it in on read
            return _lcdStatus | ppuMode
        }
        set (value) {
            // You may not write to bits 3-6, so we'll mask off everything else
            // That also means we're only keeping bits 0-2 of the current status register (bit 7 isn't used)
            _lcdStatus = value & 0x78
        }
    }
    private var viewportY: Register = 0
    private var viewportX: Register = 0
    private var lcdYCoordinate: Register = 0
    private var lcdYCompare: Register = 0
    private var backgroundPalette: Register = 0
    private var spritePaletteZero: Register = 0
    private var spritePaletteOne: Register = 0
    private var windowY: Register = 0
    private var windowX: Register = 0
    
    // MARK: - Public interface
    
    init(dmaController: DMAController) {
        // Save references to the other objects
        
        self.dmaController = dmaController
        
        // Setup the rest the way it is on startup
        
        reset()
    }
    
    func reset() {
        // Setup the bits of RAM we control
        
        videoRAM = Data(count: Int(EIGHT_KB))
        oamRAM = Data(count: 160)
        
        // Setup our registers based on what the boot ROM would
        
        backgroundPalette = 0xFC    // Set by bootup sequence
        lcdControl = LCDControl.lcdEnable | LCDControl.bgWindowTileDataArea | LCDControl.bgWindowEnable
        
        // And set a sane statuses
        
        lcdYCoordinate = 144                    // The first line of the vertical blank period
        _lcdStatus = 0                          // Nothing special going on (current mode is ORed in on read)
        ticksIntoLine = 0
        ppuMode = LCDMode.verticalBlank
        
        // The rest we'll just set to 0x00 unless the hardware sets it based on state like the LCD status
        
        viewportY = 0x00
        viewportX = 0x00
        lcdYCoordinate = 0x00
        lcdYCompare = 0x00
        windowY = 0x00
        windowX = 0x00
        spritePaletteZero = 0b11100100          // Sane palette. 3 = black, 2 = dark grey, 1 = light grey, 0 = white
        spritePaletteOne = 0b11100100
        
        // Tell the DMA controller that we own to reset
        
        dmaController.reset()
    }
    
    func dmaInProgress() -> Bool {
        // It's the DMA controller's job to know this
        return dmaController.dmaInProgress()
    }
    
    func tick(_ ticks: Ticks) -> InterruptSource? {
        // If the LCD is off, we don't draw or do anything.
        
        guard lcdControl & LCDControl.lcdEnable > 0 else {
            return nil
        }
        
        // First, update the DMA controller
        
        dmaController.tick(ticks)
        
        // Now update our modes and do drawing work if necessary
        
        ticksIntoLine += UInt16(ticks)
        
        var needsInterrupt = false
        
        // We only act if something needs to change (end of mode or line)
        
        if ticksIntoLine > 456 {
            // Line is over, go to next line
            
            ticksIntoLine %= 456
            
            lcdYCoordinate += 1
            
            if lcdYCoordinate > 153 {
                // Time for a new screen!
                
                lcdYCoordinate = 0
                ppuMode = LCDMode.searchingOAM
                
                needsInterrupt = (lcdStatus & LCDStatus.oamInterruptSource) > 0    // Flag interrupt if needed
            } else if lcdYCoordinate >= 144 && ppuMode != LCDMode.verticalBlank {
                // We're doing the vertical blank now, set it up
                ppuMode = LCDMode.verticalBlank
                
                needsInterrupt = (lcdStatus & LCDStatus.vBankInterruptSource) > 0  // Flag interrupt if needed
                
                if CONSOLE_DISPLAY {
                    print(String(repeating: "-", count: 160))
                }
            } else if ppuMode != LCDMode.verticalBlank {
                // Just a normal new line when not in the vertical blank
                
                ppuMode = LCDMode.searchingOAM
                
                needsInterrupt = (lcdStatus & LCDStatus.oamInterruptSource) > 0    // Flag interrupt if needed
            }
        } else if ppuMode != LCDMode.verticalBlank {
            // In vertical blank there is nothing to do during a line, so only act if that's not what's going on
            
            if ticksIntoLine > 80 && ticksIntoLine <= 252 && ppuMode != LCDMode.drawingToLCD {
                // Transition to drawing mode. We'll pretend it ALWAYS takes 172 ticks instead of variable like a real GameBoy
                // As soon as this mode starts we'll draw the line for output by calling drawLine()
                
                ppuMode = LCDMode.drawingToLCD
                
                let colorData = drawLine()
                
                if CONSOLE_DISPLAY {
                    let colors = [" ", "░", "▒", "▓"]
                    
                    let colorCharacters = colorData.map({colors[Int($0)]}).joined()
                    
                    print(colorCharacters)
                }
            } else if ticksIntoLine > 252 && ppuMode != LCDMode.horizontablBlank {
                // Transition to Horizontal Blank
                
                ppuMode = LCDMode.horizontablBlank
                
                needsInterrupt = (lcdStatus & LCDStatus.hBlankInterruptSource) > 0  // Flag interrupt if needed
            }
        }
        
        // Always update then check the Y coordinate compare register
        
        let yMatches = lcdYCompare == lcdYCoordinate
        
        lcdStatus = lcdStatus & (0xFF - LCDStatus.yCompareStatus) | (yMatches ? LCDStatus.yCompareStatus : 0x00)
        
        needsInterrupt = needsInterrupt || (lcdStatus & LCDStatus.yCompareStatus) > 0   // Flag interrupt if needed
        
        // Return an interrupt if needed
        
        return needsInterrupt ? .lcdStat : nil
    }
    
    // MARK: - Private methods for rending a line of pixels
    
    private func drawLine() -> [FinalColor] {
        // We have functions to render everything we should need, we just need to put the pieces together.
        // Let's gather the data we'll need and take the built in offsets into account
        
        let backgroundStart = viewportX
        let windowStart = Int(windowX) - 7
        
        var (bgColors, bgWasZero) = getFullBackgroundWindowLine(line: findBackgroundYCoordinate(), background: true) ?? (nil, nil)
        var (windowColors, windowWasZero) = getFullBackgroundWindowLine(line: findWindowYCoordinate(), background: false) ?? (nil, nil)
        let (spriteColors, backgroundPriority) = getFullSpritesLine()
        
        // Based on positioning, we may need to expand our background because it repeats (if it's there)
        // Either way extract the 160 elements we need from the array
        
        if bgColors != nil && Int(backgroundStart) + 160 > 255 {
            // OK, the bakcground will need to wrap because the viewport goes off the side.
            // To do that just append copies of the arrays after themselves. Nice and easy.
            
            bgColors!.append(contentsOf: bgColors!)
            bgWasZero!.append(contentsOf: bgWasZero!)
        }
        
        if bgColors != nil {
            bgColors = Array(bgColors!.dropFirst(Int(backgroundStart)).prefix(160))
            bgWasZero = Array(bgWasZero!.dropFirst(Int(backgroundStart)).prefix(160))
        }
        
        // Now we do the window. We'll have to add elements if the position isn't 0 (after we fixed the offset above).
        // Then either way take the 160 pixels we need if the window exists.
        
        if windowColors != nil && windowStart < 0 {
            // Window starts before the screen, so add extra elements on the end so when we take 160 there are enough.
            
            windowColors!.append(contentsOf: Array(repeating: 0, count: abs(windowStart)))
            windowWasZero!.append(contentsOf: Array(repeating: true, count: abs(windowStart)))
        } else if windowColors != nil && windowStart > 0 {
            // The window doesn't start at pixel 0, so we'll need extra elements on the front
            
            windowColors!.insert(contentsOf: Array(repeating: 0, count: windowStart), at:0)
            windowWasZero!.insert(contentsOf: Array(repeating: true, count: windowStart), at:0)
        }
        
        // We have enough elements on both arrays (if needed) we can take pixels from them without worry of causing an exception
        
        var finalPixels = Array(repeating: LCDColors.white, count: 160)     // Initial value before we combine things
        
        for x in 0..<160 {
            let bgWindowColor = windowColors?[x] ?? bgColors?[x]        // Window if we have it, BG if not, nil if neither
            let bgWindowWasZero = windowWasZero?[x] ?? bgWasZero?[x]    // Same thing with if the color was zero
            let spriteColor = spriteColors[x]                           // The sprite pixel if there is one
            let spriteBGPriority = backgroundPriority[x]                // If that sprite pixel has BG priority on it
            
            // What we do depends on if there is background priority
            
            if spriteBGPriority && bgWindowWasZero == true {
                // A non-zero background or window pixel will cover the sprite. Since bgWindowWasZero is not nil, the color won't be
                
                finalPixels[x] = bgWindowColor!
            } else if let spriteColor {
                // The sprite has priority, or the background/window was index 0 which is always behind the sprite
                
                finalPixels[x] = spriteColor
            } else if let bgWindowColor {
                // Last chance. No sprite pixel (or it was transparent) so it's background/window time.
                // If those are off, the default white color we set when creating the array wins.
                
                finalPixels[x] = bgWindowColor
            }
        }
        
        return finalPixels
    }
    
    private func getFullBackgroundWindowLine(line: LineNumber?, background: Bool) -> ([FinalColor], [Bool])? {
        guard line != nil else {
            return nil
        }
        
        // First we need the tile map data base address
        
        let tileMapArea = lcdControl & (background ? LCDControl.bgTilemapArea : LCDControl.windowTilemapArea)
        let baseAddress = tileMapArea > 0 ? MemoryLocations.videoRAMHighTileMap : MemoryLocations.videoRAMLowTileMap
        
        // We were given a y coordinates against the 256x256 map
        // Tiles are 8x8 so figure out while tile (vertically) we're in
        
        let yTile = line! / 8
        
        // Now we can loop across the whole 32 tile/256 pixel background and generate a color array
        // This is not how the Game Boy does it (it goes one pixel at a time and only the necessary pixels)
        // but this is easy and we have plenty of processor to spare. A later step can crop and mix things as needed.
        
        var finalColors: [FinalColor] = []  // The final color of each pixel after applying the palette
        var colorWasZero: [Bool] = []       // If the color index of the background pixel (before palette) was 0
        
        for x in 0..<32 {
            let mapIndex = UInt16(yTile) * 32 + UInt16(x)
            
            // With that index we can get the index into the tile set to get data for
            
            let tileIndex = videoRAM[Int(baseAddress + mapIndex - MemoryLocations.videoRAMRange.lowerBound)]
            
            // With that index we can get the address for the actual data, figure out the color indexes, and apply the fixed palette
            
            let dataAddress = getBackgroundWindowAddress(tileIndex)
            let colorIndexes = findColorData(line: line! % 8, baseAddress: dataAddress)
            
            // We're going to return two arrays. The first is the final colors of the line, the second is which color(s) were index 0.
            // We need to know the index 0 stuff for the "background over sprite" option
            
            finalColors.append(contentsOf: applyPalette(backgroundPalette, colorIndexes,
                                                        transparency: false).map({$0!}))    // There will be no nils, so force unwrap is OK
            colorWasZero.append(contentsOf: colorIndexes.map({$0 == 0}))
        }
        
        return (finalColors, colorWasZero)
    }
    
    private func getFullSpritesLine() -> ([FinalColor?], [Bool]) {
        // Let's get the sprites on our line
        
        let spritesOnLine = findSpritesForLine()
        
        // Now we can loop across the whole 160 pixel resolution finding what sprite and pixel (if any) are on that column
        // This is roughly how the real Game Boy does it. After applying the palette nil will represent transparent.
        // We'll also return a boolean array indicating which pixels have the background over sprite property set.
        
        var finalColors: [FinalColor?] = Array(repeating: nil, count: 160)      // The final color of each pixel after applying the palette
        var backgroundPriority: [Bool] = Array(repeating: false, count: 160)    // If the pixel has background over sprite set
        
        guard spritesOnLine.count > 0 else {
            // If there are no sprites we're already done
            
            return (finalColors, backgroundPriority)
        }
        
        // Let's render each sprite into a little array so we can easily pixel-peek at it and put it in a dictionary.
        // We'll do the same with other data
        
        var spriteData: [OAMOffset:[FinalColor?]] = [:]
        var spriteBGPriority: [OAMOffset:Bool] = [:]
        var spriteColumnRange: [OAMOffset:Range<Int16>] = [:]
        
        for (sprite, line) in spritesOnLine {
            let startX = findSpriteX(sprite)
            let endX = startX + 8
            
            spriteData[sprite] = getIndividualSpriteLine(line: line, sprite: sprite)
            spriteBGPriority[sprite] = oamRAM[Int(sprite + OAM_ATTRIBUTES)] & OAMAttributes.backgroundWindowOverObject > 0
            spriteColumnRange[sprite] = startX..<endX
        }
        
        // OK, now we can look at each column and find our final pixel
        
        for x in 0..<160 {
            // First, find every sprite with a bounding box covering this pixel
            
            let spritesInColumn = spritesOnLine.filter({spriteColumnRange[$0.0]!.contains(Int16(x))})
            
            // Go through each one in turn (they're in priority order) looking for a non-nil pixel
            
            for (sprite, _) in spritesInColumn {    // If no sprites are in this column, nothing happens. That's fine.
                let itsRange = spriteColumnRange[sprite]!
                let itsColors = spriteData[sprite]!
                
                if let color = itsColors[x - Int(itsRange.lowerBound)] {
                    // We found a pixel! We're done. Record what we need then break the loop.
                    
                    finalColors[x] = color
                    backgroundPriority[x] = spriteBGPriority[sprite]!
                    
                    break
                }
            }
        }
        
        return (finalColors, backgroundPriority)
    }
    
    private func getIndividualSpriteLine(line: LineNumber, sprite: OAMOffset) -> [FinalColor?] {
        // Find the flags, the tile, and the base data address for the tile data
        
        let oamFlags = oamRAM[Int(sprite + OAM_ATTRIBUTES)]
        let spriteTile = oamRAM[Int(sprite + OAM_TILE_INDEX)]
        
        let dataAddress = getSpriteAddress(spriteTile)
        
        // We need to figure out the real line, which can be different on vertical flip
        
        let height: UInt8 = lcdControl & LCDControl.objectSize > 0 ? 16 : 8
        let vFlip = oamFlags & OAMAttributes.yFlip > 0
        let hFlip = oamFlags & OAMAttributes.xFlip > 0
        
        let realLine = vFlip ? height - line : line
        
        // From there we can get the color indexes
        
        var colorIndexes = findColorData(line: realLine, baseAddress: dataAddress)
        
        if hFlip {
            // If we need to do a horizontal flip, just reverse the pixels on the line
            colorIndexes.reverse()
        }
        
        // Now we can figure out the palette and apply it
        
        let palette = oamFlags & OAMAttributes.paletteNumber > 0 ? spritePaletteOne : spritePaletteZero
        let colors = applyPalette(palette, colorIndexes, transparency: true)
        
        // Do we need to flip horizontally?
        
        return oamFlags & OAMAttributes.xFlip > 0 ? colors.reversed() : colors
    }
    
    private func findColorData(line: LineNumber, baseAddress: Address) -> [ColorIndex] {
        // The Game Boy stores sprites/tile pictures in two sequential bitplanes in memory. First the low bits, then the high bits
        
        let adjustedBase = Int(baseAddress - MemoryLocations.videoRAMRange.lowerBound + 2 * UInt16(line))
        
        let highBits = videoRAM[adjustedBase + 1]
        let lowBits = videoRAM[adjustedBase]
        
        // Now we can walk through the bits, high to low, to go left to right to get the color indexes by combining bits
        
        var result: [ColorIndex] = []
        
        for i in stride(from: 7, through: 0, by: -1) {
            let lowBit = lowBits >> i & 0x01
            let highBit = (highBits >> i & 0x01) * 2
            
            result.append(highBit + lowBit)
        }
                
        return result
    }
    
    // MARK: - Private methods to find data we need
    
    private func findSpritesForLine() -> [(OAMOffset, LineNumber)] {
        // Find the first 10 sprites on the current line, returning (OAM offset, sprite line) so we can draw them
        
        guard lcdControl & LCDControl.objectEnable > 0 else {
            // If sprites are turned off, why are we doing anythikng?
            
            return []
        }
        
        // Search through the OAM entries
        
        var sprites: [(OAMOffset, LineNumber)] = []
        
        for offset in stride(from: 0, to: OAM_ENTRIES, by: BYTES_PER_OAM)  {
            let spriteY = findSpriteYCoordinate(offset, lcdY: lcdYCoordinate)
            
            if let spriteY {
                // This line of the sprite needs displaying (unless it's off screen left or right, but that's not our problem)
                sprites.append((offset, spriteY))
            }
            
            if sprites.count == 10 {
                // If we've found 10, we have what we need
                
                break;
            }
        }
        
        // When we process things we'll want them in sorted order by X coordinate, so do that now
        
        sprites.sort(by: self.spriteOrderSorter)
        
        return sprites
    }
    
    private func findBackgroundYCoordinate() -> LineNumber? {
        guard lcdControl & LCDControl.bgWindowEnable > 0 else {
            // If the background is off, we don't need to do anything
            return nil
        }
    
        // The viewport registers tell us the BG coordinates of the upper left corner.
        // So given the line we're currently on, figure out the line into the background.
        // Note that the background repeats so we have to wrap around on 256 (32 tiles * 8 pixels high)
        
        return lcdYCoordinate &+ viewportY    // Wrap around on 256
    }
    
    private func findWindowYCoordinate() -> LineNumber? {
        guard lcdControl & LCDControl.bgWindowEnable > 0 && lcdControl & LCDControl.windowEnable > 0 else {
            // If the window is off, we don't need to do anything
            return nil
        }
        
        guard windowY >= lcdYCoordinate else {
            // We haven't gotten low enough for the window to show yet
            return nil
        }
        
        // The window is fixed to the top-left of it's tile map, the thing you change is where the window appears on screen.

        return lcdYCoordinate - windowY
    }
    
    private func findSpriteYCoordinate(_ sprite: OAMOffset, lcdY: LineNumber) -> LineNumber? {
        let spriteHeight: Int16 = ((lcdControl & LCDControl.objectSize) > 0) ? 8 : 16
        let spriteYStart = Int16(oamRAM[Int(sprite + OAM_Y_POSITION)]) - 16
        
        if lcdY < spriteYStart {
            // Haven't gotten to a line in the sprite, so nil
            
            return nil
        } else if lcdY >= spriteYStart &+ spriteHeight {
            // We're past the bottom of the sprite, so nil
            
            return nil
        } else {
            // We can calculate the line in the sprite. It's just LCD line - sprite Y coordinate
            
            return UInt8(Int16(lcdY) - spriteYStart)
        }
    }
    
    private func findSpriteX(_ sprite: OAMOffset) -> PixelCoordinate {
        return Int16(oamRAM[Int(sprite + OAM_X_POSITION)]) - 8
    }
    
    private func spriteOrderSorter(_ tupleA: (OAMOffset, LineNumber), _ tupleB: (OAMOffset, LineNumber)) -> Bool {
        // Sort by the sprite X coordinates. If they're equal, the lower index goes first
        
        let (aOffset, _) = tupleA
        let (bOffset, _) = tupleB
        
        let aX = findSpriteX(aOffset)
        let bX = findSpriteX(bOffset)
        
        return aX < bX || (aX == bX && aOffset < bOffset)
    }
    
    // MARK: - Private methods to help us find stuff in memory
    
    private func getSpriteAddress(_ index: UInt8) -> Address {
        return MemoryLocations.videoRAMRange.lowerBound + UInt16(index) * 8
    }
    
    private func getBackgroundWindowAddress(_ index: UInt8) -> Address {
        let spriteStyleAddressing = lcdControl & LCDControl.bgWindowTileDataArea > 0
        let base = Int(spriteStyleAddressing ? MemoryLocations.videoRAMRange.lowerBound : MemoryLocations.videoRAMHighBlock)
        let offset = spriteStyleAddressing ? Int(index) : Int(Int8(bitPattern: index))
        
        return UInt16(base + offset * 16)   // 8 lines * 2 bitplanes
    }
    
    // MARK: - Other private drawing helper methods
    
    private func applyPalette(_ palette: Register, _ indexes: [ColorIndex], transparency: Bool) -> [FinalColor?] {
        // Make a conversion table from the palette register so our life is easy
        
        let paletteTable = [palette & 0x03, palette >> 2 & 0x03, palette >> 4 & 0x03, palette >> 6 & 0x03]
        
        // Map through that to fix all the colors, replacing 0 with nil if transparency is on
        
        return indexes.map({colorIndex in transparency && colorIndex == 0 ? nil : paletteTable[Int(colorIndex)]})
    }
    
    private func flipHorizontal(_ colors: [FinalColor?]) -> [FinalColor?] {
        return colors.reversed()
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        switch address {
        case MemoryLocations.objectAttributeMemoryRange where LCDMode.oamBlockedStatus.contains(ppuMode):
            // During these times any reads return 0xFF becuase the memory is blocked
            // It would also trigger OAM corruption, which we'll ignore
            return 0xFF
        case MemoryLocations.objectAttributeMemoryRange:
            // The rest of the time it just returns 0x00 no matter what's in the memory
            return 0x00
        case MemoryLocations.videoRAMRange where ppuMode == LCDMode.drawingToLCD:
            // During this time you can't access the video RAM, so we'll return 0xFF
            return 0xFF
        case MemoryLocations.videoRAMRange:
            // You're allowed to access video RAM during this time, so have at it
            return videoRAM[Int(address - MemoryLocations.videoRAMRange.lowerBound)]
        case LCD_CONTROL:
            return lcdControl
        case LCD_STATUS:
            return lcdStatus
        case VIEWPORT_Y:
            return viewportY
        case VIEWPORT_X:
            return viewportX
        case LCD_Y_COORDINATE where GAMEBOY_DOCTOR:
            // For the Gameboy Doctor to help us test things, the LCD's LY register needs to always read 0x90
            return 0x90
        case LCD_Y_COORDINATE:
            return lcdYCoordinate
        case LCD_Y_COMPARE:
            return lcdYCompare
        case DMA_REGISTER:
            return dmaController.readRegister(address)
        case BACKGROUND_PALETTE:
            return backgroundPalette
        case WINDOW_Y:
            return windowY
        case WINDOW_X:
            return windowX
        default:
            return 0xFF     // This location doesn't exist. Nice try.
        }
    }
    
    func writeRegister(_ address: Address, _ value: UInt8) {
        switch address {
        case MemoryLocations.objectAttributeMemoryRange where LCDMode.oamBlockedStatus.contains(ppuMode):
            // During these times the memory is blocked and you can't write
            return
        case MemoryLocations.objectAttributeMemoryRange:
            // The rest of the time writing is OK
            oamRAM[Int(address - MemoryLocations.objectAttributeMemoryRange.lowerBound)] = value
        case MemoryLocations.videoRAMRange where ppuMode == LCDMode.drawingToLCD:
            // During this time you can't access the video RAM, so you can't write
            return
        case MemoryLocations.videoRAMRange:
            // You're allowed to access video RAM during this time, so have at it
            videoRAM[Int(address - MemoryLocations.videoRAMRange.lowerBound)] = value
        case LCD_CONTROL:
            // When the LCD is disabled we'll set our internal state so it's sane on restart
            
            if value & LCDControl.lcdEnable == 0 && lcdControl & LCDControl.lcdEnable > 0 {
                lcdYCoordinate = 144                    // The first line of the vertical blank period
                ticksIntoLine = 0                       // We'll restart at the start of the line
                ppuMode = LCDMode.verticalBlank     // We'll be in the vertical blank
            }
            
            return lcdControl = value
        case LCD_STATUS:
            lcdStatus = value
        case VIEWPORT_Y:
            viewportY = value
        case VIEWPORT_X:
            viewportX = value
        case LCD_Y_COORDINATE:
            // Read-only, sorry
            return
        case LCD_Y_COMPARE:
            lcdYCompare = value
        case DMA_REGISTER:
            return dmaController.writeRegister(address, value)
        case BACKGROUND_PALETTE:
            backgroundPalette = value
        case WINDOW_Y:
            windowY = value
        case WINDOW_X:
            windowX = value
        default:
            return      // This location doesn't exist. Nice try.
        }
    }
}
