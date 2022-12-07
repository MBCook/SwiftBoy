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

enum Interrupts: UInt8 {
    case vblank = 0b00000001
    case lcdStat = 0b00000010
    case timer = 0b00000100
    case serial = 0b00001000
    case joypad = 0b00010000
}

typealias Address = UInt16
typealias Cycles = UInt8
typealias Register = UInt8
typealias RegisterPair = UInt16

enum SpecialLocations: Address {
    case joypad = 0xFF00
    
    case divRegister = 0xFF04
    case timeCounter = 0xFF05
    case timeModulo = 0xFF06
    case timerControl = 0xFF07
    
    case interruptFlags = 0xFF0F
    case interruptEnable = 0xFFFF
}

enum CPUErrors: Error {
    case InvalidInstruction(_ opcode: UInt8)
    case BadAddressForOpcode(_ address: Address)
    case Stopped
}

class CPU {
    // MARK: - First our registers
    
    private var a: Register
    private var b: Register
    private var c: Register
    private var d: Register
    private var e: Register
    private var h: Register
    private var l: Register
    private var flags: Register
    private var sp: Address
    private var pc: Address
    
    // MARK: - Combo registers, which require computed properties
    
    private var af: RegisterPair {
        get {
            return UInt16(a) << 8 + UInt16(flags)
        }
        set(value) {
            a = UInt8(value >> 8)
            flags = UInt8(value & 0x00F0) // Note the bottom 4 bits are always 0, so don't allow them to be set
        }
    }
    private var bc: RegisterPair {
        get {
            return UInt16(b) << 8 + UInt16(c)
        }
        set(value) {
            b = UInt8(value >> 8)
            c = UInt8(value & 0x00FF)
        }
    }
    private var de: RegisterPair {
        get {
            return UInt16(d) << 8 + UInt16(e)
        }
        set(value) {
            d = UInt8(value >> 8)
            e = UInt8(value & 0x00FF)
        }
    }
    private var hl: RegisterPair {
        get {
            return UInt16(h) << 8 + UInt16(l)
        }
        set(value) {
            h = UInt8(value >> 8)
            l = UInt8(value & 0x00FF)
        }
    }
    
    // MARK: - Other things we need to keep track of
    
    private var interruptsMasterEnabledBefore: Bool // Were the interrupts enabled before the current ISR?
    private var interruptsMasterEnabled: Bool       // Are interrupts enabled globally?
    private var halted: Bool                        // If the CPU is wiaitng for an interrupt
    private let memory: Memory                      // Represents all memory, knows the special addressing rules so we don't have to
    private var ticks: UInt16                       // Increases at the instruction clock rate (1/4th the oscillator rate, 2^20 IPS), wraps
    private var lastDiv: UInt16                     // The last time the DIV register was incremented
    private var timerCounter: UInt16                // The last time the counter was incremented
    
    // MARK: - Public interface
    
    // Init sets everything to the values expected once the startup sequence finishes running
    init(memory: Memory) {
        // You can find the default values in many places, https://bgb.bircd.org/pandocs.htm#powerupsequence holds a nice summary
        a = 0x01
        b = 0x00
        c = 0x13
        d = 0x00
        e = 0xD8
        h = 0x01
        l = 0x4D
        flags = 0xB0
        sp = 0xFFFE
        pc = 0x0100
        halted = false
        
        ticks = 0
        lastDiv = 0
        timerCounter = 0
        
        interruptsMasterEnabledBefore = false
        interruptsMasterEnabled = false
        
        self.memory = memory
        
        memory[SpecialLocations.timeCounter.rawValue] = 0x00
        memory[SpecialLocations.timeModulo.rawValue] = 0x00
        memory[SpecialLocations.timerControl.rawValue] = 0x00
        
        memory[SpecialLocations.interruptEnable.rawValue] = 0x00
        memory[SpecialLocations.interruptFlags.rawValue] = 0x00
    }
    
    // The main loop that runs the CPU
    func run() {
        var instructionCount: UInt = 0
        
        var logFile: FileHandle?
        
        defer {
            if logFile != nil {
                try! logFile!.close()
            }
        }
        
        if GAMEBOY_DOCTOR {
            let path = "/Users/michael/Downloads/gameboy-doctor-master/myrun.txt";
            
            logFile = FileHandle(forWritingAtPath: path)
        }
        
        print("Starting")
        
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .decimal
        
        var ticksUsed: Cycles = 0
        
        while !halted {
            // Do useful stuff to us
            
            if GAMEBOY_DOCTOR {
                do {
                    try logFile!.write(contentsOf: generateLogLine().data(using: .utf8)!)
                    
//                    if instructionCount % 1000 == 0 {
//                        try logFile!.synchronize()
//                    }
                } catch {
                    print("Error writing to log file! \(error.localizedDescription)")
                    exit(1)
                }
            }
            
            instructionCount = instructionCount &+ 1
            
            if instructionCount % 50000 == 0 {
//                print(numberFormatter.string(from: NSNumber(integerLiteral: Int(instructionCount)))!)
            }
            
            // Update the various timers if necessary
            
            handleTimerTicks(ticksUsed)
            
            // Handle interrups
            
            // TODO: This
            
            // Handle the next instruction
            
            let op = memory[pc]
            
            do {
                switch pc {
                case 0x8000...0x9FFF,   // Video RAM
                    0xE000...0xFDFF,    // Echo RAM, Nintendo prohibited
                    0xFE00...0xFE9F,    // OAM memory
                    0xFEA0...0xFEFF,    // Nintendo prohibited
                    0xFFFF:             // Interrupt enable register
                    throw CPUErrors.BadAddressForOpcode(pc);    // Shouldn't be here, so throw an error
                default:
                    pc = pc + 0         // To shut Xcode up
                }
                
                // Run the operation, updating the program counter and the number of ticks that were used
                
                (pc, ticksUsed) = try executeOpcode(op)
            } catch CPUErrors.InvalidInstruction(let op) {
                print("Invalid instruction: \(toHex(op))")
                
                return
            } catch CPUErrors.BadAddressForOpcode(let address) {
                print("Invalid address for PC: \(toHex(address))")
                
                return
            } catch CPUErrors.Stopped {
                print("CPU stopped by instruction")
                
                return
            } catch {
                print("An unknown error occurred: \(error.localizedDescription)")
                
                return
            }
        }
    }
    
