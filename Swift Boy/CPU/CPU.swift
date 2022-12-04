//
//  CPU.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import Foundation

enum Flags: UInt8 {
    case zero = 0b10000000
    case subtraction = 0b01000000
    case halfCarry = 0b00100000
    case carry = 0b00010000
}

typealias Address = UInt16
typealias Cycles = UInt
typealias Register = UInt8
typealias RegisterPair = UInt16

enum CPUErrors: Error {
    case InvalidInstruction
    case Stopped
}

class CPU {
    // MARK: - First our registers
    
    var a: Register
    var b: Register
    var c: Register
    var d: Register
    var e: Register
    var h: Register
    var l: Register
    var flags: Register
    var sp: Address
    var pc: Address
    
    // MARK: - Combo registers, which require computed properties
    
    var af: RegisterPair {
        get {
            return UInt16(a) << 8 + UInt16(flags)
        }
        set(value) {
            a = UInt8(value >> 8)
            flags = UInt8(value * 0x00F0) // Note the bottom 4 bits are always 0, so don't allow them to be set
        }
    }
    var bc: RegisterPair {
        get {
            return UInt16(b) << 8 + UInt16(c)
        }
        set(value) {
            b = UInt8(value >> 8)
            c = UInt8(value & 0x00FF)
        }
    }
    var de: RegisterPair {
        get {
            return UInt16(d) << 8 + UInt16(e)
        }
        set(value) {
            d = UInt8(value >> 8)
            e = UInt8(value & 0x00FF)
        }
    }
    var hl: RegisterPair {
        get {
            return UInt16(h) << 8 + UInt16(l)
        }
        set(value) {
            h = UInt8(value >> 8)
            l = UInt8(value & 0x00FF)
        }
    }
    
    // MARK: - Other things we need to keep track of
    
    var halted: Bool        // If the CPU is wiaitng for an interrupt
    let memory = Memory()   // Represents all memory, knows the special addressing rules so we don't have to
    
    // MARK: - Public interface
    
    // Init sets everything to the values expected once the startup sequence finishes running
    init() {
        a = 0x01
        b = 0x00
        c = 0x13
        d = 0x13
        e = 0xD8
        h = 0x01
        l = 0x4D
        flags = 0xB0
        sp = 0xFFFE
        pc = 0x0100
        halted = false
    }
    
    // MARK: - Private helper functions
    
    private func getFlag(_ flag: Flags) -> Bool {
        return flags & flag.rawValue > 0
    }
    
    private func setFlag(_ flag: Flags) {
        flags = flags | flag.rawValue
    }
    
    private func setFlag(_ flag: Flags, to: Bool) {
        if getFlag(flag) != to {
            if to {
                setFlag(flag)
            } else {
                clearFlag(flag)
            }
        }
    }
    
    private func setFlags(zero: Bool?, subtraction: Bool?, halfCarry: Bool?, carry: Bool?) {
        if let zero {
            setFlag(.zero, to: zero)
        }
        if let subtraction {
            setFlag(.subtraction, to: subtraction)
        }
        if let halfCarry {
            setFlag(.halfCarry, to: halfCarry)
        }
        if let carry {
            setFlag(.carry, to: carry)
        }
    }
    
    private func clearFlag(_ flag: Flags) {
        flags = flags & (0xFF ^ flag.rawValue)
    }
    
    private func check8BitHalfCarry(_ a: UInt8, _ b: UInt8) -> Bool {
        return (a & 0x0F) + (b & 0x0F) > 0x0F
    }
    
    private func check16BitHalfCarry(_ a: UInt16, _ b: UInt16) -> Bool {
        return (a & 0x0FFF) + (b & 0x0FFF) > 0x0FFF
    }
    
    private func twosCompliment(_ value: UInt8) -> UInt8 {
        return (value ^ 0xFF) &+ 1
    }
    
    private func twosCompliment(_ value: UInt16) -> UInt16 {
        return (value ^ 0xFFFF) &+ 1
    }
    
    private func readWord(_ address: Address) -> UInt16 {
        let low = UInt16(memory[address])
        let high = UInt16(memory[address + 1])
        
        return high << 8 + low
    }
    
    private func writeWord(address: Address, value: UInt16) {
        let low = UInt8(value & 0x00FF)
        let high = UInt8((value & 0xFF00) >> 8)
        
        memory[address] = low
        memory[address + 1] = high
    }
    
    // MARK: - Helper functions that let us generally op-codes and pass in the registers
    
    private func loadWordIntoRegisterPair(_ register: inout RegisterPair, address: Address) {
        register = readWord(address)
    }
    
