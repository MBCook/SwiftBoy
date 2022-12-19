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

private typealias OAMOffset = UInt8
private typealias PixelCoordinate = Int16       // We have to deal with negative numbers and numbers over 127, so UInt8 and Int8 won't work

class PPU: MemoryMappedDevice {
    
    // MARK: - Our private data
    
    private var videoRAM: Data                  // Built in RAM to hold sprites and tiles
    private var oamRAM: Data                    // RAM that controls sprite/timemap display
    
    private var ppuMode: Register               // Current PPU mode
    private var ticksIntoLine: UInt16
    
    private var dmaController: DMAController    // The DMA controller only exists to help the PPU by moving data fast
    
    // MARK: - Our registers
    
    private var lcdControl: Register
    private var _lcdStatus: Register            // The REAL LCD status register
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
    private var viewportY: Register
    private var viewportX: Register
    private var lcdYCoordinate: Register
    private var lcdYCompare: Register
    private var backgroundPalette: Register
    private var windowY: Register
    private var windowX: Register
    
    // MARK: - Public interface
    
    init(dmaController: DMAController) {
        // Setup the bits of RAM we control
        
        videoRAM = Data(count: Int(EIGHT_KB))
        oamRAM = Data(count: 160)
        
        // Save references to the other objects
        
        self.dmaController = dmaController
        
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
                
                drawLine()
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
    
    // MARK: - Private methods
    
    private func drawLine() {
        // TODO: This
    }
    
    private func findSpritesForLine() -> [(OAMOffset, PixelCoordinate)] {
        // Find the first 10 sprites on the current line, returning (OAM offset, sprite line) so we can draw them
        
        guard lcdControl & LCDControl.objectEnable > 0 else {
            // If sprites are turned off, why are we doing anythikng?
            
            return []
        }
        
        // Search through the OAM entries
        
        var sprites: [(OAMOffset, PixelCoordinate)] = []
        
        for offset in stride(from: 0, to: OAM_ENTRIES, by: BYTES_PER_OAM)  {
            let spriteY = findSpriteYCoordinate(offset, lcdY: Int16(lcdYCoordinate))
            
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
    
    private func findBackgroundCoordinates() -> (PixelCoordinate, PixelCoordinate)? {
        if lcdControl & LCDControl.bgWindowEnable > 0 {
            // The background is turned on, figure out the Y coordinate into the full background
            // Add the current Y position to the viewport offset then wrap to 256 becasue the background repeats
            
            var result = lcdYCoordinate + viewportY
            
            result &+= viewportY    // Wrap around on 256
            
            return (Int16(viewportX), Int16(result))
        } else {
            // If the background is turned off we don't have a coordinate
            
            return nil
        }
    }
    
    private func findWindowCoordinates() -> (PixelCoordinate, PixelCoordinate)? {
        if lcdControl & LCDControl.windowEnable > 0 && lcdControl & LCDControl.bgWindowEnable > 0 {
            // The window is turned on, things always start at 0,0 so all that matters is what line we're on
            
            return (Int16(windowX) - 7, Int16(lcdYCoordinate) - Int16(windowY))
        } else {
            // If the window is turned off we don't have a coordinate
            
            return nil
        }
    }
    
    private func findSpriteYCoordinate(_ sprite: OAMOffset, lcdY: PixelCoordinate) -> PixelCoordinate? {
        let spriteHeight: Int16 = ((lcdControl & LCDControl.objectSize) > 0) ? 8 : 16
        let spriteYStart = Int16(oamRAM[Int(sprite + OAM_Y_POSITION)]) - 16
        
        if lcdY < spriteYStart {
            // Haven't gotten to a line in the sprite, so nil
            
            return nil
        } else if lcdY >= spriteYStart + spriteHeight {
            // We're past the bottom of the sprite, so nil
            
            return nil
        } else {
            // We can calculate the line
            
            return Int16(lcdY) - spriteYStart
        }
    }
    
    private func findSpriteXCoordinate(_ sprite: OAMOffset, lcdX: PixelCoordinate) -> PixelCoordinate? {
        let spriteXStart = getSpriteX(sprite)
        
        if lcdX < spriteXStart {
            // Haven't gotten to it yet, so nil
            
            return nil
        } else if lcdX >= spriteXStart + 8 {
            // We're past the right of the sprite (always 8 pixels wide), so nil
            
            return nil
        } else {
            // We can calculate the X cooridinate in the sprite
            
            return lcdX - spriteXStart
        }
    }
    
    private func getSpriteX(_ sprite: OAMOffset) -> PixelCoordinate {
        return Int16(oamRAM[Int(sprite + OAM_X_POSITION)]) - 8
    }
    
    private func spriteOrderSorter(_ tupleA: (OAMOffset, PixelCoordinate), _ tupleB: (OAMOffset, PixelCoordinate)) -> Bool {
        // Sort by the sprite X coordinates. If they're equal, the lower index goes first
        
        let (aOffset, _) = tupleA
        let (bOffset, _) = tupleB
        
        let aX = getSpriteX(aOffset)
        let bX = getSpriteX(bOffset)
        
        return aX < bX || (aX == bX && aOffset < bOffset)
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