    // MARK: - Private helper functions
    
    private func generateLogLine() -> String {
        // Write a log line like this:
        //
        // A:00 F:11 B:22 C:33 D:44 E:55 H:66 L:77 SP:8888 PC:9999 PCMEM:AA,BB,CC,DD
        //
        // The stuff after PCMEM are the values at PC+1, PC+2, PC+3, and PC+4 in memory
        
        return "A:\(toHex(a)) F:\(toHex(flags)) B:\(toHex(b)) C:\(toHex(c)) D:\(toHex(d)) " +
              "E:\(toHex(e)) H:\(toHex(h)) L:\(toHex(l)) SP:\(toHex(sp)) PC:\(toHex(pc)) " +
              "PCMEM:\(toHex(memory[pc])),\(toHex(memory[pc &+ 1])),\(toHex(memory[pc &+ 2])),\(toHex(memory[pc &+ 3]))\n"
    }
    
    private func toHex(_ value: UInt8) -> String {
        return String(format: "%02X", value)
    }
    
    private func toHex(_ value: UInt16) -> String {
        return String(format: "%04X", value)
    }
    
    private func getFlag(_ flag: Flags) -> Bool {
        return flags & flag.rawValue > 0
    }
    
    private func setFlagBit(_ flag: Flags) {
        flags = flags | flag.rawValue
    }
    