    private func incrementRegister(_ register: inout Register) {
        let old = register
        
        register = register &+ 1
        
        setFlags(zero: register == 0, subtraction: false, halfCarry: check8BitHalfCarry(old, 1), carry: nil)
    }
    
    private func decrementRegister(_ register: inout Register) {
        let old = register
        
        register = register &- 1
        
        setFlags(zero: register == 0, subtraction: true, halfCarry: check8BitHalfCarry(old, 1), carry: nil)
                    
    }
    
    private func addToRegisterPair(_ register: inout RegisterPair, _ amount: UInt16) {
        let carry = check16BitHalfCarry(register, amount)
        
        register = register &+ amount
        
        setFlags(zero: nil, subtraction: false, halfCarry: carry, carry: carry)
        
    }
    
    // MARK: - Opcode dispatch
    
    // Runs the opcode at PC, returns the new value for PC and how many cycles were used (divided by four)
    // NOTE: We use the no-overflow operators (&+, &-) because that's how a GB would work
    private func executeOpcode() throws -> (Address, Cycles) {
        switch (memory[pc]) {
        case 0x00:
            // NOP, does nothing
            
            return (pc + 1, 1)
        case 0x01:
            // LD BC, d16
            
            loadWordIntoRegisterPair(&bc, address: pc + 1)
            
            return (pc + 3, 3)
        case 0x02:
            // LD (BC), A
            
            memory[bc] = a
            
            return (pc + 1, 2)
        case 0x03:
            // INC BC
            
            bc = bc &+ 1
            
            return (pc + 1, 2)
        case 0x04:
            // INC B
            
            incrementRegister(&b)
            
            return (pc + 1, 1)
        case 0x05:
            // DEC B
            
            decrementRegister(&b)
            
            return (pc + 1, 1)
        case 0x06:
            // LD B, d8
            
            b = memory[pc + 1]
            
            return (pc + 2, 2)
        case 0x07:
            // RLCA
            
            let rotated = a << 1
            let carry = a & 0b10000000 > 0  // The high bit will become the low bit AND the carry flag
            
            a = rotated & (carry ? 1 : 0)
            
            setFlags(zero: false, subtraction: false, halfCarry: false, carry: carry)
            
            return (pc + 1, 1)
        case 0x08:
            // LD (a16), SP
            
            let address = readWord(pc + 1)
            
            writeWord(address: address, value: sp)
            
            return (pc + 3, 5)
        case 0x09:
            // ADD HL, BC
            
            addToRegisterPair(&hl, bc)
            
            return (pc + 1, 2)
        case 0x0A:
            // LD A, (BC)
            
            a = memory[bc]
            
            return (pc + 1, 2)
        case 0x0B:
            // DEC BC
            
            bc = bc &- 1
            
            return (pc + 1, 2)
        case 0x0C:
            // INC C
            
            incrementRegister(&c)
            
            return (pc + 1, 1)
        case 0x0D:
            // DEC C
            
            decrementRegister(&c)
            
            return (pc + 1, 1)
        case 0x0E:
            // LD C, d8
            
            c = memory[pc + 1]
            
            return (pc + 2, 2)
        case 0x0F:
            // RRCA
            
            let rotated = a >> 1
            let carry = a & 0b00000001 > 0  // The low bit will become the high bit AND the carry flag
            
            a = rotated & (carry ? 1 : 0)
            
            setFlags(zero: false, subtraction: false, halfCarry: false, carry: carry)
            
            return (pc + 1, 1)
        case 0x10:
            throw CPUErrors.Stopped
        case 0x11:
            // LD DE, d16
            
            de = readWord(pc + 1)
            
            return (pc + 3, 3)
        case 0x12:
            // LD (DE), A
            
            memory[de] = a
            
            return (pc + 1, 2)
        case 0x13:
            // INC DE
            
            de = de &+ 1
            
            return (pc + 1, 2)
        case 0x14:
            // INC D
            
            incrementRegister(&d)
            
            return (pc + 1, 1)
        case 0x15:
            // DEC D
            
            decrementRegister(&d)
            
            return (pc + 1, 1)
        case 0x16:
            // LD D, d8
            
            d = memory[pc + 1]
            
            return (pc + 2, 2)
        case 0x17:
            // RLA
            
            let rotated = a << 1
            let carry = a & 0b10000000 > 0  // The high bit will become the the carry flag
            
            a = rotated & (getFlag(.carry) ? 1 : 0) // The old cary flag becomes bit 0
            
            setFlags(zero: false, subtraction: false, halfCarry: false, carry: carry)
            
            return (pc + 1, 1)
        case 0x18:
            // JR s8
            
            return (pc + UInt16(memory[pc + 1]), 3)
        case 0x19:
            // ADD HL, DE
            
            addToRegisterPair(&hl, de)
            
            return (pc + 1, 2)
        case 0x1A:
            // LD A, (DE)
            
            a = memory[de]
            
            return (pc + 1, 2)
        case 0x1B:
            // DEC DE
            
            de = de &- 1
            
            return (pc + 1, 2)
        case 0x1C:
            // INC E
            
            incrementRegister(&e)
            
            return (pc + 1, 1)
        case 0x1D:
            // DEC E
            
            decrementRegister(&d)
            
            return (pc + 1, 1)
        case 0x1E:
            // LD E, d8
            
            e = memory[pc + 1]
            
            return (pc + 2, 2)
        case 0x1F:
            // RRaA
            
            let rotated = a >> 1
            let carry = a & 0b00000001 > 0  // The low bit will become the carry flag
            
            a = rotated & (getFlag(.carry) ? 0b10000000 : 0) // The high bit becomes the carry flag
            
            setFlags(zero: false, subtraction: false, halfCarry: false, carry: carry)
            
            return (pc + 1, 1)
        case 0x20:
            return (pc + 1, 1)
        case 0x21:
            return (pc + 1, 1)
        case 0x22:
            return (pc + 1, 1)
        case 0x23:
            return (pc + 1, 1)
        case 0x24:
            return (pc + 1, 1)
        case 0x25:
            return (pc + 1, 1)
        case 0x26:
            return (pc + 1, 1)
        case 0x27:
            return (pc + 1, 1)
        case 0x28:
            return (pc + 1, 1)
        case 0x29:
            return (pc + 1, 1)
        case 0x2A:
            return (pc + 1, 1)
        case 0x2B:
            return (pc + 1, 1)
        case 0x2C:
            return (pc + 1, 1)
        case 0x2D:
            return (pc + 1, 1)
        case 0x2E:
            return (pc + 1, 1)
        case 0x2F:
            return (pc + 1, 1)
        case 0x30:
            return (pc + 1, 1)
        case 0x31:
            return (pc + 1, 1)
        case 0x32:
            return (pc + 1, 1)
        case 0x33:
            return (pc + 1, 1)
        case 0x34:
            return (pc + 1, 1)
        case 0x35:
            return (pc + 1, 1)
        case 0x36:
            return (pc + 1, 1)
        case 0x37:
            return (pc + 1, 1)
        case 0x38:
            return (pc + 1, 1)
        case 0x39:
            return (pc + 1, 1)
        case 0x3A:
            return (pc + 1, 1)
        case 0x3B:
            return (pc + 1, 1)
        case 0x3C:
            return (pc + 1, 1)
        case 0x3D:
            return (pc + 1, 1)
        case 0x3E:
            return (pc + 1, 1)
        case 0x3F:
            return (pc + 1, 1)
        case 0x40:
            return (pc + 1, 1)
        case 0x41:
            return (pc + 1, 1)
        case 0x42:
            return (pc + 1, 1)
        case 0x43:
            return (pc + 1, 1)
        case 0x44:
            return (pc + 1, 1)
        case 0x45:
            return (pc + 1, 1)
        case 0x46:
            return (pc + 1, 1)
        case 0x47:
            return (pc + 1, 1)
        case 0x48:
            return (pc + 1, 1)
        case 0x49:
            return (pc + 1, 1)
        case 0x4A:
            return (pc + 1, 1)
        case 0x4B:
            return (pc + 1, 1)
        case 0x4C:
            return (pc + 1, 1)
        case 0x4D:
            return (pc + 1, 1)
        case 0x4E:
            return (pc + 1, 1)
        case 0x4F:
            return (pc + 1, 1)
        case 0x50:
            return (pc + 1, 1)
        case 0x51:
            return (pc + 1, 1)
        case 0x52:
            return (pc + 1, 1)
        case 0x53:
            return (pc + 1, 1)
        case 0x54:
            return (pc + 1, 1)
        case 0x55:
            return (pc + 1, 1)
        case 0x56:
            return (pc + 1, 1)
        case 0x57:
            return (pc + 1, 1)
        case 0x58:
            return (pc + 1, 1)
        case 0x59:
            return (pc + 1, 1)
        case 0x5A:
            return (pc + 1, 1)
        case 0x5B:
            return (pc + 1, 1)
        case 0x5C:
            return (pc + 1, 1)
        case 0x5D:
            return (pc + 1, 1)
        case 0x5E:
            return (pc + 1, 1)
        case 0x5F:
            return (pc + 1, 1)
        case 0x60:
            return (pc + 1, 1)
        case 0x61:
            return (pc + 1, 1)
        case 0x62:
            return (pc + 1, 1)
        case 0x63:
            return (pc + 1, 1)
        case 0x64:
            return (pc + 1, 1)
        case 0x65:
            return (pc + 1, 1)
        case 0x66:
            return (pc + 1, 1)
        case 0x67:
            return (pc + 1, 1)
        case 0x68:
            return (pc + 1, 1)
        case 0x69:
            return (pc + 1, 1)
        case 0x6A:
            return (pc + 1, 1)
        case 0x6B:
            return (pc + 1, 1)
        case 0x6C:
            return (pc + 1, 1)
        case 0x6D:
            return (pc + 1, 1)
        case 0x6E:
            return (pc + 1, 1)
        case 0x6F:
            return (pc + 1, 1)
        case 0x70:
            return (pc + 1, 1)
        case 0x71:
            return (pc + 1, 1)
        case 0x72:
            return (pc + 1, 1)
        case 0x73:
            return (pc + 1, 1)
        case 0x74:
            return (pc + 1, 1)
        case 0x75:
            return (pc + 1, 1)
        case 0x76:
            halted = true
            return (pc + 1, 1)
        case 0x77:
            return (pc + 1, 1)
        case 0x78:
            return (pc + 1, 1)
        case 0x79:
            return (pc + 1, 1)
        case 0x7A:
            return (pc + 1, 1)
        case 0x7B:
            return (pc + 1, 1)
        case 0x7C:
            return (pc + 1, 1)
        case 0x7D:
            return (pc + 1, 1)
        case 0x7E:
            return (pc + 1, 1)
        case 0x7F:
            return (pc + 1, 1)
        case 0x80:
            return (pc + 1, 1)
        case 0x81:
            return (pc + 1, 1)
        case 0x82:
            return (pc + 1, 1)
        case 0x83:
            return (pc + 1, 1)
        case 0x84:
            return (pc + 1, 1)
        case 0x85:
            return (pc + 1, 1)
        case 0x86:
            return (pc + 1, 1)
        case 0x87:
            return (pc + 1, 1)
        case 0x88:
            return (pc + 1, 1)
        case 0x89:
            return (pc + 1, 1)
        case 0x8A:
            return (pc + 1, 1)
        case 0x8B:
            return (pc + 1, 1)
        case 0x8C:
            return (pc + 1, 1)
        case 0x8D:
            return (pc + 1, 1)
        case 0x8E:
            return (pc + 1, 1)
        case 0x8F:
            return (pc + 1, 1)
        case 0x90:
            return (pc + 1, 1)
        case 0x91:
            return (pc + 1, 1)
        case 0x92:
            return (pc + 1, 1)
        case 0x93:
            return (pc + 1, 1)
        case 0x94:
            return (pc + 1, 1)
        case 0x95:
            return (pc + 1, 1)
        case 0x96:
            return (pc + 1, 1)
        case 0x97:
            return (pc + 1, 1)
        case 0x98:
            return (pc + 1, 1)
        case 0x99:
            return (pc + 1, 1)
        case 0x9A:
            return (pc + 1, 1)
        case 0x9B:
            return (pc + 1, 1)
        case 0x9C:
            return (pc + 1, 1)
        case 0x9D:
            return (pc + 1, 1)
        case 0x9E:
            return (pc + 1, 1)
        case 0x9F:
            return (pc + 1, 1)
        case 0xA0:
            return (pc + 1, 1)
        case 0xA1:
            return (pc + 1, 1)
        case 0xA2:
            return (pc + 1, 1)
        case 0xA3:
            return (pc + 1, 1)
        case 0xA4:
            return (pc + 1, 1)
        case 0xA5:
            return (pc + 1, 1)
        case 0xA6:
            return (pc + 1, 1)
        case 0xA7:
            return (pc + 1, 1)
        case 0xA8:
            return (pc + 1, 1)
        case 0xA9:
            return (pc + 1, 1)
        case 0xAA:
            return (pc + 1, 1)
        case 0xAB:
            return (pc + 1, 1)
        case 0xAC:
            return (pc + 1, 1)
        case 0xAD:
            return (pc + 1, 1)
        case 0xAE:
            return (pc + 1, 1)
        case 0xAF:
            return (pc + 1, 1)
        case 0xB0:
            return (pc + 1, 1)
        case 0xB1:
            return (pc + 1, 1)
        case 0xB2:
            return (pc + 1, 1)
        case 0xB3:
            return (pc + 1, 1)
        case 0xB4:
            return (pc + 1, 1)
        case 0xB5:
            return (pc + 1, 1)
        case 0xB6:
            return (pc + 1, 1)
        case 0xB7:
            return (pc + 1, 1)
        case 0xB8:
            return (pc + 1, 1)
        case 0xB9:
            return (pc + 1, 1)
        case 0xBA:
            return (pc + 1, 1)
        case 0xBB:
            return (pc + 1, 1)
        case 0xBC:
            return (pc + 1, 1)
        case 0xBD:
            return (pc + 1, 1)
        case 0xBE:
            return (pc + 1, 1)
        case 0xBF:
            return (pc + 1, 1)
        case 0xC0:
            return (pc + 1, 1)
        case 0xC1:
            return (pc + 1, 1)
        case 0xC2:
            return (pc + 1, 1)
        case 0xC3:
            return (pc + 1, 1)
        case 0xC4:
            return (pc + 1, 1)
        case 0xC5:
            return (pc + 1, 1)
        case 0xC6:
            return (pc + 1, 1)
        case 0xC7:
            return (pc + 1, 1)
        case 0xC8:
            return (pc + 1, 1)
        case 0xC9:
            return (pc + 1, 1)
        case 0xCA:
            return (pc + 1, 1)
        case 0xCB:
            // This is a prefix for a second set of 256 instructions. We have a different function to handle those
            return executeCBOpcode()
        case 0xCC:
            return (pc + 1, 1)
        case 0xCD:
            return (pc + 1, 1)
        case 0xCE:
            return (pc + 1, 1)
        case 0xCF:
            return (pc + 1, 1)
        case 0xD0:
            return (pc + 1, 1)
        case 0xD1:
            return (pc + 1, 1)
        case 0xD2:
            return (pc + 1, 1)
        case 0xD3:
            return (pc + 1, 1)
        case 0xD4:
            throw CPUErrors.InvalidInstruction
        case 0xD5:
            return (pc + 1, 1)
        case 0xD6:
            return (pc + 1, 1)
        case 0xD7:
            return (pc + 1, 1)
        case 0xD8:
            throw CPUErrors.InvalidInstruction
        case 0xD9:
            return (pc + 1, 1)
        case 0xDA:
            return (pc + 1, 1)
        case 0xDB:
            return (pc + 1, 1)
        case 0xDC:
            return (pc + 1, 1)
        case 0xDD:
            throw CPUErrors.InvalidInstruction
        case 0xDE:
            return (pc + 1, 1)
        case 0xDF:
            return (pc + 1, 1)
        case 0xE0:
            return (pc + 1, 1)
        case 0xE1:
            return (pc + 1, 1)
        case 0xE2:
            return (pc + 1, 1)
        case 0xE3:
            throw CPUErrors.InvalidInstruction
        case 0xE4:
            throw CPUErrors.InvalidInstruction
        case 0xE5:
            return (pc + 1, 1)
        case 0xE6:
            return (pc + 1, 1)
        case 0xE7:
            return (pc + 1, 1)
        case 0xE8:
            return (pc + 1, 1)
        case 0xE9:
            return (pc + 1, 1)
        case 0xEA:
            return (pc + 1, 1)
        case 0xEB:
            throw CPUErrors.InvalidInstruction
        case 0xEC:
            throw CPUErrors.InvalidInstruction
        case 0xED:
            throw CPUErrors.InvalidInstruction
        case 0xEE:
            return (pc + 1, 1)
        case 0xEF:
            return (pc + 1, 1)
        case 0xF0:
            return (pc + 1, 1)
        case 0xF1:
            return (pc + 1, 1)
        case 0xF2:
            return (pc + 1, 1)
        case 0xF3:
            return (pc + 1, 1)
        case 0xF4:
            throw CPUErrors.InvalidInstruction
        case 0xF5:
            return (pc + 1, 1)
        case 0xF6:
            return (pc + 1, 1)
        case 0xF7:
            return (pc + 1, 1)
        case 0xF8:
            return (pc + 1, 1)
        case 0xF9:
            return (pc + 1, 1)
        case 0xFA:
            return (pc + 1, 1)
        case 0xFB:
            return (pc + 1, 1)
        case 0xFC:
            throw CPUErrors.InvalidInstruction
        case 0xFD:
            throw CPUErrors.InvalidInstruction
        case 0xFE:
            return (pc + 1, 1)
        case 0xFF:
            return (pc + 1, 1)
        default:
            // Xcode can't seem to figure out we have all possible cases of a UInt8
            fatalError("Unable to find a case for instruction 0x\(String(format: "%02X", pc + 1))!");
        }
    }
    
