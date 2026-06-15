import Foundation

struct AssemblyResult {
    let instructions: [AssembledInstruction]
    let dataEntries: [DataEntry]
    let labels: [String: Int]
    let dataLabelAddresses: [String: Int]
    let routineInstructions: [AssembledInstruction]
}

struct AssembledInstruction: Identifiable {
    let id = UUID()
    let lineNumber: Int
    let mnemonic: String
    let operands: [String]
    let isRoutine: Bool
}

struct DataEntry {
    let lineNumber: Int
    let label: String
    let directive: DataDirective
    let rawValues: [String]
}

enum DataDirective: String {
    case word = ".word"
    case space = ".space"
    case ascii = ".ascii"
    case asciiz = ".asciiz"
    case float = ".float"
}

struct AssemblyIssue: Identifiable {
    let id = UUID()
    let lineNumber: Int
    let message: String
    let source: String
}

enum AssemblyError: Error {
    case issues([AssemblyIssue])
}

final class AssemblerEngine {
    private let supportedMnemonics: Set<String> = [
        "add", "addi", "sub", "and", "andi", "or", "ori", "slt", "slti",
        "xor", "xori", "nor",
        "move", "neg", "not",
        "li", "la", "lui", "lw", "sw", "lb", "sb", "lwc1", "swc1",
        "beq", "bne", "bgt", "blt", "bge", "ble", "j", "jal", "jr", "nop", "syscall",
        "mult", "div", "mfhi", "mflo", "sll", "srl", "sra",
        "mfc0", "mfc1", "mtc1", "movs", "movd",
        "adds", "subs", "muls", "divs",
        "addd", "subd", "muld", "divd",
        "abss", "absd", "negs", "negd",
        "ceqs", "clts", "cles", "ceqd", "cltd", "cled",
        "cvtws", "cvtsw", "cvtwd", "cvtdw", "cvtsd", "cvtds",
        "bc1t", "bc1f", "rfe"
    ]

    private let operandCountByMnemonic: [String: Int] = [
        "add": 3, "addi": 3, "sub": 3,
        "and": 3, "andi": 3, "or": 3, "ori": 3,
        "xor": 3, "xori": 3, "nor": 3,
        "slt": 3, "slti": 3,
        "move": 2, "neg": 2, "not": 2,
        "li": 2, "la": 2, "lui": 2,
        "lw": 2, "sw": 2, "lb": 2, "sb": 2,
        "lwc1": 2, "swc1": 2,
        "beq": 3, "bne": 3, "bgt": 3, "blt": 3, "bge": 3, "ble": 3,
        "j": 1, "jal": 1, "jr": 1,
        "nop": 0, "syscall": 0,
        "mult": 2, "div": 2,
        "mfhi": 1, "mflo": 1,
        "sll": 3, "srl": 3, "sra": 3,
        "mfc0": 2, "mfc1": 2, "mtc1": 2, "movs": 2, "movd": 2,
        "adds": 3, "subs": 3, "muls": 3, "divs": 3,
        "addd": 3, "subd": 3, "muld": 3, "divd": 3,
        "abss": 2, "absd": 2, "negs": 2, "negd": 2,
        "ceqs": 2, "clts": 2, "cles": 2,
        "ceqd": 2, "cltd": 2, "cled": 2,
        "cvtws": 2, "cvtsw": 2, "cvtwd": 2, "cvtdw": 2, "cvtsd": 2, "cvtds": 2,
        "bc1t": 1, "bc1f": 1, "rfe": 0
    ]

    private let dataBaseAddress = 0x10010000

    private func localized(_ key: String, _ args: CVarArg...) -> String {
        let languageRaw = UserDefaults.standard.string(forKey: "simula3ms.language") ?? AppLanguageSelection.automatic.rawValue
        let selection = AppLanguageSelection(rawValue: languageRaw) ?? .automatic
        let template = L10n.tr(key, languageCode: selection.languageCode)
        guard !args.isEmpty else { return template }
        return String(format: template, locale: Locale(identifier: selection.languageCode), arguments: args)
    }

