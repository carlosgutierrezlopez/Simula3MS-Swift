import Foundation

struct CPUExecutionResult {
    let steps: Int
    let halted: Bool
    let registers: [String: Int]
    let floatingRegisters: [String: UInt32]
    let trace: [String]
    let cycles: [CPUCycleSnapshot]
    let ioOutput: String
    let interruptCount: Int
    let dataMemoryWords: [MemoryWord]
    let textRows: [TextRow]
}

struct CPUCycleSnapshot: Identifiable {
    let id = UUID()
    let cycle: Int
    let pcBefore: Int
    let pcAfter: Int
    let instruction: String
    let t0: Int
    let t1: Int
    let t2: Int
    let s0: Int
    let s1: Int
    let hi: Int
    let lo: Int
}

struct MemoryWord: Identifiable {
    let id = UUID()
    let address: Int
    let value: Int
}

struct TextRow: Identifiable {
    let id = UUID()
    let address: Int
    let machineCode: Int
    let instruction: String
}

enum CPUExecutionError: Error {
    case invalidRegister(String)
    case invalidFloatRegister(String)
    case invalidImmediate(String)
    case invalidAddress(String)
    case unknownInstruction(String)
    case unknownLabel(String)
    case divisionByZero
}

enum BranchExecutionMode {
    case fixed
    case delayed
}

enum IOExecutionMode {
    case mapped
    case interrupts
    case disabled
}

final class CPUEngine {
    private var registers: [String: Int] = [:]
    private var floatingRegisters: [String: UInt32] = [:]
    private var memoryBytes: [Int: UInt8] = [:]
    private var pc: Int = 0
    private var trace: [String] = []

    private var labels: [String: Int] = [:]
    private var dataLabelAddresses: [String: Int] = [:]
    private var hi: Int = 0
    private var lo: Int = 0
    private var fpCondition: Bool = false

    private var cp0BadVaddr: Int = 0
    private var cp0Status: Int = 0
    private var cp0Cause: Int = 0
    private var cp0Epc: Int = 0
    private var heapBreak: Int = 0x10040000

    private var branchMode: BranchExecutionMode = .fixed
    private var pendingBranchTarget: Int?
    private var pendingBranchDelaySlots = 0

    private var ioMode: IOExecutionMode = .mapped
    private var ioOutput = ""
    private var ioInputBuffer: [UInt8] = []
    private var interruptCount = 0

    private let mmioKeyboardDataAddress = 0xFFFF0004
    private let mmioDisplayDataAddress = 0xFFFF000C

    private let writableRegisters: Set<String> = [
        "$at", "$v0", "$v1",
        "$a0", "$a1", "$a2", "$a3",
        "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6", "$t7", "$t8", "$t9",
        "$s0", "$s1", "$s2", "$s3", "$s4", "$s5", "$s6", "$s7",
        "$k0", "$k1", "$gp", "$sp", "$fp", "$ra"
    ]
    private let floatingRegisterNames: Set<String> = Set((0...31).map { "$f\($0)" })

    private let readableRegisters: Set<String>

    init() {
        readableRegisters = writableRegisters.union(["$zero"])
        reset()
    }

    func execute(
        program: [AssembledInstruction],
        labels: [String: Int],
        dataEntries: [DataEntry],
        dataLabelAddresses: [String: Int],
        branchMode: BranchExecutionMode = .fixed,
        ioMode: IOExecutionMode = .mapped,
        inputText: String = "",
        maxSteps: Int = 10_000
    ) throws -> CPUExecutionResult {
        reset()
        self.labels = labels
        self.dataLabelAddresses = dataLabelAddresses
        self.branchMode = branchMode
        self.ioMode = ioMode
        self.ioInputBuffer = Array(inputText.utf8)
        loadData(entries: dataEntries, addresses: dataLabelAddresses)

        var halted = false
        var steps = 0
        var cycleSnapshots: [CPUCycleSnapshot] = []

        while pc >= 0 && pc < program.count && steps < maxSteps {
            let instruction = program[pc]
            let oldPC = pc
            let stop = try executeInstruction(instruction)
            steps += 1

            if stop {
                halted = true
            }

            if pc == oldPC {
                pc += 1
            }

            if let target = pendingBranchTarget {
                if pendingBranchDelaySlots > 0 {
                    pendingBranchDelaySlots -= 1
                } else {
                    pc = target
                    pendingBranchTarget = nil
                }
            }

            cycleSnapshots.append(makeCycleSnapshot(cycle: steps, pcBefore: oldPC, pcAfter: pc, instruction: instruction))

            if stop {
                break
            }
        }

        var fullRegisters = registers
        fullRegisters["$pc"] = pc
        fullRegisters["$epc"] = cp0Epc
        fullRegisters["$cause"] = cp0Cause
        fullRegisters["$status"] = cp0Status
        fullRegisters["$badvaddr"] = cp0BadVaddr
        fullRegisters["$hi"] = hi
        fullRegisters["$lo"] = lo

        return CPUExecutionResult(
            steps: steps,
            halted: halted,
            registers: fullRegisters,
            floatingRegisters: floatingRegisters,
            trace: trace,
            cycles: cycleSnapshots,
            ioOutput: ioOutput,
            interruptCount: interruptCount,
            dataMemoryWords: makeDataMemorySnapshot(),
            textRows: makeTextRows(program: program)
        )
    }

    private func reset() {
        registers = [:]
        floatingRegisters = [:]
        memoryBytes = [:]
        pc = 0
        trace = []
        labels = [:]
        dataLabelAddresses = [:]
        hi = 0
        lo = 0
        fpCondition = false
        cp0BadVaddr = 0
        cp0Status = 0
        cp0Cause = 0
        cp0Epc = 0
        heapBreak = 0x10040000
        branchMode = .fixed
        pendingBranchTarget = nil
        pendingBranchDelaySlots = 0

        ioMode = .mapped
        ioOutput = ""
        ioInputBuffer = []
        interruptCount = 0

        for reg in writableRegisters {
            registers[reg] = 0
        }
        for freg in floatingRegisterNames {
            floatingRegisters[freg] = 0
        }

        registers["$sp"] = 0x7fffeffc
    }