    // Same as above, but all opcodes are prefixed with 0xCB so we have to make sure to take that into account
    private func executeCBOpcode() -> (Address, Cycles) {
        switch (memory[pc + 1]) {   // Skip the 0xCB byte, we already know that one
        case 0x00:
            return (pc + 2, 1)
        case 0x01:
            return (pc + 2, 1)
        case 0x02:
            return (pc + 2, 1)
        case 0x03:
            return (pc + 2, 1)
        case 0x04:
            return (pc + 2, 1)
        case 0x05:
            return (pc + 2, 1)
        case 0x06:
            return (pc + 2, 1)
        case 0x07:
            return (pc + 2, 1)
        case 0x08:
            return (pc + 2, 1)
        case 0x09:
            return (pc + 2, 1)
        case 0x0A:
            return (pc + 2, 1)
        case 0x0B:
            return (pc + 2, 1)
        case 0x0C:
            return (pc + 2, 1)
        case 0x0D:
            return (pc + 2, 1)
        case 0x0E:
            return (pc + 2, 1)
        case 0x0F:
            return (pc + 2, 1)
        case 0x10:
            return (pc + 2, 1)
        case 0x11:
            return (pc + 2, 1)
        case 0x12:
            return (pc + 2, 1)
        case 0x13:
            return (pc + 2, 1)
        case 0x14:
            return (pc + 2, 1)
        case 0x15:
            return (pc + 2, 1)
        case 0x16:
            return (pc + 2, 1)
        case 0x17:
            return (pc + 2, 1)
        case 0x18:
            return (pc + 2, 1)
        case 0x19:
            return (pc + 2, 1)
        case 0x1A:
            return (pc + 2, 1)
        case 0x1B:
            return (pc + 2, 1)
        case 0x1C:
            return (pc + 2, 1)
        case 0x1D:
            return (pc + 2, 1)
        case 0x1E:
            return (pc + 2, 1)
        case 0x1F:
            return (pc + 2, 1)
        case 0x20:
            return (pc + 2, 1)
        case 0x21:
            return (pc + 2, 1)
        case 0x22:
            return (pc + 2, 1)
        case 0x23:
            return (pc + 2, 1)
        case 0x24:
            return (pc + 2, 1)
        case 0x25:
            return (pc + 2, 1)
        case 0x26:
            return (pc + 2, 1)
        case 0x27:
            return (pc + 2, 1)
        case 0x28:
            return (pc + 2, 1)
        case 0x29:
            return (pc + 2, 1)
        case 0x2A:
            return (pc + 2, 1)
        case 0x2B:
            return (pc + 2, 1)
        case 0x2C:
            return (pc + 2, 1)
        case 0x2D:
            return (pc + 2, 1)
        case 0x2E:
            return (pc + 2, 1)
        case 0x2F:
            return (pc + 2, 1)
        case 0x30:
            return (pc + 2, 1)
        case 0x31:
            return (pc + 2, 1)
        case 0x32:
            return (pc + 2, 1)
        case 0x33:
            return (pc + 2, 1)
        case 0x34:
            return (pc + 2, 1)
        case 0x35:
            return (pc + 2, 1)
        case 0x36:
            return (pc + 2, 1)
        case 0x37:
            return (pc + 2, 1)
        case 0x38:
            return (pc + 2, 1)
        case 0x39:
            return (pc + 2, 1)
        case 0x3A:
            return (pc + 2, 1)
        case 0x3B:
            return (pc + 2, 1)
        case 0x3C:
            return (pc + 2, 1)
        case 0x3D:
            return (pc + 2, 1)
        case 0x3E:
            return (pc + 2, 1)
        case 0x3F:
            return (pc + 2, 1)
        case 0x40:
            return (pc + 2, 1)
        case 0x41:
            return (pc + 2, 1)
        case 0x42:
            return (pc + 2, 1)
        case 0x43:
            return (pc + 2, 1)
        case 0x44:
            return (pc + 2, 1)
        case 0x45:
            return (pc + 2, 1)
        case 0x46:
            return (pc + 2, 1)
        case 0x47:
            return (pc + 2, 1)
        case 0x48:
            return (pc + 2, 1)
        case 0x49:
            return (pc + 2, 1)
        case 0x4A:
            return (pc + 2, 1)
        case 0x4B:
            return (pc + 2, 1)
        case 0x4C:
            return (pc + 2, 1)
        case 0x4D:
            return (pc + 2, 1)
        case 0x4E:
            return (pc + 2, 1)
        case 0x4F:
            return (pc + 2, 1)
        case 0x50:
            return (pc + 2, 1)
        case 0x51:
            return (pc + 2, 1)
        case 0x52:
            return (pc + 2, 1)
        case 0x53:
            return (pc + 2, 1)
        case 0x54:
            return (pc + 2, 1)
        case 0x55:
            return (pc + 2, 1)
        case 0x56:
            return (pc + 2, 1)
        case 0x57:
            return (pc + 2, 1)
        case 0x58:
            return (pc + 2, 1)
        case 0x59:
            return (pc + 2, 1)
        case 0x5A:
            return (pc + 2, 1)
        case 0x5B:
            return (pc + 2, 1)
        case 0x5C:
            return (pc + 2, 1)
        case 0x5D:
            return (pc + 2, 1)
        case 0x5E:
            return (pc + 2, 1)
        case 0x5F:
            return (pc + 2, 1)
        case 0x60:
            return (pc + 2, 1)
        case 0x61:
            return (pc + 2, 1)
        case 0x62:
            return (pc + 2, 1)
        case 0x63:
            return (pc + 2, 1)
        case 0x64:
            return (pc + 2, 1)
        case 0x65:
            return (pc + 2, 1)
        case 0x66:
            return (pc + 2, 1)
        case 0x67:
            return (pc + 2, 1)
        case 0x68:
            return (pc + 2, 1)
        case 0x69:
            return (pc + 2, 1)
        case 0x6A:
            return (pc + 2, 1)
        case 0x6B:
            return (pc + 2, 1)
        case 0x6C:
            return (pc + 2, 1)
        case 0x6D:
            return (pc + 2, 1)
        case 0x6E:
            return (pc + 2, 1)
        case 0x6F:
            return (pc + 2, 1)
        case 0x70:
            return (pc + 2, 1)
        case 0x71:
            return (pc + 2, 1)
        case 0x72:
            return (pc + 2, 1)
        case 0x73:
            return (pc + 2, 1)
        case 0x74:
            return (pc + 2, 1)
        case 0x75:
            return (pc + 2, 1)
        case 0x76:
            return (pc + 2, 1)
        case 0x77:
            return (pc + 2, 1)
        case 0x78:
            return (pc + 2, 1)
        case 0x79:
            return (pc + 2, 1)
        case 0x7A:
            return (pc + 2, 1)
        case 0x7B:
            return (pc + 2, 1)
        case 0x7C:
            return (pc + 2, 1)
        case 0x7D:
            return (pc + 2, 1)
        case 0x7E:
            return (pc + 2, 1)
        case 0x7F:
            return (pc + 2, 1)
        case 0x80:
            return (pc + 2, 1)
        case 0x81:
            return (pc + 2, 1)
        case 0x82:
            return (pc + 2, 1)
        case 0x83:
            return (pc + 2, 1)
        case 0x84:
            return (pc + 2, 1)
        case 0x85:
            return (pc + 2, 1)
        case 0x86:
            return (pc + 2, 1)
        case 0x87:
            return (pc + 2, 1)
        case 0x88:
            return (pc + 2, 1)
        case 0x89:
            return (pc + 2, 1)
        case 0x8A:
            return (pc + 2, 1)
        case 0x8B:
            return (pc + 2, 1)
        case 0x8C:
            return (pc + 2, 1)
        case 0x8D:
            return (pc + 2, 1)
        case 0x8E:
            return (pc + 2, 1)
        case 0x8F:
            return (pc + 2, 1)
        case 0x90:
            return (pc + 2, 1)
        case 0x91:
            return (pc + 2, 1)
        case 0x92:
            return (pc + 2, 1)
        case 0x93:
            return (pc + 2, 1)
        case 0x94:
            return (pc + 2, 1)
        case 0x95:
            return (pc + 2, 1)
        case 0x96:
            return (pc + 2, 1)
        case 0x97:
            return (pc + 2, 1)
        case 0x98:
            return (pc + 2, 1)
        case 0x99:
            return (pc + 2, 1)
        case 0x9A:
            return (pc + 2, 1)
        case 0x9B:
            return (pc + 2, 1)
        case 0x9C:
            return (pc + 2, 1)
        case 0x9D:
            return (pc + 2, 1)
        case 0x9E:
            return (pc + 2, 1)
        case 0x9F:
            return (pc + 2, 1)
        case 0xA0:
            return (pc + 2, 1)
        case 0xA1:
            return (pc + 2, 1)
        case 0xA2:
            return (pc + 2, 1)
        case 0xA3:
            return (pc + 2, 1)
        case 0xA4:
            return (pc + 2, 1)
        case 0xA5:
            return (pc + 2, 1)
        case 0xA6:
            return (pc + 2, 1)
        case 0xA7:
            return (pc + 2, 1)
        case 0xA8:
            return (pc + 2, 1)
        case 0xA9:
            return (pc + 2, 1)
        case 0xAA:
            return (pc + 2, 1)
        case 0xAB:
            return (pc + 2, 1)
        case 0xAC:
            return (pc + 2, 1)
        case 0xAD:
            return (pc + 2, 1)
        case 0xAE:
            return (pc + 2, 1)
        case 0xAF:
            return (pc + 2, 1)
        case 0xB0:
            return (pc + 2, 1)
        case 0xB1:
            return (pc + 2, 1)
        case 0xB2:
            return (pc + 2, 1)
        case 0xB3:
            return (pc + 2, 1)
        case 0xB4:
            return (pc + 2, 1)
        case 0xB5:
            return (pc + 2, 1)
        case 0xB6:
            return (pc + 2, 1)
        case 0xB7:
            return (pc + 2, 1)
        case 0xB8:
            return (pc + 2, 1)
        case 0xB9:
            return (pc + 2, 1)
        case 0xBA:
            return (pc + 2, 1)
        case 0xBB:
            return (pc + 2, 1)
        case 0xBC:
            return (pc + 2, 1)
        case 0xBD:
            return (pc + 2, 1)
        case 0xBE:
            return (pc + 2, 1)
        case 0xBF:
            return (pc + 2, 1)
        case 0xC0:
            return (pc + 2, 1)
        case 0xC1:
            return (pc + 2, 1)
        case 0xC2:
            return (pc + 2, 1)
        case 0xC3:
            return (pc + 2, 1)
        case 0xC4:
            return (pc + 2, 1)
        case 0xC5:
            return (pc + 2, 1)
        case 0xC6:
            return (pc + 2, 1)
        case 0xC7:
            return (pc + 2, 1)
        case 0xC8:
            return (pc + 2, 1)
        case 0xC9:
            return (pc + 2, 1)
        case 0xCA:
            return (pc + 2, 1)
        case 0xCB:
            return (pc + 2, 1)
        case 0xCC:
            return (pc + 2, 1)
        case 0xCD:
            return (pc + 2, 1)
        case 0xCE:
            return (pc + 2, 1)
        case 0xCF:
            return (pc + 2, 1)
        case 0xD0:
            return (pc + 2, 1)
        case 0xD1:
            return (pc + 2, 1)
        case 0xD2:
            return (pc + 2, 1)
        case 0xD3:
            return (pc + 2, 1)
        case 0xD4:
            return (pc + 2, 1)
        case 0xD5:
            return (pc + 2, 1)
        case 0xD6:
            return (pc + 2, 1)
        case 0xD7:
            return (pc + 2, 1)
        case 0xD8:
            return (pc + 2, 1)
        case 0xD9:
            return (pc + 2, 1)
        case 0xDA:
            return (pc + 2, 1)
        case 0xDB:
            return (pc + 2, 1)
        case 0xDC:
            return (pc + 2, 1)
        case 0xDD:
            return (pc + 2, 1)
        case 0xDE:
            return (pc + 2, 1)
        case 0xDF:
            return (pc + 2, 1)
        case 0xE0:
            return (pc + 2, 1)
        case 0xE1:
            return (pc + 2, 1)
        case 0xE2:
            return (pc + 2, 1)
        case 0xE3:
            return (pc + 2, 1)
        case 0xE4:
            return (pc + 2, 1)
        case 0xE5:
            return (pc + 2, 1)
        case 0xE6:
            return (pc + 2, 1)
        case 0xE7:
            return (pc + 2, 1)
        case 0xE8:
            return (pc + 2, 1)
        case 0xE9:
            return (pc + 2, 1)
        case 0xEA:
            return (pc + 2, 1)
        case 0xEB:
            return (pc + 2, 1)
        case 0xEC:
            return (pc + 2, 1)
        case 0xED:
            return (pc + 2, 1)
        case 0xEE:
            return (pc + 2, 1)
        case 0xEF:
            return (pc + 2, 1)
        case 0xF0:
            return (pc + 2, 1)
        case 0xF1:
            return (pc + 2, 1)
        case 0xF2:
            return (pc + 2, 1)
        case 0xF3:
            return (pc + 2, 1)
        case 0xF4:
            return (pc + 2, 1)
        case 0xF5:
            return (pc + 2, 1)
        case 0xF6:
            return (pc + 2, 1)
        case 0xF7:
            return (pc + 2, 1)
        case 0xF8:
            return (pc + 2, 1)
        case 0xF9:
            return (pc + 2, 1)
        case 0xFA:
            return (pc + 2, 1)
        case 0xFB:
            return (pc + 2, 1)
        case 0xFC:
            return (pc + 2, 1)
        case 0xFD:
            return (pc + 2, 1)
        case 0xFE:
            return (pc + 2, 1)
        case 0xFF:
            return (pc + 2, 1)
        default:
            // Xcode can't seem to figure out we have all possible cases of a UInt8
            fatalError("Unable to find a case for instruction 0xCB\(String(format: "%02X", pc + 1))!");
        }
    }
}