    func assemble(_ source: String) throws -> AssemblyResult {
        let strippedLines = stripCommentsAndTrim(source)
        let sections = splitSections(strippedLines)

        var issues: [AssemblyIssue] = []
        issues.append(contentsOf: validateSourceAndSections(strippedLines: strippedLines, sections: sections))
        issues.append(contentsOf: validateTextHeader(sections.textLines))
        issues.append(contentsOf: validateOrphanLines(sections.orphanLines))

        let dataEntries = parseDataSection(sections.dataLines, issues: &issues)
        let dataAddresses = buildDataAddressTable(dataEntries)
        let program = parseTextSection(sections.textLines, isRoutine: false, issues: &issues)
        let routine = parseTextSection(sections.text0xLines, isRoutine: true, issues: &issues)

        validateOperandCounts(program.instructions, issues: &issues)
        validateOperandCounts(routine.instructions, issues: &issues)
        validateControlFlowTargets(
            instructions: program.instructions,
            labels: program.labels,
            dataAddresses: dataAddresses,
            issues: &issues
        )
        validateControlFlowTargets(
            instructions: routine.instructions,
            labels: routine.labels,
            dataAddresses: dataAddresses,
            issues: &issues
        )

        if !issues.isEmpty {
            throw AssemblyError.issues(issues.sorted { $0.lineNumber < $1.lineNumber })
        }

        return AssemblyResult(
            instructions: program.instructions,
            dataEntries: dataEntries,
            labels: program.labels,
            dataLabelAddresses: dataAddresses,
            routineInstructions: routine.instructions
        )
    }