    private func setFlag(_ flag: Flags, to: Bool) {
        if getFlag(flag) != to {
            if to {
                setFlagBit(flag)
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
    
    private func checkByteHalfCarryAdd(_ a: UInt8, _ b: UInt8, carry: Bool = false) -> Bool {
        return ((a & 0x0F) + (b & 0x0F) + (carry ? 1 : 0)) & 0x10 > 0
    }
    
    private func checkByteHalfCarrySubtract(_ a: UInt8, _ b: UInt8, carry: Bool = false) -> Bool {
        return ((a & 0x0F) &- (b & 0x0F) &- (carry ? 1 : 0)) & 0x10 > 0
    }
    
    private func checkWordHalfCarryAdd(_ a: UInt16, _ b: UInt16) -> Bool {
        return (a & 0x0FFF) + (b & 0x0FFF) > 0x0FFF
    }
    
    private func checkWordHalfCarrySubtract(_ a: UInt16, _ b: UInt16) -> Bool {
        return Int(a & 0x0FFF) - Int(b & 0x0FFF) < 0
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
    
    private func push(_ value: UInt16) {
        let low = UInt8(value & 0x00FF)
        let high = UInt8((value & 0xFF00) >> 8)
        
        memory[sp - 1] = high
        memory[sp - 2] = low
        
        sp = sp - 2
    }
    
    private func pop() -> UInt16 {
        let value = UInt16(memory[sp]) + UInt16(memory[sp + 1]) << 8
        
        sp = sp + 2
        
        return value
    }
    
    private func resetVector(_ index: UInt8) -> (Address, Cycles) {
        push(pc + 1)
        
        return (UInt16(index) * 8, 4)
    }
    
    // MARK: - Helper functions that let us generalize op-codes and pass in the registers
    
    private func loadWordIntoRegisterPair(_ register: inout RegisterPair, address: Address) {
        register = readWord(address)
    }
    
    private func incrementRegister(_ register: inout Register) {
        let old = register
        
        register = register &+ 1
        
        setFlags(zero: register == 0, subtraction: false, halfCarry: checkByteHalfCarryAdd(old, 1), carry: nil)
    }
    
    private func decrementRegister(_ register: inout Register) {
        let old = register
        
        register = register &- 1
        
        setFlags(zero: register == 0, subtraction: true, halfCarry: checkByteHalfCarrySubtract(old, 1), carry: nil)
    }
    
    private func addToRegisterPair(_ register: inout RegisterPair, _ amount: UInt16) {
        let halfCarry = checkWordHalfCarryAdd(register, amount)
        let oldRegister = register
        
        register = register &+ amount
        
        setFlags(zero: nil, subtraction: false, halfCarry: halfCarry, carry: oldRegister > register)
    }
    
    private func jumpByByteOnFlag(_ flag: Flags, negate: Bool) ->  (Address, Cycles) {
        if getFlag(flag) == !negate {
            // The flag is set to the right value, jump to the offset (which is SIGNED)
            
            let signedOffset = Int8(bitPattern: memory[pc + 1])
            let signedOffsetExpanded = Int16(signedOffset)
            let newPC = pc &+ UInt16(bitPattern: signedOffsetExpanded) &+ 2 // The 2 is for the size of this instruction (already 'done')
            
            return (newPC, 3)
        } else {
            // The flag was the wrong value, keep going without a jump
            
            return (pc + 2, 2)
        }
    }
    
    private func jumpToWordOnFlag(_ flag: Flags, negate: Bool) ->  (Address, Cycles) {
        if getFlag(flag) == !negate {
            // The flag is set to the right value, jump to the offset
            
            return (readWord(pc + 1), 4)
        } else {
            // The flag was the wrong value, keep going without a jump
            
            return (pc + 3, 3)
        }
    }
    
    private func returnOnFlag(_ flag: Flags, negate: Bool) ->  (Address, Cycles) {
        if getFlag(flag) == !negate {
            // The flag is set to the right value, perform a return
            
            return (pop(), 5)
        } else {
            // The flag was the wrong value, keep going without a return
            
            return (pc + 1, 2)
        }
    }
    
    private func callOnFlag(_ flag: Flags, negate: Bool) ->  (Address, Cycles) {
        if getFlag(flag) == !negate {
            // The flag is set to the right value, perform a return
            
            push(pc + 3)    // The +3 is for the bytes of this instruction
            
            return (readWord(pc + 1), 5)
        } else {
            // The flag was the wrong value, keep going without a return
            
            return (pc + 3, 3)
        }
    }
    
    private func rotateLeftCopyCarry(_ value: UInt8) -> UInt8 {
        let rotated = value << 1
        let carry = value & 0b10000000 > 0  // The high bit will become the low bit AND the carry flag
        
        setFlags(zero: false, subtraction: false, halfCarry: false, carry: carry)
        
        return rotated + (carry ? 1 : 0)
    }
    
    private func rotateLeftThroughCarry(_ value: UInt8) -> UInt8 {
        let rotated = value << 1 + (getFlag(.carry) ? 1 : 0)
        let carry = value & 0b10000000 > 0  // The high bit will become the the carry flag
        
        setFlags(zero: false, subtraction: false, halfCarry: false, carry: carry)
        
        return rotated  // The old cary flag becomes bit 0
    }
    
    private func rotateRightCopyCarry(_ value: UInt8) -> UInt8 {
        let rotated = value >> 1
        let carry = value & 0b00000001 > 0  // The low bit will become the high bit AND the carry flag
        
        setFlags(zero: false, subtraction: false, halfCarry: false, carry: carry)
        
        return rotated + (carry ? 0b10000000 : 0)
    }
    
    private func rotateRightThroughCarry(_ value: UInt8) -> UInt8 {
        let rotated = value >> 1 + (getFlag(.carry) ? 0b10000000 : 0)
        let carry = value & 0b00000001 > 0  // The low bit will become the carry flag
        
        setFlags(zero: rotated == 0, subtraction: false, halfCarry: false, carry: carry)
        
        return rotated // The high bit is now what the carry flag holds
    }
    
    private func arithmeticShiftLeft(_ value: UInt8) -> UInt8 {
        let rotated = value << 1
        let carry = value & 0b10000000 > 0
        
        setFlags(zero: rotated == 0, subtraction: false, halfCarry: false, carry: carry)
        
        return rotated
    }
    
    private func arithmeticShiftRight(_ value: UInt8) -> UInt8 {
        let rotated = value >> 1
        let carry = value & 0b00000001 > 0
        let oldBit7 = value & 0b10000000
        
        setFlags(zero: rotated == 0, subtraction: false, halfCarry: false, carry: carry)
        
        return rotated + oldBit7
    }
    
    private func logicalShiftRight(_ value: UInt8) -> UInt8 {
        let rotated = value >> 1
        let carry = value & 0b00000001 > 0
        
        setFlags(zero: rotated == 0, subtraction: false, halfCarry: false, carry: carry)
        
        return rotated
    }
    
    private func swapNibbles(_ value: UInt8) -> UInt8 {
        let result = value << 4 + value >> 4
        
        setFlags(zero: result == 0, subtraction: false, halfCarry: false, carry: false)
        
        return result
    }
    
    // MARK: - Interrupt servicing
    
    private func handleTimerTicks(_ ticks: UInt8) {
        // TODO: This
        
        // Need to keep track of stop vs halt
        // Stop kills everything until joypad input, then picks up where it left off
        // Halt stops running new instructions but timers keep going waiting for an interrupt
    }
    
    // MARK: - Opcode dispatch
    
    // Runs the opcode at PC, returns the new value for PC and how many cycles were used (divided by four)
    // NOTE: We use the no-overflow operators (&+, &-) because that's how a GB would work
    private func executeOpcode(_ op: UInt8) throws -> (Address, Cycles) {
        switch (op) {
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
            
            a = rotateLeftCopyCarry(a)
            
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
            
            a = rotateRightCopyCarry(a)
            
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
            
            a = rotateLeftThroughCarry(a)
            
            return (pc + 1, 1)
        case 0x18:
            // JR s8
            
            return (pc + UInt16(memory[pc + 1]) + 2, 3) // The + 2 is for the bytes of this instruction
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
            
            decrementRegister(&e)
            
            return (pc + 1, 1)
        case 0x1E:
            // LD E, d8
            
            e = memory[pc + 1]
            
            return (pc + 2, 2)
        case 0x1F:
            // RRA
            
            a = rotateRightThroughCarry(a)
            
            clearFlag(.zero)    // The function above can set this, but this specific instruction should always clear it
            
            return (pc + 1, 1)
        case 0x20:
            // JR NZ, s8
            
            return jumpByByteOnFlag(.zero, negate: true)
        case 0x21:
            // LD HL, d16
            
            hl = readWord(pc + 1)
            
            return (pc + 3, 3)
        case 0x22:
            // LD (HL+), A
            
            memory[hl] = a
            
            hl = hl &+ 1
            
            return (pc + 1, 2)
        case 0x23:
            // INC HL
            
            hl = hl &+ 1
            
            return (pc + 1, 2)
        case 0x24:
            // INC H
            
            incrementRegister(&h)
            
            return (pc + 1, 1)
        case 0x25:
            // DEC H
            
            decrementRegister(&h)
            
            return (pc + 1, 1)
        case 0x26:
            // LD H, d8
            
            h = memory[pc + 1]
            
            return (pc + 2, 2)
        case 0x27:
            // DAA
            
            // Excellent descriptions of this at:
            //  https://forums.nesdev.org/viewtopic.php?t=15944
            //  and https://ehaskins.com/2018-01-30%20Z80%20DAA/
            
            if !getFlag(.subtraction) {
                // Adjust things if a carry of some kind occured or there is an out of bounds condition
                
                if getFlag(.carry) || a > 0x99 {
                    a = a &+ 0x60
                    setFlagBit(.carry)
                }
                
                if getFlag(.halfCarry) || (a & 0x0F) > 0x09 {
                    a = a &+ 0x06
                }
            } else {
                // After subtraction only adjust if there was a carry of some kind
                
                if getFlag(.carry) {
                    a = a &- 0x60
                }
                
                if getFlag(.halfCarry) {
                    a = a &- 0x06
                }
            }
            
            setFlag(.zero, to: a == 0)
            clearFlag(.halfCarry)
            
            return (pc + 1, 1)
        case 0x28:
            // JR Z, s8
            
            return jumpByByteOnFlag(.zero, negate: false)
        case 0x29:
            // ADD HL, HL
            
            addToRegisterPair(&hl, hl)
            
            return (pc + 1, 2)
        case 0x2A:
            // LD A, (HL+)
            
            a = memory[hl]
            
            hl = hl &+ 1
            
            return (pc + 1, 2)
        case 0x2B:
            // DEC HL
            
            hl = hl &- 1
            
            return (pc + 1, 2)
        case 0x2C:
            // INC L
            
            incrementRegister(&l)
            
            return (pc + 1, 1)
        case 0x2D:
            // DEC L
            
            decrementRegister(&l)
            
            return (pc + 1, 1)
        case 0x2E:
            // LD L, d8
            
            l = memory[pc + 1]
            
            return (pc + 2, 2)
        case 0x2F:
            // CPL
            
            a = a ^ 0xFF
            
            setFlags(zero: nil, subtraction: true, halfCarry: true, carry: nil)
            
            return (pc + 1, 1)
        case 0x30:
            // JR NC, s8
            
            return jumpByByteOnFlag(.carry, negate: true)
        case 0x31:
            // LD SP, d16
            
            sp = readWord(pc + 1)
            
            return (pc + 3, 3)
        case 0x32:
            // LD (HL-), A
            
            memory[hl] = a
            
            hl = hl &- 1
            
            return (pc + 1, 2)
        case 0x33:
            // INC SP
            
            sp = sp &+ 1
            
            return (pc + 1, 2)
        case 0x34:
            // INC (HL)
            
            let old = memory[hl]
            
            memory[hl] = memory[hl] &+ 1
            
            setFlags(zero: memory[hl] == 0, subtraction: false, halfCarry: checkByteHalfCarryAdd(old, 1), carry: nil)
            
            return (pc + 1, 3)
        case 0x35:
            // DEC (HL)
            
            let old = memory[hl]
            
            memory[hl] = memory[hl] &- 1
            
            setFlags(zero: memory[hl] == 0, subtraction: true, halfCarry: checkByteHalfCarrySubtract(old, 1), carry: nil)
            
            return (pc + 1, 3)
        case 0x36:
            // LD (HL), d8
            
            memory[hl] = memory[pc + 1]
            
            return (pc + 2, 3)
        case 0x37:
            // SCF
            
            setFlags(zero: nil, subtraction: false, halfCarry: false, carry: true)
            
            return (pc + 1, 1)
        case 0x38:
            // JR C, s8
            
            return jumpByByteOnFlag(.carry, negate: false)
        case 0x39:
            // ADD HL, SP
            
            addToRegisterPair(&hl, sp)
            
            return (pc + 1, 2)
        case 0x3A:
            // LD A, (HL-)
            
            a = memory[hl]
            
            hl = hl &- 1
            
            return (pc + 1, 2)
        case 0x3B:
            // DEC SP
            
            sp = sp &- 1
            
            return (pc + 1, 2)
        case 0x3C:
            // INC A
            
            incrementRegister(&a)
            
            return (pc + 1, 1)
        case 0x3D:
            // DEC A
            
            decrementRegister(&a)
            
            return (pc + 1, 1)
        case 0x3E:
            // LD A, d8
            
            a = memory[pc + 1]
            
            return (pc + 2, 2)
        case 0x3F:
            // CCF
            
            setFlags(zero: nil, subtraction: false, halfCarry: false, carry: !getFlag(.carry))
            
            return (pc + 1, 1)
        case 0x76:
            // Note: This is the one exception in the interval below.
            // So we'll handle it here to exclude it even though that's out of order
            
            halted = true
            
            return (pc + 1, 1)
        case 0x40...0x7F:
            // LD ?, ? or LD ?, (HL)
            
            // This is a big block of load instructions that just have different values for the two parameters.
            // Instead of writing all these out, we'll parse out what to do from the patter in the bits in another function
            
            return handleLoadBlock(op)
        case 0x80...0x87:
            // ADD A, ?
            
            let (source, memoryUsed) = getCorrectSource(op)
            let oldA = a
            
            a = a &+ source
            
            // Carry is set if we wrapped around (oldA > a)
            setFlags(zero: a == 0, subtraction: false, halfCarry: checkByteHalfCarryAdd(oldA, source), carry: oldA > a)
            
            if memoryUsed {
                return (pc + 1, 2)
            } else {
                return (pc + 1, 1)
            }
        case 0x88...0x8F:
            // ADC A, ?
            
            let (source, memoryUsed) = getCorrectSource(op)
            
            let extra = UInt8(getFlag(.carry) ? 1 : 0)
            let subtotal = source &+ extra
            let oldA = a
            
            a = a &+ subtotal
            
            // There are two carry possibilities
            let carry = (oldA &+ source < oldA) || (oldA &+ subtotal < oldA &+ source)
                        
            setFlags(zero: a == 0, subtraction: false, halfCarry: checkByteHalfCarryAdd(oldA, source, carry: extra == 1), carry: carry)
            
            if memoryUsed {
                return (pc + 1, 2)
            } else {
                return (pc + 1, 1)
            }
        case 0x90...0x97:
            // SUB ?
            
            let (source, memoryUsed) = getCorrectSource(op)
            
            let oldA = a
            
            a = a &- source
            
            // Carry is set if the value subtracted from A was bigger than A
            setFlags(zero: a == 0, subtraction: true, halfCarry: checkByteHalfCarrySubtract(oldA, source), carry: source > oldA)
            
            if memoryUsed {
                return (pc + 1, 2)
            } else {
                return (pc + 1, 1)
            }
        case 0x98...0x9F:
            // SBC ?
            
            let (source, memoryUsed) = getCorrectSource(op)
            
            let extra = UInt8(getFlag(.carry) ? 1 : 0)
            let subtotal = source &+ extra   // Plus becasue we want to subtract MORE
            
            let oldA = a

            a = a &- subtotal
            
            let halfCarry = checkByteHalfCarrySubtract(oldA, source, carry: extra == 1)
            
            // There are two possible carries
            let carry = (oldA &- source > oldA) || (oldA &- subtotal > oldA &- source)
            
            // Carry is set if the value subtracted from A was bigger than A
            setFlags(zero: a == 0, subtraction: true, halfCarry: halfCarry, carry: carry)
            
            if memoryUsed {
                return (pc + 1, 2)
            } else {
                return (pc + 1, 1)
            }
        case 0xA0...0xA7:
            // AND ?
            
            let (source, memoryUsed) = getCorrectSource(op)
            
            a = a & source
            
            setFlags(zero: a == 0, subtraction: false, halfCarry: true, carry: false)
            
            if memoryUsed {
                return (pc + 1, 2)
            } else {
                return (pc + 1, 1)
            }
        case 0xA8...0xAF:
            // XOR ?
            
            let (source, memoryUsed) = getCorrectSource(op)
            
            a = a ^ source
            
            setFlags(zero: a == 0, subtraction: false, halfCarry: false, carry: false)
            
            if memoryUsed {
                return (pc + 1, 2)
            } else {
                return (pc + 1, 1)
            }
        case 0xB0...0xB7:
            // OR ?
            
            let (source, memoryUsed) = getCorrectSource(op)
            
            a = a | source
            
            setFlags(zero: a == 0, subtraction: false, halfCarry: false, carry: false)
            
            if memoryUsed {
                return (pc + 1, 2)
            } else {
                return (pc + 1, 1)
            }
        case 0xB8...0xBF:
            // CP ?
            
            let (source, memoryUsed) = getCorrectSource(op)
            
            // Carry is set if the value compated to A was bigger than A (becuase it uses SUB of A - source internally)
            setFlags(zero: a == source, subtraction: true, halfCarry: checkByteHalfCarrySubtract(a, source), carry: source > a)
            
            if memoryUsed {
                return (pc + 1, 2)
            } else {
                return (pc + 1, 1)
            }
        case 0xC0:
            // RET NZ
            
            return returnOnFlag(.zero, negate: true)
        case 0xC1:
            // POP BC
            
            bc = pop()
            
            return (pc + 1, 3)
        case 0xC2:
            // JP NZ, a16
            
            return jumpToWordOnFlag(.zero, negate: true)
        case 0xC3:
            // JP a16
            
            return (readWord(pc + 1), 4)
        case 0xC4:
            // CALL NZ, a16
            
            return callOnFlag(.zero, negate: true)
        case 0xC5:
            // PUSH BC
            
            push(bc)
            
            return (pc + 1, 4)
        case 0xC6:
            // ADD A, d8
            
            let oldA = a
            
            a = a &+ memory[pc + 1]
            
            // Carry is set if we wrapped around (oldA > a)
            setFlags(zero: a == 0, subtraction: false, halfCarry: checkByteHalfCarryAdd(oldA, memory[pc + 1]), carry: oldA > a)
            
            return (pc + 2, 2)
        case 0xC7:
            // RST 0
            
            return resetVector(0)
        case 0xC8:
            // RET Z
            
            return returnOnFlag(.zero, negate: false)
        case 0xC9:
            // RET
            
            return (pop(), 4)
        case 0xCA:
            // JMP Z, a16
            
            return jumpToWordOnFlag(.zero, negate: false)
        case 0xCB:
            // This is a prefix for a second set of 256 instructions.
            // We have a different function to handle those.
            
            return executeCBOpcode(memory[pc + 1])
        case 0xCC:
            // CALL Z, a16
            
            return callOnFlag(.zero, negate: false)
        case 0xCD:
            // CALL a16
            
            push(pc + 3)    // The +3 is for the bytes of this instruction
            
            return (readWord(pc + 1), 6)
        case 0xCE:
            // ADC A, d8
            
            let source = memory[pc + 1]
            let extra = UInt8(getFlag(.carry) ? 1 : 0)
            let subtotal = source &+ extra
            let oldA = a
            
            a = a &+ subtotal
            
            let halfCarry = checkByteHalfCarryAdd(oldA, source, carry: extra == 1)
            
            // There are two carry possibilities
            let carry = (oldA &+ source < oldA) || (oldA &+ subtotal < oldA &+ source)
            
            setFlags(zero: a == 0, subtraction: false, halfCarry: halfCarry, carry: carry)
            
            return (pc + 2, 2)
        case 0xCF:
            // RST 1
            
            return resetVector(1)
        case 0xD0:
            // RET NC
            
            return returnOnFlag(.carry, negate: true)
        case 0xD1:
            // POP DE
            
            de = pop()
            
            return (pc + 1, 3)
        case 0xD2:
            // JMP NC, a16
            
            return jumpToWordOnFlag(.carry, negate: true)
        case 0xD3:
            throw CPUErrors.InvalidInstruction(op)
        case 0xD4:
            // CALL NC, a16
            
            return callOnFlag(.carry, negate: true)
        case 0xD5:
            // PUSH DE
            
            push(de)
            
            return (pc + 1, 4)
        case 0xD6:
            // SUB d8
            
            let source = memory[pc + 1]
            let oldA = a
            
            a = a &- source
            
            // Carry is set if we subtracted more than was there (oldA < source)
            setFlags(zero: a == 0, subtraction: true, halfCarry: checkByteHalfCarrySubtract(oldA, source), carry: oldA < source)
            
            return (pc + 2, 2)
        case 0xD7:
            // RST 2
            
            return resetVector(2)
        case 0xD8:
            // RET C
            
            return returnOnFlag(.carry, negate: false)
        case 0xD9:
            // RETI
            
            interruptsMasterEnabled = interruptsMasterEnabledBefore
            
            return (pop(), 4)
        case 0xDA:
            // JMP C, a16
            
            return jumpToWordOnFlag(.carry, negate: false)
        case 0xDB:
            throw CPUErrors.InvalidInstruction(op)
        case 0xDC:
            // CALL C, a16
            
            return callOnFlag(.carry, negate: false)
        case 0xDD:
            throw CPUErrors.InvalidInstruction(op)
        case 0xDE:
            // SBC A, d8
            
            let source = memory[pc + 1]
            let extra = UInt8(getFlag(.carry) ? 1 : 0)
            let subtotal = source &+ extra  // Plus because we want to subtract MORE below
            let oldA = a
            
            a = a &- subtotal
            
            let halfCarry = checkByteHalfCarrySubtract(oldA, source, carry: extra == 1)
            
            // There are two possible carries
            let carry = (oldA &- source > oldA) || (oldA &- subtotal > oldA &- source)
            
            setFlags(zero: a == 0, subtraction: true, halfCarry: halfCarry, carry: carry)
            
            return (pc + 2, 2)
        case 0xDF:
            // RST 3
            
            return resetVector(3)
        case 0xE0:
            // LD (a8), A
            
            memory[0xFF00 + UInt16(memory[pc + 1])] = a
            
            return (pc + 2, 3)
        case 0xE1:
            // POP HL
            
            hl = pop()
            
            return (pc + 1, 3)
        case 0xE2:
            // LD (C), A
            
            memory[0xFF00 + UInt16(c)] = a
            
            return (pc + 1, 2)
        case 0xE3:
            throw CPUErrors.InvalidInstruction(op)
        case 0xE4:
            throw CPUErrors.InvalidInstruction(op)
        case 0xE5:
            // PUSH HL
            
            push(hl)
            
            return (pc + 1, 4)
        case 0xE6:
            // AND d8
            
            a = a & memory[pc + 1]
            
            setFlags(zero: a == 0, subtraction: false, halfCarry: true, carry: false)
            
            return (pc + 2, 2)
        case 0xE7:
            // RST 4
            
            return resetVector(4)
        case 0xE8:
            // ADD SP, s8
            
            let signedValue = UInt16(bitPattern: Int16(Int8(bitPattern: memory[pc + 1])))
            let oldSP = sp
            
            sp = sp &+ signedValue
            
            // All flags are based on the lower byte, as if we were doing an 8 bit addition
            
            let halfCarry = checkByteHalfCarryAdd(UInt8(oldSP & 0x00FF), UInt8(signedValue & 0x0FF))
            
            let carry = UInt8(oldSP & 0x00FF) > UInt8(sp & 0x0FF)
            
            // Carry is set on 8 bit rules, did we carry from lower byte to higher?
            setFlags(zero: false, subtraction: false, halfCarry: halfCarry, carry: carry)
            
            return (pc + 2, 4)
        case 0xE9:
            // JMP HL
            
            return (hl, 1)
        case 0xEA:
            // LD (a16), A
            
            memory[readWord(pc + 1)] = a
            
            return (pc + 3, 4)
        case 0xEB:
            throw CPUErrors.InvalidInstruction(op)
        case 0xEC:
            throw CPUErrors.InvalidInstruction(op)
        case 0xED:
            throw CPUErrors.InvalidInstruction(op)
        case 0xEE:
            // XOR d8
            
            a = a ^ memory[pc + 1]
            
            setFlags(zero: a == 0, subtraction: false, halfCarry: false, carry: false)
            
            return (pc + 2, 2)
        case 0xEF:
            // RST 5
            
            return resetVector(5)
        case 0xF0:
            // LD A, (d8)
            
            let address = 0xFF00 + UInt16(memory[pc + 1])
            
            a = memory[address]
            
            return (pc + 2, 3)
        case 0xF1:
            // POP AF
            
            af = pop()
            
            return (pc + 1, 3)
        case 0xF2:
            // LD A, (C)
            
            a = memory[0xFF00 + UInt16(c)]
            
            return (pc + 1, 2)
        case 0xF3:
            // DI
            
            interruptsMasterEnabled = false
            
            return (pc + 1, 1)
        case 0xF4:
            throw CPUErrors.InvalidInstruction(op)
        case 0xF5:
            // PUSH AF
            
            push(af)
            
            return (pc + 1, 4)
        case 0xF6:
            // OR d8
            
            a = a | memory[pc + 1]
            
            setFlags(zero: a == 0, subtraction: false, halfCarry: false, carry: false)
            
            return (pc + 2, 2)
        case 0xF7:
            // RST 6
            
            return resetVector(6)
        case 0xF8:
            // LD HL, SP + s8
            
            let signedValue = UInt16(bitPattern: Int16(Int8(bitPattern: memory[pc + 1])))
            
            hl = sp &+ signedValue
            
            // All flags are based on the lower byte, as if we were doing an 8 bit addition
            
            let halfCarry = checkByteHalfCarryAdd(UInt8(sp & 0x00FF), UInt8(signedValue & 0x00FF))
            
            let carry = UInt8(sp & 0x00FF) > UInt8(hl & 0x0FF)
            
            setFlags(zero: false, subtraction: false, halfCarry: halfCarry, carry: carry)
            
            return (pc + 2, 3)
        case 0xF9:
            // LD SP, HL
            
            sp = hl
            
            return (pc + 1, 2)
        case 0xFA:
            // LD A, (a16)
            
            a = memory[readWord(pc + 1)]
            
            return (pc + 3, 4)
        case 0xFB:
            // EI
            
            interruptsMasterEnabled = true
            
            return (pc + 1, 1)
        case 0xFC:
            throw CPUErrors.InvalidInstruction(op)
        case 0xFD:
            throw CPUErrors.InvalidInstruction(op)
        case 0xFE:
            // CP d8
            
            let source = memory[pc + 1]
            
            // Carry is set if the value compated to A was bigger than A (becuase it uses SUB of A - source internally)
            setFlags(zero: a == source, subtraction: true, halfCarry: checkByteHalfCarrySubtract(a, source), carry: source > a)
            
            return (pc + 2, 2)
        case 0xFF:
            // RST 7
            
            return resetVector(7)
        default:
            // Xcode can't seem to figure out we have all possible cases of a UInt8
            fatalError("Unable to find a case for instruction 0x\(toHex(op))!");
        }
    }
    
    // Same as above, but all opcodes are prefixed with 0xCB so we have to make sure to take that into account
    private func executeCBOpcode(_ op: UInt8) -> (Address, Cycles) {
        switch (op) {   // Skip the 0xCB byte, we already know that one
        case 0x00...0x07:
            // RLC ?
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            let rotated = rotateLeftCopyCarry(value)
            
            setCorrectDestination(op, value: rotated)
            
            setFlags(zero: rotated == 0, subtraction: false, halfCarry: false, carry: value & 0x80 > 0)
            
            if memoryUsed {
                return (pc + 2, 4)
            } else {
                return (pc + 2, 2)
            }
        case 0x08...0x0F:
            // RRC ?
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            let rotated = rotateRightCopyCarry(value)
            
            setCorrectDestination(op, value: rotated)
            
            setFlags(zero: rotated == 0, subtraction: false, halfCarry: false, carry: value & 0x01 > 0)
            
            if memoryUsed {
                return (pc + 2, 4)
            } else {
                return (pc + 2, 2)
            }
        case 0x10...0x17:
            // RL ?
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            let rotated = rotateLeftThroughCarry(value)
            
            setCorrectDestination(op, value: rotated)
            
            setFlags(zero: rotated == 0, subtraction: false, halfCarry: false, carry: value & 0x80 > 0)
            
            if memoryUsed {
                return (pc + 2, 4)
            } else {
                return (pc + 2, 2)
            }
        case 0x18...0x1F:
            // RR ?
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            let rotated = rotateRightThroughCarry(value)
            
            setCorrectDestination(op, value: rotated)
            
            setFlags(zero: rotated == 0, subtraction: false, halfCarry: false, carry: value & 0x01 > 0)
            
            if memoryUsed {
                return (pc + 2, 4)
            } else {
                return (pc + 2, 2)
            }
        case 0x20...0x27:
            // SLA ?
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            let shifted = arithmeticShiftLeft(value)
            
            setCorrectDestination(op, value: shifted)
            
            setFlags(zero: shifted == 0, subtraction: false, halfCarry: false, carry: value & 0x80 > 0)
            
            if memoryUsed {
                return (pc + 2, 4)
            } else {
                return (pc + 2, 2)
            }
        case 0x28...0x2F:
            // SRA ?
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            let shifted = arithmeticShiftRight(value)
            
            setCorrectDestination(op, value: shifted)
            
            setFlags(zero: shifted == 0, subtraction: false, halfCarry: false, carry: value & 0x01 > 0)
            
            if memoryUsed {
                return (pc + 2, 4)
            } else {
                return (pc + 2, 2)
            }
        case 0x30...0x37:
            // SWAP ?
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            setCorrectDestination(op, value: swapNibbles(value))
            
            // The swapped value will only be 0 if value was 0
            setFlags(zero: value == 0, subtraction: false, halfCarry: false, carry: false)
            
            if memoryUsed {
                return (pc + 2, 4)
            } else {
                return (pc + 2, 2)
            }
        case 0x38...0x3F:
            // SRL ?
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            let shifted = logicalShiftRight(value)
            
            setCorrectDestination(op, value: shifted)
            
            setFlags(zero: shifted == 0, subtraction: false, halfCarry: false, carry: value & 0x01 > 0)
            
            if memoryUsed {
                return (pc + 2, 4)
            } else {
                return (pc + 2, 2)
            }
        case 0x40...0x7F:
            // BIT #, ?
            
            // Which bit we want is in bits 5-3 of the opcode, so we'll extract it
            
            let bit = (memory[pc + 1] & 0b00111000) >> 3
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            // Find out if that bit is set
            
            let bitSet = (1 << bit) & value > 0
            
            setFlags(zero: !bitSet, subtraction: false, halfCarry: true, carry: nil)
            
            if memoryUsed {
                return (pc + 2, 3)
            } else {
                return (pc + 2, 2)
            }
        case 0x80...0xBF:
            // RES #, ?
            
            // Which bit we want is in bits 5-3 of the opcode, so we'll extract it
            
            let bit = (memory[pc + 1] & 0b00111000) >> 3
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            // Generate our mask without that bit in it
            
            let mask = 0xFF as UInt8 - (1 << bit)
            
            setCorrectDestination(op, value: value & mask)
            
            if memoryUsed {
                return (pc + 2, 4)
            } else {
                return (pc + 2, 2)
            }
        case 0xC0...0xFF:
            // SET #, ?
            
            // Which bit we want is in bits 5-3 of the opcode, so we'll extract it
            
            let bit = (op & 0b00111000) >> 3
            
            let (value, memoryUsed) = getCorrectSource(op)
            
            // Set that bit in the value and put it back where it came from
            
            setCorrectDestination(op, value: value | (1 << bit))
            
            if memoryUsed {
                return (pc + 2, 4)
            } else {
                return (pc + 2, 2)
            }
        default:
            // Xcode can't seem to figure out we have all possible cases of a UInt8
            fatalError("Unable to find a case for instruction 0xCB\(toHex(op))!");
        }
    }
    
    private func handleLoadBlock(_ op: UInt8) -> (Address, Cycles) {
        // So 0x40 - 0x6F is a bunch of very repeatable instructions. We can use some bit math to decode what's going on.
        // First we need to figure out the source, which we can get by masking out the last 3 bits
        
        var (value, memoryUsed) = getCorrectSource(op)
            
        // Now we put it in the right place based on the higher bits
            
        switch op {
        case 0x40...0x47:
            b = value
        case 0x48...0x4F:
            c = value
        case 0x50...0x57:
            d = value
        case 0x58...0x5F:
            e = value
        case 0x60...0x67:
            h = value
        case 0x68...0x6F:
            l = value
        case 0x70...0x77:
            memory[hl] = value
            memoryUsed = true
        case 0x78...0x7F:
            a = value
        default:
            // Xcode has no way of knowing other values won't be passed in
            fatalError("Unable to find a destination for load instruction 0x\(toHex(op))!");
        }
        
        // We've done the work. Now there is one question left. This all takes 1 cycle, unless we had to access (HL).
        
        if memoryUsed {
            return (pc + 1, 2)  // We accessed memroy, that's two cycles total
        } else {
            return (pc + 1, 1)  // Just register access, no memory access
        }
    }
    
    // Get the source operand, return it and if memory access was used
    private func getCorrectSource(_ op: UInt8) -> (UInt8, Bool) {
        // The last 3 bits encode the source for a large number of instructions, so this ends up being handy
        switch op & 0x07 {
        case 0:
            return (b, false)
        case 1:
            return (c, false)
        case 2:
            return (d, false)
        case 3:
            return (e, false)
        case 4:
            return (h, false)
        case 5:
            return (l, false)
        case 6:
            return (memory[hl], true)
        case 7:
            return (a, false)
        default:
            // Xcode can't seem to figure out we have all possible cases covered
            fatalError("Unable to find a source operand for instruction 0x\(toHex(op))!");
        }
    }
    
    // Get the source operand, return it and if memory access was used
    private func setCorrectDestination(_ op: UInt8, value: UInt8) {
        // The last 3 bits encode the destination for a large number of instructions (same as the source), so this ends up being handy
        switch op & 0x07 {
        case 0:
            b = value
        case 1:
            c = value
        case 2:
            d = value
        case 3:
            e = value
        case 4:
            h = value
        case 5:
            l = value
        case 6:
            memory[hl] = value
        case 7:
            a = value
        default:
            // Xcode can't seem to figure out we have all possible cases covered
            fatalError("Unable to find a destination operand for instruction 0x\(toHex(op))!");
        }
    }
}
