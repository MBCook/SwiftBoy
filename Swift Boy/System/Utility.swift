//
//  Utility.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/7/22.
//

import Foundation

func toHex(_ value: UInt8) -> String {
    return String(format: "%02X", value)
}

func toHex(_ value: UInt16) -> String {
    return String(format: "%04X", value)
}