    private func stripCommentsAndTrim(_ source: String) -> [(lineNumber: Int, text: String)] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, rawLine in
                let line = String(rawLine)
                let uncommented = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                let trimmed = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (index + 1, trimmed)
            }
    }

    private func splitSections(_ lines: [(lineNumber: Int, text: String)]) -> (
        dataLines: [(Int, String)],
        textLines: [(Int, String)],
        text0xLines: [(Int, String)],
        orphanLines: [(Int, String)]
    ) {
        enum SectionKind {
            case none
            case data
            case text
            case text0x
        }

        var current: SectionKind = .none
        var data: [(Int, String)] = []
        var text: [(Int, String)] = []
        var text0x: [(Int, String)] = []
        var orphan: [(Int, String)] = []

        for line in lines {
            let normalized = line.text.lowercased()

            if normalized == ".data" {
                current = .data
                continue
            }

            if normalized == ".text" {
                current = .text
                continue
            }

            if normalized.hasPrefix(".text ") {
                current = normalized.contains("0x80000080") ? .text0x : .none
                text0x.append(line)
                continue
            }

            switch current {
            case .data:
                data.append(line)
            case .text:
                text.append(line)
            case .text0x:
                text0x.append(line)
            case .none:
                orphan.append(line)
            }
        }

        return (data, text, text0x, orphan)
    }

    private func validateSourceAndSections(
        strippedLines: [(lineNumber: Int, text: String)],
        sections: (dataLines: [(Int, String)], textLines: [(Int, String)], text0xLines: [(Int, String)], orphanLines: [(Int, String)])
    ) -> [AssemblyIssue] {
        if strippedLines.isEmpty {
            return [AssemblyIssue(lineNumber: 1, message: localized("asm.error.emptyFile"), source: "")]
        }

        if sections.textLines.isEmpty {
            if let first = strippedLines.first {
                return [AssemblyIssue(
                    lineNumber: first.lineNumber,
                    message: localized("asm.error.noValidTextSection"),
                    source: first.text
                )]
            }
        }

        return []
    }

    private func validateOrphanLines(_ lines: [(Int, String)]) -> [AssemblyIssue] {
        lines.map { line in
            AssemblyIssue(
                lineNumber: line.0,
                message: localized("asm.error.lineOutsideSection"),
                source: line.1
            )
        }
    }

    private func validateTextHeader(_ textLines: [(Int, String)]) -> [AssemblyIssue] {
        var issues: [AssemblyIssue] = []
        guard let first = textLines.first else {
            return issues
        }

        if first.1 != ".globl main" {
            issues.append(AssemblyIssue(
                lineNumber: first.0,
                message: localized("asm.error.missingGloblMain"),
                source: first.1
            ))
        }

        if textLines.count > 1 {
            let second = textLines[1]
            if !second.1.hasPrefix("main:") {
                issues.append(AssemblyIssue(
                    lineNumber: second.0,
                    message: localized("asm.error.missingMainLabel"),
                    source: second.1
                ))
            }
        } else {
            issues.append(AssemblyIssue(lineNumber: first.0, message: localized("asm.error.missingMainLabel"), source: first.1))
        }

        return issues
    }

    private func parseDataSection(
        _ lines: [(Int, String)],
        issues: inout [AssemblyIssue]
    ) -> [DataEntry] {
        var entries: [DataEntry] = []
        var labels: Set<String> = []

        for line in lines {
            guard let colonIndex = line.1.firstIndex(of: ":") else {
                issues.append(AssemblyIssue(lineNumber: line.0, message: localized("asm.error.invalidDataLabel"), source: line.1))
                continue
            }

            let label = String(line.1[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let remainder = String(line.1[line.1.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            guard !label.isEmpty else {
                issues.append(AssemblyIssue(lineNumber: line.0, message: localized("asm.error.emptyDataLabel"), source: line.1))
                continue
            }

            if labels.contains(label) {
                issues.append(AssemblyIssue(lineNumber: line.0, message: localized("asm.error.duplicateDataLabel", label), source: line.1))
                continue
            }
            labels.insert(label)

            let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard let directiveToken = parts.first, let directive = DataDirective(rawValue: directiveToken) else {
                issues.append(AssemblyIssue(lineNumber: line.0, message: localized("asm.error.unsupportedDataDirective"), source: line.1))
                continue
            }

            let valuesPart = parts.count > 1 ? parts[1] : ""
            let values: [String]
            switch directive {
            case .ascii, .asciiz:
                values = [valuesPart.trimmingCharacters(in: .whitespaces)]
            default:
                values = splitDataValues(valuesPart)
            }

            entries.append(DataEntry(
                lineNumber: line.0,
                label: label,
                directive: directive,
                rawValues: values
            ))
        }

        return entries
    }

    private func buildDataAddressTable(_ entries: [DataEntry]) -> [String: Int] {
        var currentAddress = dataBaseAddress
        var table: [String: Int] = [:]

        for entry in entries {
            table[entry.label] = currentAddress
            currentAddress += storageSize(for: entry)
        }

        return table
    }

    private func storageSize(for entry: DataEntry) -> Int {
        switch entry.directive {
        case .word, .float:
            let count = max(entry.rawValues.count, 1)
            return count * 4
        case .space:
            let size = Int(entry.rawValues.first ?? "") ?? 0
            return max(size, 0)
        case .ascii:
            return decodeStringLength(entry.rawValues.first ?? "", includeNull: false)
        case .asciiz:
            return decodeStringLength(entry.rawValues.first ?? "", includeNull: true)
        }
    }

    private func decodeStringLength(_ raw: String, includeNull: Bool) -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            let body = decodeEscapedStringLiteral(String(trimmed.dropFirst().dropLast()))
            return body.count + (includeNull ? 1 : 0)
        }
        return trimmed.count + (includeNull ? 1 : 0)
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

    private func parseTextSection(
        _ lines: [(Int, String)],
        isRoutine: Bool,
        issues: inout [AssemblyIssue]
    ) -> (instructions: [AssembledInstruction], labels: [String: Int]) {
        var instructions: [AssembledInstruction] = []
        var labels: [String: Int] = [:]

        for line in lines {
            var working = line.1

            if working.hasPrefix(".text ") {
                if !working.lowercased().contains("0x80000080") {
                    issues.append(AssemblyIssue(
                        lineNumber: line.0,
                        message: localized("asm.error.invalidRoutineTextAddress"),
                        source: working
                    ))
                }
                continue
            }

            if working == ".globl main" {
                continue
            }

            // Support labels in-line, e.g. "loop: add $t0, $t1, $t2".
            while let colon = working.firstIndex(of: ":") {
                let candidate = String(working[..<colon]).trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || candidate.contains(" ") || candidate.contains("\t") {
                    break
                }

                if labels[candidate] != nil {
                    issues.append(AssemblyIssue(lineNumber: line.0, message: localized("asm.error.duplicateLabel", candidate), source: working))
                } else {
                    labels[candidate] = instructions.count
                }

                let remainder = String(working[working.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                working = remainder
                if working.isEmpty {
                    break
                }
            }

            if working.isEmpty || working == "main:" {
                continue
            }

            let (mnemonic, operands) = tokenizeInstruction(working)

            guard supportedMnemonics.contains(mnemonic) else {
                issues.append(AssemblyIssue(lineNumber: line.0, message: localized("asm.error.unsupportedInstruction", mnemonic), source: working))
                continue
            }

            instructions.append(
                AssembledInstruction(
                    lineNumber: line.0,
                    mnemonic: mnemonic,
                    operands: operands,
                    isRoutine: isRoutine
                )
            )
        }

        return (instructions, labels)
    }

    private func validateOperandCounts(
        _ instructions: [AssembledInstruction],
        issues: inout [AssemblyIssue]
    ) {
        for instruction in instructions {
            let expected = operandCountByMnemonic[instruction.mnemonic] ?? 0
            let actual = instruction.operands.count
            if expected != actual {
                issues.append(
                    AssemblyIssue(
                        lineNumber: instruction.lineNumber,
                        message: localized("asm.error.invalidOperandCount", instruction.mnemonic, expected, actual),
                        source: "\(instruction.mnemonic) \(instruction.operands.joined(separator: ", "))"
                    )
                )
            }
        }
    }

    private func validateControlFlowTargets(
        instructions: [AssembledInstruction],
        labels: [String: Int],
        dataAddresses: [String: Int],
        issues: inout [AssemblyIssue]
    ) {
        for instruction in instructions {
            switch instruction.mnemonic {
            case "beq", "bne", "bgt", "blt", "bge", "ble":
                guard instruction.operands.count == 3 else { continue }
                let target = instruction.operands[2]
                if !isNumericLiteral(target) && labels[target] == nil {
                    issues.append(
                        AssemblyIssue(
                            lineNumber: instruction.lineNumber,
                            message: localized("asm.error.undefinedConditionalJumpLabel", target),
                            source: "\(instruction.mnemonic) \(instruction.operands.joined(separator: ", "))"
                        )
                    )
                }

            case "j", "jal", "bc1t", "bc1f":
                guard instruction.operands.count == 1 else { continue }
                let target = instruction.operands[0]
                if !isNumericLiteral(target) && labels[target] == nil {
                    issues.append(
                        AssemblyIssue(
                            lineNumber: instruction.lineNumber,
                            message: localized("asm.error.undefinedJumpLabel", target),
                            source: "\(instruction.mnemonic) \(instruction.operands.joined(separator: ", "))"
                        )
                    )
                }

            case "la":
                guard instruction.operands.count == 2 else { continue }
                let target = instruction.operands[1]
                if labels[target] == nil && dataAddresses[target] == nil {
                    issues.append(
                        AssemblyIssue(
                            lineNumber: instruction.lineNumber,
                            message: localized("asm.error.undefinedAddressLabel", target),
                            source: "\(instruction.mnemonic) \(instruction.operands.joined(separator: ", "))"
                        )
                    )
                }

            default:
                break
            }
        }
    }

    private func isNumericLiteral(_ value: String) -> Bool {
        if Int(value) != nil {
            return true
        }

        if value.lowercased().hasPrefix("0x"), Int(value.dropFirst(2), radix: 16) != nil {
            return true
        }

        return false
    }

    private func splitDataValues(_ raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var insideQuotes = false

        for char in raw {
            if char == "\"" {
                insideQuotes.toggle()
                current.append(char)
                continue
            }

            if char == "," && !insideQuotes {
                let token = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    result.append(token)
                }
                current = ""
            } else {
                current.append(char)
            }
        }

        let finalToken = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalToken.isEmpty {
            result.append(finalToken)
        }

        return result
    }

    private func normalizeMnemonic(_ raw: String) -> String {
        let key = raw.lowercased()
        let map: [String: String] = [
            "add.s": "adds", "sub.s": "subs", "mul.s": "muls", "div.s": "divs",
            "add.d": "addd", "sub.d": "subd", "mul.d": "muld", "div.d": "divd",
            "mov.s": "movs", "mov.d": "movd",
            "abs.s": "abss", "abs.d": "absd",
            "neg.s": "negs", "neg.d": "negd",
            "c.eq.s": "ceqs", "c.lt.s": "clts", "c.le.s": "cles",
            "c.eq.d": "ceqd", "c.lt.d": "cltd", "c.le.d": "cled",
            "cvt.w.s": "cvtws", "cvt.s.w": "cvtsw",
            "cvt.w.d": "cvtwd", "cvt.d.w": "cvtdw",
            "cvt.s.d": "cvtsd", "cvt.d.s": "cvtds"
        ]
        return map[key] ?? key
    }

    private func tokenizeInstruction(_ line: String) -> (String, [String]) {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let mnemonic = normalizeMnemonic(parts.first ?? "")

        guard parts.count > 1 else {
            return (mnemonic, [])
        }

        let operands = parts[1]
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        return (mnemonic, operands)
    }
}
