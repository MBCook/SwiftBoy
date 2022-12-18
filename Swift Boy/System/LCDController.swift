//
//  LCDController.swift
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
    
    static let oamBlockedStatus: ClosedRange = LCDMode.searchingOAM...LCDMode.drawingToLCD
}

private enum LCDColors {
    static let white: UInt8 = 0x00
    static let lightGray: UInt8 = 0x01
    static let darkGray: UInt8 = 0x02
    static let black: UInt8 = 0x03
}

class LCDController: MemoryMappedDevice {
    
    // MARK: - Our private data
    
    private var videoRAM: Data                  // Built in RAM to hold sprites and tiles
    private var oamRAM: Data                    // RAM that controls sprite/timemap display
    
    private var currentMode: UInt8              // Current LCD mode
    private var ticksIntoLine: UInt16
    
    private var dmaController: DMAController    // We'll need a reference to this for DMA work
    
    // MARK: - Our registers
    
    private var lcdControl: UInt8
    private var _lcdStatus: UInt8       // The REAL LCD status register
    private var lcdStatus: UInt8 {
        get {
            // We don't really store the current mode in the register, so add it in on read
            return _lcdStatus | currentMode
        }
        set (value) {
            // You may not write to bits 3-6, so we'll mask off everything else
            // That also means we're only keeping bits 0-2 of the current status register (bit 7 isn't used)
            _lcdStatus = value & 0x78
        }
    }
    private var viewportY: UInt8
    private var viewportX: UInt8
    private var lcdYCoordinate: UInt8
    private var lcdYCompare: UInt8
    private var backgroundPalette: UInt8
    private var windowY: UInt8
    private var windowX: UInt8
    
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
        currentMode = LCDMode.verticalBlank
        
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
                currentMode = LCDMode.searchingOAM
                
                needsInterrupt = (lcdStatus & LCDStatus.oamInterruptSource) > 0    // Flag interrupt if needed
            } else if lcdYCoordinate >= 144 && currentMode != LCDMode.verticalBlank {
                // We're doing the vertical blank now, set it up
                currentMode = LCDMode.verticalBlank
                
                needsInterrupt = (lcdStatus & LCDStatus.vBankInterruptSource) > 0  // Flag interrupt if needed
            } else if currentMode != LCDMode.verticalBlank {
                // Just a normal new line when not in the vertical blank
                
                currentMode = LCDMode.searchingOAM
                
                needsInterrupt = (lcdStatus & LCDStatus.oamInterruptSource) > 0    // Flag interrupt if needed
            }
        } else if currentMode != LCDMode.verticalBlank {
            // In vertical blank there is nothing to do during a line, so only act if that's not what's going on
            
            if ticksIntoLine > 80 && ticksIntoLine <= 252 && currentMode != LCDMode.drawingToLCD {
                // Transition to drawing mode. We'll pretend it ALWAYS takes 172 ticks instead of variable like a real GameBoy
                // As soon as this mode starts we'll draw the line for output by calling drawLine()
                
                currentMode = LCDMode.drawingToLCD
                
                drawLine()
            } else if ticksIntoLine > 252 && currentMode != LCDMode.horizontablBlank {
                // Transition to Horizontal Blank
                
                currentMode = LCDMode.horizontablBlank
                
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
    
    func drawLine() {
        // TODO: This
    }
    
    // MARK: - MemoryMappedDevice protocol functions
    
    func readRegister(_ address: Address) -> UInt8 {
        switch address {
        case MemoryLocations.objectAttributeMemoryRange where LCDMode.oamBlockedStatus.contains(currentMode):
            // During these times any reads return 0xFF becuase the memory is blocked
            // It would also trigger OAM corruption, which we'll ignore
            return 0xFF
        case MemoryLocations.objectAttributeMemoryRange:
            // The rest of the time it just returns 0x00 no matter what's in the memory
            return 0x00
        case MemoryLocations.videoRAMRange where currentMode == LCDMode.drawingToLCD:
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
        case MemoryLocations.objectAttributeMemoryRange where LCDMode.oamBlockedStatus.contains(currentMode):
            // During these times the memory is blocked and you can't write
            return
        case MemoryLocations.objectAttributeMemoryRange:
            // The rest of the time writing is OK
            oamRAM[Int(address - MemoryLocations.objectAttributeMemoryRange.lowerBound)] = value
        case MemoryLocations.videoRAMRange where currentMode == LCDMode.drawingToLCD:
            // During this time you can't access the video RAM, so you can't write
            return
        case MemoryLocations.videoRAMRange:
            // You're allowed to access video RAM during this time, so have at it
            videoRAM[Int(address - MemoryLocations.videoRAMRange.lowerBound)] = value
        case LCD_CONTROL:
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