    private func loadData(entries: [DataEntry], addresses: [String: Int]) {
        for entry in entries {
            guard let baseAddress = addresses[entry.label] else { continue }

            switch entry.directive {
            case .word:
                for (index, raw) in entry.rawValues.enumerated() {
                    let value = parseImmediateOrZero(raw)
                    writeWord(baseAddress + index * 4, value)
                }

            case .float:
                for (index, raw) in entry.rawValues.enumerated() {
                    let floatValue = Float(raw) ?? 0
                    let bitPattern = Int(Int32(bitPattern: floatValue.bitPattern))
                    writeWord(baseAddress + index * 4, bitPattern)
                }

            case .space:
                let size = max(parseImmediateOrZero(entry.rawValues.first ?? "0"), 0)
                for i in 0..<size {
                    writeByte(baseAddress + i, 0)
                }

            case .ascii, .asciiz:
                let text = decodeString(entry.rawValues.first ?? "")
                let bytes = Array(text.utf8)
                for (index, byte) in bytes.enumerated() {
                    writeByte(baseAddress + index, byte)
                }
                if entry.directive == .asciiz {
                    writeByte(baseAddress + bytes.count, 0)
                }
            }
        }
    }

    private func decodeString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        return decodeEscapedStringLiteral(String(trimmed.dropFirst().dropLast()))
    }

    private func decodeEscapedStringLiteral(_ value: String) -> String {
        var result = ""
        var isEscape = false

        for ch in value {
            if isEscape {
                switch ch {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "0": result.append("\0")
                default: result.append(ch)
                }
                isEscape = false
            } else if ch == "\\" {
                isEscape = true
            } else {
                result.append(ch)
            }
        }

        if isEscape {
            result.append("\\")
        }

        return result
    }

    private func executeInstruction(_ instruction: AssembledInstruction) throws -> Bool {
        let op = instruction.mnemonic
        let args = instruction.operands

        switch op {
        case "li":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("li requiere 2 operandos") }
            let imm = try parseImmediate(args[1])
            try writeRegister(args[0], imm)
            trace.append("L\(instruction.lineNumber): li \(args[0]), \(imm)")

        case "la":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("la requiere 2 operandos") }
            if let address = dataLabelAddresses[args[1]] {
                try writeRegister(args[0], address)
                trace.append("L\(instruction.lineNumber): la \(args[0]), \(args[1]) -> \(address)")
            } else if let target = labels[args[1]] {
                try writeRegister(args[0], target)
                trace.append("L\(instruction.lineNumber): la \(args[0]), \(args[1]) -> \(target)")
            } else {
                throw CPUExecutionError.unknownLabel(args[1])
            }

        case "add":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("add requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let rhs = try readRegister(args[2])
            try writeRegister(args[0], lhs + rhs)
            trace.append("L\(instruction.lineNumber): add -> \(args[0])=\(lhs + rhs)")

        case "addi":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("addi requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let rhs = try parseImmediate(args[2])
            try writeRegister(args[0], lhs + rhs)
            trace.append("L\(instruction.lineNumber): addi -> \(args[0])=\(lhs + rhs)")

        case "sub":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("sub requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let rhs = try readRegister(args[2])
            try writeRegister(args[0], lhs - rhs)
            trace.append("L\(instruction.lineNumber): sub -> \(args[0])=\(lhs - rhs)")

        case "and":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("and requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let rhs = try readRegister(args[2])
            try writeRegister(args[0], lhs & rhs)
            trace.append("L\(instruction.lineNumber): and -> \(args[0])=\(lhs & rhs)")

        case "andi":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("andi requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let imm = try parseImmediate(args[2])
            try writeRegister(args[0], lhs & imm)
            trace.append("L\(instruction.lineNumber): andi -> \(args[0])=\(lhs & imm)")

        case "or":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("or requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let rhs = try readRegister(args[2])
            try writeRegister(args[0], lhs | rhs)
            trace.append("L\(instruction.lineNumber): or -> \(args[0])=\(lhs | rhs)")

        case "xor":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("xor requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let rhs = try readRegister(args[2])
            try writeRegister(args[0], lhs ^ rhs)
            trace.append("L\(instruction.lineNumber): xor -> \(args[0])=\(lhs ^ rhs)")

        case "nor":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("nor requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let rhs = try readRegister(args[2])
            try writeRegister(args[0], ~(lhs | rhs))
            trace.append("L\(instruction.lineNumber): nor -> \(args[0])=\(~(lhs | rhs))")

        case "ori":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("ori requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let imm = try parseImmediate(args[2])
            try writeRegister(args[0], lhs | imm)
            trace.append("L\(instruction.lineNumber): ori -> \(args[0])=\(lhs | imm)")

        case "slt":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("slt requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let rhs = try readRegister(args[2])
            try writeRegister(args[0], lhs < rhs ? 1 : 0)
            trace.append("L\(instruction.lineNumber): slt -> \(args[0])=\(lhs < rhs ? 1 : 0)")

        case "slti":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("slti requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let rhs = try parseImmediate(args[2])
            try writeRegister(args[0], lhs < rhs ? 1 : 0)
            trace.append("L\(instruction.lineNumber): slti -> \(args[0])=\(lhs < rhs ? 1 : 0)")

        case "xori":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("xori requiere 3 operandos") }
            let lhs = try readRegister(args[1])
            let imm = try parseImmediate(args[2])
            try writeRegister(args[0], lhs ^ imm)
            trace.append("L\(instruction.lineNumber): xori -> \(args[0])=\(lhs ^ imm)")

        case "move":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("move requiere 2 operandos") }
            let value = try readRegister(args[1])
            try writeRegister(args[0], value)
            trace.append("L\(instruction.lineNumber): move -> \(args[0])=\(value)")

        case "neg":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("neg requiere 2 operandos") }
            let value = try readRegister(args[1])
            try writeRegister(args[0], -value)
            trace.append("L\(instruction.lineNumber): neg -> \(args[0])=\(-value)")

        case "not":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("not requiere 2 operandos") }
            let value = try readRegister(args[1])
            try writeRegister(args[0], ~value)
            trace.append("L\(instruction.lineNumber): not -> \(args[0])=\(~value)")

        case "lui":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("lui requiere 2 operandos") }
            let imm = try parseImmediate(args[1])
            try writeRegister(args[0], imm << 16)
            trace.append("L\(instruction.lineNumber): lui -> \(args[0])=\(imm << 16)")

        case "lw":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("lw requiere 2 operandos") }
            let (offset, baseReg) = try parseBaseAddress(args[1])
            let base = try readRegister(baseReg)
            let address = base + offset
            let value = mmioReadWord(address)
            try writeRegister(args[0], value)
            trace.append("L\(instruction.lineNumber): lw -> \(args[0])=\(value) from \(address)")

        case "sw":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("sw requiere 2 operandos") }
            let value = try readRegister(args[0])
            let (offset, baseReg) = try parseBaseAddress(args[1])
            let base = try readRegister(baseReg)
            let address = base + offset
            mmioWriteWord(address, value)
            trace.append("L\(instruction.lineNumber): sw -> mem32[\(address)]=\(value)")

        case "lb":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("lb requiere 2 operandos") }
            let (offset, baseReg) = try parseBaseAddress(args[1])
            let base = try readRegister(baseReg)
            let address = base + offset
            let byteValue = Int(mmioReadByte(address))
            let signed = (byteValue & 0x80) != 0 ? (byteValue | ~0xFF) : byteValue
            try writeRegister(args[0], signed)
            trace.append("L\(instruction.lineNumber): lb -> \(args[0])=\(signed) from \(address)")

        case "sb":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("sb requiere 2 operandos") }
            let value = try readRegister(args[0])
            let (offset, baseReg) = try parseBaseAddress(args[1])
            let base = try readRegister(baseReg)
            let address = base + offset
            mmioWriteByte(address, UInt8(truncatingIfNeeded: value))
            trace.append("L\(instruction.lineNumber): sb -> mem8[\(address)]=\(value & 0xFF)")

        case "sll":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("sll requiere 3 operandos") }
            let value = try readRegister(args[1])
            let shamt = try parseImmediate(args[2]) & 0x1F
            try writeRegister(args[0], value << shamt)
            trace.append("L\(instruction.lineNumber): sll -> \(args[0])=\(value << shamt)")

        case "srl":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("srl requiere 3 operandos") }
            let value = try readRegister(args[1])
            let shamt = try parseImmediate(args[2]) & 0x1F
            let logical = Int(UInt32(bitPattern: Int32(truncatingIfNeeded: value)) >> UInt32(shamt))
            try writeRegister(args[0], logical)
            trace.append("L\(instruction.lineNumber): srl -> \(args[0])=\(logical)")

        case "sra":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("sra requiere 3 operandos") }
            let value = try readRegister(args[1])
            let shamt = try parseImmediate(args[2]) & 0x1F
            try writeRegister(args[0], value >> shamt)
            trace.append("L\(instruction.lineNumber): sra -> \(args[0])=\(value >> shamt)")

        case "mult":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("mult requiere 2 operandos") }
            let lhs = Int64(try readRegister(args[0]))
            let rhs = Int64(try readRegister(args[1]))
            let result = lhs * rhs
            lo = Int(Int32(truncatingIfNeeded: result & 0xFFFF_FFFF))
            hi = Int(Int32(truncatingIfNeeded: (result >> 32) & 0xFFFF_FFFF))
            trace.append("L\(instruction.lineNumber): mult -> hi=\(hi), lo=\(lo)")

        case "div":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("div requiere 2 operandos") }
            let lhs = try readRegister(args[0])
            let rhs = try readRegister(args[1])
            guard rhs != 0 else { throw CPUExecutionError.divisionByZero }
            lo = lhs / rhs
            hi = lhs % rhs
            trace.append("L\(instruction.lineNumber): div -> hi=\(hi), lo=\(lo)")

        case "mfhi":
            guard args.count == 1 else { throw CPUExecutionError.unknownInstruction("mfhi requiere 1 operando") }
            try writeRegister(args[0], hi)
            trace.append("L\(instruction.lineNumber): mfhi -> \(args[0])=\(hi)")

        case "mflo":
            guard args.count == 1 else { throw CPUExecutionError.unknownInstruction("mflo requiere 1 operando") }
            try writeRegister(args[0], lo)
            trace.append("L\(instruction.lineNumber): mflo -> \(args[0])=\(lo)")

        case "beq":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("beq requiere 3 operandos") }
            let lhs = try readRegister(args[0])
            let rhs = try readRegister(args[1])
            if lhs == rhs {
                let target = try resolveBranchTarget(args[2], currentPC: pc)
                applyControlTransfer(target: target)
                trace.append("L\(instruction.lineNumber): beq tomado -> objetivo=\(target) modo=\(branchMode == .delayed ? "retardado" : "fijo")")
            } else {
                trace.append("L\(instruction.lineNumber): beq no tomado")
            }

        case "bne":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("bne requiere 3 operandos") }
            let lhs = try readRegister(args[0])
            let rhs = try readRegister(args[1])
            if lhs != rhs {
                let target = try resolveBranchTarget(args[2], currentPC: pc)
                applyControlTransfer(target: target)
                trace.append("L\(instruction.lineNumber): bne tomado -> objetivo=\(target) modo=\(branchMode == .delayed ? "retardado" : "fijo")")
            } else {
                trace.append("L\(instruction.lineNumber): bne no tomado")
            }

        case "bgt":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("bgt requiere 3 operandos") }
            let lhs = try readRegister(args[0])
            let rhs = try readRegister(args[1])
            if lhs > rhs {
                let target = try resolveBranchTarget(args[2], currentPC: pc)
                applyControlTransfer(target: target)
                trace.append("L\(instruction.lineNumber): bgt tomado -> objetivo=\(target)")
            } else {
                trace.append("L\(instruction.lineNumber): bgt no tomado")
            }

        case "blt":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("blt requiere 3 operandos") }
            let lhs = try readRegister(args[0])
            let rhs = try readRegister(args[1])
            if lhs < rhs {
                let target = try resolveBranchTarget(args[2], currentPC: pc)
                applyControlTransfer(target: target)
                trace.append("L\(instruction.lineNumber): blt tomado -> objetivo=\(target)")
            } else {
                trace.append("L\(instruction.lineNumber): blt no tomado")
            }

        case "bge":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("bge requiere 3 operandos") }
            let lhs = try readRegister(args[0])
            let rhs = try readRegister(args[1])
            if lhs >= rhs {
                let target = try resolveBranchTarget(args[2], currentPC: pc)
                applyControlTransfer(target: target)
                trace.append("L\(instruction.lineNumber): bge tomado -> objetivo=\(target)")
            } else {
                trace.append("L\(instruction.lineNumber): bge no tomado")
            }

        case "ble":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("ble requiere 3 operandos") }
            let lhs = try readRegister(args[0])
            let rhs = try readRegister(args[1])
            if lhs <= rhs {
                let target = try resolveBranchTarget(args[2], currentPC: pc)
                applyControlTransfer(target: target)
                trace.append("L\(instruction.lineNumber): ble tomado -> objetivo=\(target)")
            } else {
                trace.append("L\(instruction.lineNumber): ble no tomado")
            }

        case "j":
            guard args.count == 1 else { throw CPUExecutionError.unknownInstruction("j requiere 1 operando") }
            let target = try resolveJumpTarget(args[0])
            applyControlTransfer(target: target)
            trace.append("L\(instruction.lineNumber): j -> objetivo=\(target) modo=\(branchMode == .delayed ? "retardado" : "fijo")")

        case "jal":
            guard args.count == 1 else { throw CPUExecutionError.unknownInstruction("jal requiere 1 operando") }
            try writeRegister("$ra", pc + 1)
            let target = try resolveJumpTarget(args[0])
            applyControlTransfer(target: target)
            trace.append("L\(instruction.lineNumber): jal -> objetivo=\(target), $ra=\(registers["$ra"] ?? 0), modo=\(branchMode == .delayed ? "retardado" : "fijo")")

        case "jr":
            guard args.count == 1 else { throw CPUExecutionError.unknownInstruction("jr requiere 1 operando") }
            let target = try readRegister(args[0])
            applyControlTransfer(target: target)
            trace.append("L\(instruction.lineNumber): jr -> objetivo=\(target) modo=\(branchMode == .delayed ? "retardado" : "fijo")")

        case "lwc1":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("lwc1 requiere 2 operandos") }
            let (offset, baseReg) = try parseBaseAddress(args[1])
            let base = try readRegister(baseReg)
            let address = base + offset
            let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: readWord(address)))
            try writeFloatingRegisterBits(args[0], raw)
            trace.append("L\(instruction.lineNumber): lwc1 -> \(args[0])=0x\(String(raw, radix: 16))")

        case "swc1":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("swc1 requiere 2 operandos") }
            let raw = try readFloatingRegisterBits(args[0])
            let (offset, baseReg) = try parseBaseAddress(args[1])
            let base = try readRegister(baseReg)
            let address = base + offset
            writeWord(address, Int(Int32(bitPattern: raw)))
            trace.append("L\(instruction.lineNumber): swc1 -> mem32[\(address)]=0x\(String(raw, radix: 16))")

        case "mfc0":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("mfc0 requiere 2 operandos") }
            let value = readCop0Register(args[1])
            try writeRegister(args[0], value)
            trace.append("L\(instruction.lineNumber): mfc0 \(args[1]) -> \(args[0])=\(value)")

        case "mfc1":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("mfc1 requiere 2 operandos") }
            let raw = try readFloatingRegisterBits(args[1])
            try writeRegister(args[0], Int(Int32(bitPattern: raw)))
            trace.append("L\(instruction.lineNumber): mfc1 -> \(args[0])=0x\(String(raw, radix: 16))")

        case "mtc1":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("mtc1 requiere 2 operandos") }
            let intValue = try readRegister(args[0])
            let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: intValue))
            try writeFloatingRegisterBits(args[1], raw)
            trace.append("L\(instruction.lineNumber): mtc1 -> \(args[1])=0x\(String(raw, radix: 16))")

        case "movs", "movd":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("mov requiere 2 operandos") }
            let raw = try readFloatingRegisterBits(args[1])
            try writeFloatingRegisterBits(args[0], raw)
            trace.append("L\(instruction.lineNumber): \(op) -> \(args[0])")

        case "adds", "addd":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("adds requiere 3 operandos") }
            let lhs = try readFloatingRegister(args[1])
            let rhs = try readFloatingRegister(args[2])
            let result = lhs + rhs
            try writeFloatingRegister(args[0], result)
            trace.append("L\(instruction.lineNumber): adds -> \(args[0])=\(result)")

        case "subs", "subd":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("sub requiere 3 operandos") }
            let lhs = try readFloatingRegister(args[1])
            let rhs = try readFloatingRegister(args[2])
            let result = lhs - rhs
            try writeFloatingRegister(args[0], result)
            trace.append("L\(instruction.lineNumber): \(op) -> \(args[0])=\(result)")

        case "muls", "muld":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("mul requiere 3 operandos") }
            let lhs = try readFloatingRegister(args[1])
            let rhs = try readFloatingRegister(args[2])
            let result = lhs * rhs
            try writeFloatingRegister(args[0], result)
            trace.append("L\(instruction.lineNumber): \(op) -> \(args[0])=\(result)")

        case "divs", "divd":
            guard args.count == 3 else { throw CPUExecutionError.unknownInstruction("div requiere 3 operandos") }
            let lhs = try readFloatingRegister(args[1])
            let rhs = try readFloatingRegister(args[2])
            let result = lhs / rhs
            try writeFloatingRegister(args[0], result)
            trace.append("L\(instruction.lineNumber): \(op) -> \(args[0])=\(result)")

        case "abss", "absd":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("abs requiere 2 operandos") }
            let value = try readFloatingRegister(args[1])
            try writeFloatingRegister(args[0], abs(value))
            trace.append("L\(instruction.lineNumber): \(op) -> \(args[0])")

        case "negs", "negd":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("neg requiere 2 operandos") }
            let value = try readFloatingRegister(args[1])
            try writeFloatingRegister(args[0], -value)
            trace.append("L\(instruction.lineNumber): \(op) -> \(args[0])")

        case "ceqs", "ceqd":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("ceqs requiere 2 operandos") }
            let lhs = try readFloatingRegister(args[0])
            let rhs = try readFloatingRegister(args[1])
            fpCondition = lhs == rhs
            trace.append("L\(instruction.lineNumber): ceqs -> cond=\(fpCondition)")

        case "clts", "cltd":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("clt requiere 2 operandos") }
            let lhs = try readFloatingRegister(args[0])
            let rhs = try readFloatingRegister(args[1])
            fpCondition = lhs < rhs
            trace.append("L\(instruction.lineNumber): \(op) -> cond=\(fpCondition)")

        case "cles", "cled":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("cle requiere 2 operandos") }
            let lhs = try readFloatingRegister(args[0])
            let rhs = try readFloatingRegister(args[1])
            fpCondition = lhs <= rhs
            trace.append("L\(instruction.lineNumber): \(op) -> cond=\(fpCondition)")

        case "cvtws", "cvtwd":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("cvtw requiere 2 operandos") }
            let value = try readFloatingRegister(args[1])
            let intValue = Int32(value.rounded(.towardZero))
            try writeFloatingRegisterBits(args[0], UInt32(bitPattern: intValue))
            trace.append("L\(instruction.lineNumber): \(op) -> \(args[0])")

        case "cvtsw", "cvtdw":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("cvts/d.w requiere 2 operandos") }
            let raw = try readFloatingRegisterBits(args[1])
            let intValue = Int32(bitPattern: raw)
            try writeFloatingRegister(args[0], Float(intValue))
            trace.append("L\(instruction.lineNumber): \(op) -> \(args[0])")

        case "cvtsd", "cvtds":
            guard args.count == 2 else { throw CPUExecutionError.unknownInstruction("cvt s/d requiere 2 operandos") }
            let value = try readFloatingRegister(args[1])
            try writeFloatingRegister(args[0], value)
            trace.append("L\(instruction.lineNumber): \(op) -> \(args[0])")

        case "bc1t":
            guard args.count == 1 else { throw CPUExecutionError.unknownInstruction("bc1t requiere 1 operando") }
            if fpCondition {
                let target = try resolveBranchTarget(args[0], currentPC: pc)
                applyControlTransfer(target: target)
                trace.append("L\(instruction.lineNumber): bc1t tomado -> objetivo=\(target) modo=\(branchMode == .delayed ? "retardado" : "fijo")")
            } else {
                trace.append("L\(instruction.lineNumber): bc1t no tomado")
            }

        case "bc1f":
            guard args.count == 1 else { throw CPUExecutionError.unknownInstruction("bc1f requiere 1 operando") }
            if !fpCondition {
                let target = try resolveBranchTarget(args[0], currentPC: pc)
                applyControlTransfer(target: target)
                trace.append("L\(instruction.lineNumber): bc1f tomado -> objetivo=\(target) modo=\(branchMode == .delayed ? "retardado" : "fijo")")
            } else {
                trace.append("L\(instruction.lineNumber): bc1f no tomado")
            }

        case "rfe":
            // Restore previous execution mode bits (compatible with Java behavior).
            let bit3 = (cp0Status >> 3) & 1
            let bit2 = (cp0Status >> 2) & 1
            let bit4 = (cp0Status >> 4) & 1
            let bit5 = (cp0Status >> 5) & 1
            cp0Status = setBit(cp0Status, 1, to: bit3)
            cp0Status = setBit(cp0Status, 0, to: bit2)
            cp0Status = setBit(cp0Status, 3, to: bit4)
            cp0Status = setBit(cp0Status, 2, to: bit5)
            trace.append("L\(instruction.lineNumber): rfe -> status=0x\(String(cp0Status, radix: 16))")

        case "nop":
            trace.append("L\(instruction.lineNumber): nop")

        case "syscall":
            let code = registers["$v0"] ?? 0
            switch code {
            case 1:
                ioOutput += "\(registers["$a0"] ?? 0)"
                trace.append("L\(instruction.lineNumber): syscall print_int")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            case 2:
                let value = try readFloatingRegister("$f12")
                ioOutput += "\(value)"
                trace.append("L\(instruction.lineNumber): syscall print_float")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            case 3:
                let value = try readDoubleFromPair(high: "$f12", low: "$f13")
                ioOutput += "\(value)"
                trace.append("L\(instruction.lineNumber): syscall print_double")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            case 4:
                let start = registers["$a0"] ?? 0
                let text = readCString(from: start)
                ioOutput += text
                trace.append("L\(instruction.lineNumber): syscall print_string")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            case 5:
                let intValue = readNextIntFromInput()
                try writeRegister("$v0", intValue)
                trace.append("L\(instruction.lineNumber): syscall read_int -> $v0=\(intValue)")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            case 6:
                let floatValue = readNextFloatFromInput()
                try writeFloatingRegister("$f0", floatValue)
                trace.append("L\(instruction.lineNumber): syscall read_float -> $f0=\(floatValue)")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            case 7:
                let doubleValue = readNextDoubleFromInput()
                try writeDoubleToPair(doubleValue, high: "$f0", low: "$f1")
                trace.append("L\(instruction.lineNumber): syscall read_double -> $f0/$f1=\(doubleValue)")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            case 8:
                let address = registers["$a0"] ?? 0
                let capacity = max(registers["$a1"] ?? 0, 0)
                let text = readNextStringFromInput(maxLength: capacity)
                writeCString(text, to: address, maxLength: capacity)
                try writeRegister("$a1", text.count)
                trace.append("L\(instruction.lineNumber): syscall read_string -> len=\(text.count)")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            case 9:
                let size = max(registers["$a0"] ?? 0, 0)
                let address = heapBreak
                heapBreak += size
                try writeRegister("$v0", address)
                trace.append("L\(instruction.lineNumber): syscall sbrk -> $v0=\(address), size=\(size)")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            case 10:
                trace.append("L\(instruction.lineNumber): syscall exit -> halt")
                return true
            case 11:
                let byte = UInt8(truncatingIfNeeded: registers["$a0"] ?? 0)
                ioOutput.append(Character(UnicodeScalar(byte)))
                trace.append("L\(instruction.lineNumber): syscall print_char")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            case 12:
                let byte = ioInputBuffer.isEmpty ? 0 : ioInputBuffer.removeFirst()
                try writeRegister("$v0", Int(byte))
                trace.append("L\(instruction.lineNumber): syscall read_char -> $v0=\(byte)")
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return false
            default:
                trace.append("L\(instruction.lineNumber): syscall code=\(code) -> halt")
                return true
            }

        default:
            throw CPUExecutionError.unknownInstruction(op)
        }

        return false
    }

    private func resolveBranchTarget(_ raw: String, currentPC: Int) throws -> Int {
        if let immediate = tryParseImmediate(raw) {
            return currentPC + 1 + immediate
        }

        if let target = labels[raw] {
            return target
        }

        throw CPUExecutionError.unknownLabel(raw)
    }

    private func applyControlTransfer(target: Int) {
        switch branchMode {
        case .fixed:
            pc = target
        case .delayed:
            pendingBranchTarget = target
            pendingBranchDelaySlots = 1
        }
    }

    private func resolveJumpTarget(_ raw: String) throws -> Int {
        if let target = labels[raw] {
            return target
        }

        if let immediate = tryParseImmediate(raw) {
            return immediate
        }

        throw CPUExecutionError.unknownLabel(raw)
    }

    private func parseBaseAddress(_ raw: String) throws -> (Int, String) {
        guard let leftParen = raw.firstIndex(of: "("), let rightParen = raw.firstIndex(of: ")"), rightParen > leftParen else {
            throw CPUExecutionError.invalidAddress(raw)
        }

        let offsetString = String(raw[..<leftParen]).trimmingCharacters(in: .whitespaces)
        let base = String(raw[raw.index(after: leftParen)..<rightParen]).trimmingCharacters(in: .whitespaces)

        guard !base.isEmpty else {
            throw CPUExecutionError.invalidAddress(raw)
        }

        let offset = offsetString.isEmpty ? 0 : try parseImmediate(offsetString)
        return (offset, base)
    }

    private func tryParseImmediate(_ raw: String) -> Int? {
        if let intValue = Int(raw) {
            return intValue
        }

        if raw.lowercased().hasPrefix("0x"), let hex = Int(raw.dropFirst(2), radix: 16) {
            return hex
        }

        return nil
    }

    private func parseImmediate(_ raw: String) throws -> Int {
        guard let value = tryParseImmediate(raw) else {
            throw CPUExecutionError.invalidImmediate(raw)
        }
        return value
    }

    private func parseImmediateOrZero(_ raw: String) -> Int {
        tryParseImmediate(raw) ?? 0
    }

    private func readRegister(_ name: String) throws -> Int {
        let normalized = normalizeGeneralRegisterName(name)
        guard readableRegisters.contains(normalized) else {
            throw CPUExecutionError.invalidRegister(name)
        }

        if normalized == "$zero" {
            return 0
        }

        return registers[normalized] ?? 0
    }

    private func writeRegister(_ name: String, _ value: Int) throws {
        let normalized = normalizeGeneralRegisterName(name)
        guard normalized != "$zero" else {
            return
        }

        guard writableRegisters.contains(normalized) else {
            throw CPUExecutionError.invalidRegister(name)
        }

        registers[normalized] = value
    }

    private func normalizeGeneralRegisterName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "$0" {
            return "$zero"
        }
        return trimmed
    }

    private func readFloatingRegisterBits(_ name: String) throws -> UInt32 {
        guard floatingRegisterNames.contains(name) else {
            throw CPUExecutionError.invalidFloatRegister(name)
        }
        return floatingRegisters[name] ?? 0
    }

    private func writeFloatingRegisterBits(_ name: String, _ value: UInt32) throws {
        guard floatingRegisterNames.contains(name) else {
            throw CPUExecutionError.invalidFloatRegister(name)
        }
        floatingRegisters[name] = value
    }

    private func readFloatingRegister(_ name: String) throws -> Float {
        let bits = try readFloatingRegisterBits(name)
        return Float(bitPattern: bits)
    }

    private func writeFloatingRegister(_ name: String, _ value: Float) throws {
        try writeFloatingRegisterBits(name, value.bitPattern)
    }

    private func readDoubleFromPair(high: String, low: String) throws -> Double {
        let hiBits = UInt64(try readFloatingRegisterBits(high))
        let loBits = UInt64(try readFloatingRegisterBits(low))
        let bits = (hiBits << 32) | loBits
        return Double(bitPattern: bits)
    }

    private func writeDoubleToPair(_ value: Double, high: String, low: String) throws {
        let bits = value.bitPattern
        let hiBits = UInt32((bits >> 32) & 0xFFFF_FFFF)
        let loBits = UInt32(bits & 0xFFFF_FFFF)
        try writeFloatingRegisterBits(high, hiBits)
        try writeFloatingRegisterBits(low, loBits)
    }

    private func readCString(from address: Int, maxBytes: Int = 4096) -> String {
        var bytes: [UInt8] = []
        var addr = address
        var guardCount = 0

        while guardCount < maxBytes {
            let byte = readByte(addr)
            if byte == 0 {
                break
            }
            bytes.append(byte)
            addr += 1
            guardCount += 1
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private func writeCString(_ text: String, to address: Int, maxLength: Int) {
        let bytes = Array(text.utf8)
        let allowed = maxLength > 0 ? max(maxLength - 1, 0) : bytes.count
        let count = min(bytes.count, allowed)

        for i in 0..<count {
            writeByte(address + i, bytes[i])
        }
        writeByte(address + count, 0)
    }

    private func readCop0Register(_ raw: String) -> Int {
        switch parseCop0RegisterIndex(raw) {
        case 8:
            return cp0BadVaddr
        case 12:
            return cp0Status
        case 13:
            return cp0Cause
        case 14:
            return cp0Epc
        default:
            return 0
        }
    }

    private func parseCop0RegisterIndex(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "$status" { return 12 }
        if trimmed == "$cause" { return 13 }
        if trimmed == "$epc" { return 14 }
        if trimmed == "$badvaddr" { return 8 }

        if trimmed.hasPrefix("$") {
            return Int(trimmed.dropFirst())
        }
        return Int(trimmed)
    }

    private func setBit(_ value: Int, _ index: Int, to bit: Int) -> Int {
        if bit == 0 {
            return value & ~(1 << index)
        }
        return value | (1 << index)
    }

    private func makeCycleSnapshot(
        cycle: Int,
        pcBefore: Int,
        pcAfter: Int,
        instruction: AssembledInstruction
    ) -> CPUCycleSnapshot {
        CPUCycleSnapshot(
            cycle: cycle,
            pcBefore: pcBefore,
            pcAfter: pcAfter,
            instruction: "\(instruction.mnemonic) \(instruction.operands.joined(separator: ", "))".trimmingCharacters(in: .whitespaces),
            t0: registers["$t0"] ?? 0,
            t1: registers["$t1"] ?? 0,
            t2: registers["$t2"] ?? 0,
            s0: registers["$s0"] ?? 0,
            s1: registers["$s1"] ?? 0,
            hi: hi,
            lo: lo
        )
    }

    private func makeDataMemorySnapshot() -> [MemoryWord] {
        let base = 0x10010000
        let wordCount = 32
        return (0..<wordCount).map { index in
            let address = base + (index * 4)
            return MemoryWord(address: address, value: readWord(address))
        }
    }

    private func makeTextRows(program: [AssembledInstruction]) -> [TextRow] {
        let base = 0x00400000
        return program.enumerated().map { index, instruction in
            let address = base + (index * 4)
            let text = "\(instruction.mnemonic) \(instruction.operands.joined(separator: ", "))".trimmingCharacters(in: .whitespaces)
            let encoded = encodeMachineCode(instruction: instruction, atIndex: index)
            return TextRow(address: address, machineCode: encoded, instruction: text)
        }
    }

    private func encodeMachineCode(instruction: AssembledInstruction, atIndex index: Int) -> Int {
        let op = instruction.mnemonic
        let args = instruction.operands

        func reg(_ raw: String) -> Int? {
            let key = normalizeGeneralRegisterName(raw)
            let table: [String: Int] = [
                "$zero": 0, "$at": 1, "$v0": 2, "$v1": 3,
                "$a0": 4, "$a1": 5, "$a2": 6, "$a3": 7,
                "$t0": 8, "$t1": 9, "$t2": 10, "$t3": 11, "$t4": 12, "$t5": 13, "$t6": 14, "$t7": 15,
                "$s0": 16, "$s1": 17, "$s2": 18, "$s3": 19, "$s4": 20, "$s5": 21, "$s6": 22, "$s7": 23,
                "$t8": 24, "$t9": 25, "$k0": 26, "$k1": 27, "$gp": 28, "$sp": 29, "$fp": 30, "$ra": 31
            ]
            return table[key]
        }

        func imm16(_ raw: String) -> Int {
            Int(UInt16(bitPattern: Int16(truncatingIfNeeded: parseImmediateOrZero(raw))))
        }

        func rType(rs: Int, rt: Int, rd: Int, shamt: Int, funct: Int) -> Int {
            ((rs & 0x1F) << 21) | ((rt & 0x1F) << 16) | ((rd & 0x1F) << 11) | ((shamt & 0x1F) << 6) | (funct & 0x3F)
        }

        func iType(opcode: Int, rs: Int, rt: Int, imm: Int) -> Int {
            ((opcode & 0x3F) << 26) | ((rs & 0x1F) << 21) | ((rt & 0x1F) << 16) | (imm & 0xFFFF)
        }

        func jType(opcode: Int, target: Int) -> Int {
            ((opcode & 0x3F) << 26) | (target & 0x03FF_FFFF)
        }

        func parseBase(_ raw: String) -> (offset: Int, base: Int)? {
            guard let open = raw.firstIndex(of: "("), let close = raw.firstIndex(of: ")"), open < close else { return nil }
            let offsetRaw = String(raw[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            let baseRaw = String(raw[raw.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let base = reg(baseRaw) else { return nil }
            return (imm16(offsetRaw.isEmpty ? "0" : offsetRaw), base)
        }

        func branchOffset(_ label: String) -> Int {
            if let target = labels[label] {
                return Int(UInt16(bitPattern: Int16(truncatingIfNeeded: target - (index + 1))))
            }
            return imm16(label)
        }

        func jumpTarget(_ label: String) -> Int {
            if let target = labels[label] {
                return target & 0x03FF_FFFF
            }
            return (parseImmediateOrZero(label) >> 2) & 0x03FF_FFFF
        }

        switch op {
        case "syscall":
            return 0x0000000C
        case "nop":
            return 0
        case "add":
            guard args.count == 3, let rd = reg(args[0]), let rs = reg(args[1]), let rt = reg(args[2]) else { return 0 }
            return rType(rs: rs, rt: rt, rd: rd, shamt: 0, funct: 0x20)
        case "sub":
            guard args.count == 3, let rd = reg(args[0]), let rs = reg(args[1]), let rt = reg(args[2]) else { return 0 }
            return rType(rs: rs, rt: rt, rd: rd, shamt: 0, funct: 0x22)
        case "and":
            guard args.count == 3, let rd = reg(args[0]), let rs = reg(args[1]), let rt = reg(args[2]) else { return 0 }
            return rType(rs: rs, rt: rt, rd: rd, shamt: 0, funct: 0x24)
        case "or":
            guard args.count == 3, let rd = reg(args[0]), let rs = reg(args[1]), let rt = reg(args[2]) else { return 0 }
            return rType(rs: rs, rt: rt, rd: rd, shamt: 0, funct: 0x25)
        case "xor":
            guard args.count == 3, let rd = reg(args[0]), let rs = reg(args[1]), let rt = reg(args[2]) else { return 0 }
            return rType(rs: rs, rt: rt, rd: rd, shamt: 0, funct: 0x26)
        case "nor":
            guard args.count == 3, let rd = reg(args[0]), let rs = reg(args[1]), let rt = reg(args[2]) else { return 0 }
            return rType(rs: rs, rt: rt, rd: rd, shamt: 0, funct: 0x27)
        case "slt":
            guard args.count == 3, let rd = reg(args[0]), let rs = reg(args[1]), let rt = reg(args[2]) else { return 0 }
            return rType(rs: rs, rt: rt, rd: rd, shamt: 0, funct: 0x2A)
        case "sll":
            guard args.count == 3, let rd = reg(args[0]), let rt = reg(args[1]) else { return 0 }
            return rType(rs: 0, rt: rt, rd: rd, shamt: parseImmediateOrZero(args[2]), funct: 0x00)
        case "srl":
            guard args.count == 3, let rd = reg(args[0]), let rt = reg(args[1]) else { return 0 }
            return rType(rs: 0, rt: rt, rd: rd, shamt: parseImmediateOrZero(args[2]), funct: 0x02)
        case "sra":
            guard args.count == 3, let rd = reg(args[0]), let rt = reg(args[1]) else { return 0 }
            return rType(rs: 0, rt: rt, rd: rd, shamt: parseImmediateOrZero(args[2]), funct: 0x03)
        case "jr":
            guard args.count == 1, let rs = reg(args[0]) else { return 0 }
            return rType(rs: rs, rt: 0, rd: 0, shamt: 0, funct: 0x08)
        case "mult":
            guard args.count == 2, let rs = reg(args[0]), let rt = reg(args[1]) else { return 0 }
            return rType(rs: rs, rt: rt, rd: 0, shamt: 0, funct: 0x18)
        case "div":
            guard args.count == 2, let rs = reg(args[0]), let rt = reg(args[1]) else { return 0 }
            return rType(rs: rs, rt: rt, rd: 0, shamt: 0, funct: 0x1A)
        case "mfhi":
            guard args.count == 1, let rd = reg(args[0]) else { return 0 }
            return rType(rs: 0, rt: 0, rd: rd, shamt: 0, funct: 0x10)
        case "mflo":
            guard args.count == 1, let rd = reg(args[0]) else { return 0 }
            return rType(rs: 0, rt: 0, rd: rd, shamt: 0, funct: 0x12)
        case "addi":
            guard args.count == 3, let rt = reg(args[0]), let rs = reg(args[1]) else { return 0 }
            return iType(opcode: 0x08, rs: rs, rt: rt, imm: imm16(args[2]))
        case "andi":
            guard args.count == 3, let rt = reg(args[0]), let rs = reg(args[1]) else { return 0 }
            return iType(opcode: 0x0C, rs: rs, rt: rt, imm: imm16(args[2]))
        case "ori":
            guard args.count == 3, let rt = reg(args[0]), let rs = reg(args[1]) else { return 0 }
            return iType(opcode: 0x0D, rs: rs, rt: rt, imm: imm16(args[2]))
        case "xori":
            guard args.count == 3, let rt = reg(args[0]), let rs = reg(args[1]) else { return 0 }
            return iType(opcode: 0x0E, rs: rs, rt: rt, imm: imm16(args[2]))
        case "slti":
            guard args.count == 3, let rt = reg(args[0]), let rs = reg(args[1]) else { return 0 }
            return iType(opcode: 0x0A, rs: rs, rt: rt, imm: imm16(args[2]))
        case "lui":
            guard args.count == 2, let rt = reg(args[0]) else { return 0 }
            return iType(opcode: 0x0F, rs: 0, rt: rt, imm: imm16(args[1]))
        case "lw":
            guard args.count == 2, let rt = reg(args[0]), let base = parseBase(args[1]) else { return 0 }
            return iType(opcode: 0x23, rs: base.base, rt: rt, imm: base.offset)
        case "sw":
            guard args.count == 2, let rt = reg(args[0]), let base = parseBase(args[1]) else { return 0 }
            return iType(opcode: 0x2B, rs: base.base, rt: rt, imm: base.offset)
        case "lb":
            guard args.count == 2, let rt = reg(args[0]), let base = parseBase(args[1]) else { return 0 }
            return iType(opcode: 0x20, rs: base.base, rt: rt, imm: base.offset)
        case "sb":
            guard args.count == 2, let rt = reg(args[0]), let base = parseBase(args[1]) else { return 0 }
            return iType(opcode: 0x28, rs: base.base, rt: rt, imm: base.offset)
        case "beq":
            guard args.count == 3, let rs = reg(args[0]), let rt = reg(args[1]) else { return 0 }
            return iType(opcode: 0x04, rs: rs, rt: rt, imm: branchOffset(args[2]))
        case "bne":
            guard args.count == 3, let rs = reg(args[0]), let rt = reg(args[1]) else { return 0 }
            return iType(opcode: 0x05, rs: rs, rt: rt, imm: branchOffset(args[2]))
        case "j":
            guard args.count == 1 else { return 0 }
            return jType(opcode: 0x02, target: jumpTarget(args[0]))
        case "jal":
            guard args.count == 1 else { return 0 }
            return jType(opcode: 0x03, target: jumpTarget(args[0]))
        case "move":
            guard args.count == 2, let rd = reg(args[0]), let rs = reg(args[1]) else { return 0 }
            return rType(rs: rs, rt: 0, rd: rd, shamt: 0, funct: 0x21)
        case "li":
            guard args.count == 2, let rt = reg(args[0]) else { return 0 }
            return iType(opcode: 0x08, rs: 0, rt: rt, imm: imm16(args[1]))
        case "la":
            guard args.count == 2, let rt = reg(args[0]) else { return 0 }
            let address = dataLabelAddresses[args[1]] ?? labels[args[1]] ?? parseImmediateOrZero(args[1])
            return iType(opcode: 0x0D, rs: 0, rt: rt, imm: Int(UInt16(bitPattern: Int16(truncatingIfNeeded: address))))
        default:
            return 0
        }
    }

    private func readNextIntFromInput() -> Int {
        guard let token = readNextTokenFromInput() else {
            return 0
        }
        return Int(token) ?? 0
    }

    private func readNextFloatFromInput() -> Float {
        guard let token = readNextTokenFromInput() else {
            return 0
        }
        return Float(token) ?? 0
    }

    private func readNextDoubleFromInput() -> Double {
        guard let token = readNextTokenFromInput() else {
            return 0
        }
        return Double(token) ?? 0
    }

    private func readNextStringFromInput(maxLength: Int) -> String {
        if ioInputBuffer.isEmpty {
            return ""
        }

        var text = String(decoding: ioInputBuffer, as: UTF8.self)
        let consumedLine: String

        if let newline = text.firstIndex(of: "\n") {
            consumedLine = String(text[..<newline])
            text = String(text[text.index(after: newline)...])
        } else {
            consumedLine = text
            text = ""
        }

        ioInputBuffer = Array(text.utf8)

        let limit = maxLength > 0 ? max(maxLength - 1, 0) : consumedLine.count
        return String(consumedLine.prefix(limit))
    }

    private func readNextTokenFromInput() -> String? {
        if ioInputBuffer.isEmpty {
            return nil
        }

        let text = String(decoding: ioInputBuffer, as: UTF8.self)
        let separators: (Character) -> Bool = { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "," }
        let trimmed = text.drop(while: separators)

        guard !trimmed.isEmpty else {
            ioInputBuffer = []
            return nil
        }

        let token = String(trimmed.prefix(while: { !separators($0) }))
        let remaining = trimmed.dropFirst(token.count).drop(while: separators)
        ioInputBuffer = Array(String(remaining).utf8)
        return token
    }

    private func mmioReadWord(_ address: Int) -> Int {
        if address == mmioKeyboardDataAddress {
            switch ioMode {
            case .disabled:
                return 0
            case .mapped, .interrupts:
                let byte = ioInputBuffer.isEmpty ? 0 : ioInputBuffer.removeFirst()
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return Int(byte)
            }
        }
        return readWord(address)
    }

    private func mmioWriteWord(_ address: Int, _ value: Int) {
        if address == mmioDisplayDataAddress {
            switch ioMode {
            case .disabled:
                return
            case .mapped, .interrupts:
                let ch = Character(UnicodeScalar(UInt8(truncatingIfNeeded: value)))
                ioOutput.append(ch)
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return
            }
        }
        writeWord(address, value)
    }

    private func mmioReadByte(_ address: Int) -> UInt8 {
        if address == mmioKeyboardDataAddress {
            switch ioMode {
            case .disabled:
                return 0
            case .mapped, .interrupts:
                let byte = ioInputBuffer.isEmpty ? 0 : ioInputBuffer.removeFirst()
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return byte
            }
        }
        return readByte(address)
    }

    private func mmioWriteByte(_ address: Int, _ value: UInt8) {
        if address == mmioDisplayDataAddress {
            switch ioMode {
            case .disabled:
                return
            case .mapped, .interrupts:
                let ch = Character(UnicodeScalar(value))
                ioOutput.append(ch)
                if ioMode == .interrupts {
                    interruptCount += 1
                }
                return
            }
        }
        writeByte(address, value)
    }

    private func readByte(_ address: Int) -> UInt8 {
        memoryBytes[address] ?? 0
    }

    private func writeByte(_ address: Int, _ value: UInt8) {
        memoryBytes[address] = value
    }

    private func readWord(_ address: Int) -> Int {
        let b0 = UInt32(readByte(address))
        let b1 = UInt32(readByte(address + 1))
        let b2 = UInt32(readByte(address + 2))
        let b3 = UInt32(readByte(address + 3))

        let raw = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        return Int(Int32(bitPattern: raw))
    }

    private func writeWord(_ address: Int, _ value: Int) {
        let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        writeByte(address, UInt8((raw >> 24) & 0xFF))
        writeByte(address + 1, UInt8((raw >> 16) & 0xFF))
        writeByte(address + 2, UInt8((raw >> 8) & 0xFF))
        writeByte(address + 3, UInt8(raw & 0xFF))
    }
}
