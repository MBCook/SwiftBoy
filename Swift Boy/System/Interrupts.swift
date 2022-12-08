//
//  Interrupts.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/7/22.
//

import Foundation

enum InterruptSource: Bitmask {
case vblank = 0x01
case lcdStat = 0x02
case timer = 0x04
case serial = 0x08
case joypad = 0x10
}
