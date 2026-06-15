import Foundation

enum AdvancedSchedulingMode {
    case segmented
    case scoreboard
    case tomasulo
}

enum DataPathCycleMode {
    case monocycle
    case multicycle
}

struct AdvancedSimulationResult {
    let cycles: [CPUCycleSnapshot]
    let trace: [String]
    let totalCycles: Int
}

final class AdvancedSimulationEngine {
    func simulate(
        instructions: [AssembledInstruction],
        mode: AdvancedSchedulingMode,
        dataPathMode: DataPathCycleMode = .monocycle,
        multicycleConfig: MulticycleConfig = .init(),
        functionalUnitsConfig: FunctionalUnitsConfig = .init(),
        scoreboardConfig: ScoreboardConfig = .init(),
        tomasuloConfig: TomasuloConfig = .init(),
        maxCycles: Int = 2_000
    ) -> AdvancedSimulationResult {
        switch mode {
        case .segmented:
            return simulateSegmented(
                instructions: instructions,
                dataPathMode: dataPathMode,
                functionalUnitsConfig: functionalUnitsConfig,
                maxCycles: maxCycles
            )
        case .scoreboard:
            return simulateScoreboard(
                instructions: instructions,
                dataPathMode: dataPathMode,
                multicycleConfig: multicycleConfig,
                scoreboardConfig: scoreboardConfig,
                maxCycles: maxCycles
            )
        case .tomasulo:
            return simulateTomasulo(
                instructions: instructions,
                dataPathMode: dataPathMode,
                multicycleConfig: multicycleConfig,
                tomasuloConfig: tomasuloConfig,
                maxCycles: maxCycles
            )
        }
    }

    private func simulateSegmented(
        instructions: [AssembledInstruction],
        dataPathMode: DataPathCycleMode,
        functionalUnitsConfig: FunctionalUnitsConfig,
        maxCycles: Int
    ) -> AdvancedSimulationResult {
        var snapshots: [CPUCycleSnapshot] = []
        var trace: [String] = []

        // IF, ID, EX, MEM, WB
        var pipeline: [Int?] = Array(repeating: nil, count: 5)
        var nextToFetch = 0
        var completed = 0

        let deps = instructions.map { dependencies(for: $0) }

        var exRemaining: [Int: Int] = [:]
        var fpInFlight: [String: [Int]] = ["ADD": [], "MUL": [], "DIV": []]
        var cycle = 0
        while cycle < maxCycles, completed < instructions.count {
            cycle += 1

            for key in fpInFlight.keys {
                fpInFlight[key] = fpInFlight[key, default: []].compactMap { remaining in
                    let next = remaining - 1
                    return next > 0 ? next : nil
                }
            }

            if let wb = pipeline[4] {
                completed = max(completed, wb + 1)
            }

            let old = pipeline
            let idIndex = old[1]
            let exIndex = old[2]

            var loadUseStall = false
            if let idIndex, let exIndex {
                let producer = instructions[exIndex]
                if isLoadMnemonic(producer.mnemonic) {
                    let producerWrites = deps[exIndex].writes
                    let consumerReads = deps[idIndex].reads
                    loadUseStall = !producerWrites.isDisjoint(with: consumerReads)
                }
            }

            var controlStall = false
            if let idIndex {
                let control = instructions[idIndex]
                controlStall = isControlMnemonic(control.mnemonic)
            }

            var exLatencyStall = false
            if let exIndex {
                let current = exRemaining[exIndex] ?? segmentedEXLatency(
                    for: instructions[exIndex].mnemonic,
                    config: functionalUnitsConfig
                )
                if current > 1 {
                    exRemaining[exIndex] = current - 1
                    exLatencyStall = true
                } else {
                    exRemaining[exIndex] = 1
                }
            }

            var fpUnitStall = false
            var next: [Int?] = Array(repeating: nil, count: 5)
            next[4] = old[3]

            if exLatencyStall {
                // Keep EX occupied while long-latency functional unit completes.
                next[3] = nil
                next[2] = old[2]
                next[1] = old[1]
                next[0] = old[0]
            } else {
                next[3] = old[2]

                if let candidateEX = old[1],
                   let fpClass = segmentedFPClassForMnemonic(instructions[candidateEX].mnemonic),
                   let unitRow = segmentedUnitRow(for: fpClass, config: functionalUnitsConfig) {
                    let capacity = unitRow.segmented
                        ? max(1, unitRow.units) * max(1, unitRow.latency)
                        : max(1, unitRow.units)
                    let inFlightCount = fpInFlight[fpClass, default: []].count
                    fpUnitStall = inFlightCount >= capacity
                }

                if loadUseStall || fpUnitStall {
                    // Bubble in EX, freeze IF/ID one cycle.
                    next[2] = nil
                    next[1] = old[1]
                    next[0] = old[0]
                } else {
                    next[2] = old[1]
                    if let newEX = next[2] {
                        exRemaining[newEX] = segmentedEXLatency(
                            for: instructions[newEX].mnemonic,
                            config: functionalUnitsConfig
                        )
                        if let fpClass = segmentedFPClassForMnemonic(instructions[newEX].mnemonic),
                           let unitRow = segmentedUnitRow(for: fpClass, config: functionalUnitsConfig) {
                            fpInFlight[fpClass, default: []].append(max(1, unitRow.latency))
                        }
                    }
                    next[1] = old[0]

                    if controlStall {
                        // Simple one-cycle fetch stall for branch/jump in ID.
                        next[0] = nil
                    } else if nextToFetch < instructions.count {
                        next[0] = nextToFetch
                        nextToFetch += 1
                    } else {
                        next[0] = nil
                    }
                }
            }

            pipeline = next

            let stageStrings = zip(["IF", "ID", "EX", "MEM", "WB"], pipeline).map { stage, idx in
                if let idx {
                    return "\(stage):I\(idx + 1)"
                }
                return "\(stage):-"
            }

            let summary = stageStrings.joined(separator: " ")
            let hazardText = "hazards[LU=\(loadUseStall ? 1 : 0),CTRL=\(controlStall ? 1 : 0),EXLAT=\(exLatencyStall ? 1 : 0),FPU=\(fpUnitStall ? 1 : 0)]"
            trace.append("C\(cycle) \(summary) \(hazardText)")

            let occupied = pipeline.compactMap { $0 }.count
            snapshots.append(
                CPUCycleSnapshot(
                    cycle: cycle,
                    pcBefore: max(nextToFetch - 1, 0),
                    pcAfter: nextToFetch,
                    instruction: "SEG \(summary) \(hazardText)",
                    t0: nextToFetch,
                    t1: occupied,
                    t2: completed,
                    s0: (loadUseStall || exLatencyStall || fpUnitStall) ? 1 : 0,
                    s1: controlStall ? 1 : 0,
                    hi: 0,
                    lo: 0
                )
            )
        }

        return AdvancedSimulationResult(cycles: snapshots, trace: trace, totalCycles: snapshots.count)
    }

    private func simulateScoreboard(
        instructions: [AssembledInstruction],
        dataPathMode: DataPathCycleMode,
        multicycleConfig: MulticycleConfig,
        scoreboardConfig: ScoreboardConfig,
        maxCycles: Int
    ) -> AdvancedSimulationResult {
        enum State {
            case waitOperands
            case executing
            case done
        }

        struct ActiveOp {
            let index: Int
            let unit: String
            let deps: InstructionDependencies
            var remaining: Int
            var state: State
        }

        let deps = instructions.map { dependencies(for: $0) }
        let unitCapacity: [String: Int] = [
            "INT": max(1, scoreboardConfig.intUnits),
            "ADD": max(1, scoreboardConfig.addFPUnits),
            "MUL": max(1, scoreboardConfig.multFPUnits),
            "DIV": max(1, scoreboardConfig.divFPUnits)
        ]

        var snapshots: [CPUCycleSnapshot] = []
        var trace: [String] = []

        var active: [ActiveOp] = []
        var issued = 0
        var completed = 0

        var cycle = 0
        while cycle < maxCycles, completed < instructions.count {
            cycle += 1

            var stallStructural = false
            var stallWAW = false
            var stallRAW = 0
            var stallWAR = 0

            // Issue stage: structural + WAW.
            if issued < instructions.count {
                let instr = instructions[issued]
                let currentDeps = deps[issued]
                let unit = scoreboardUnitForMnemonic(instr.mnemonic)
                let used = active.filter { $0.unit == unit }.count
                let cap = unitCapacity[unit, default: 1]

                let pendingWrites = Set(active.flatMap { $0.deps.writes })
                let hasWAW = !pendingWrites.isDisjoint(with: currentDeps.writes)

                if used < cap, !hasWAW {
                    active.append(
                        ActiveOp(
                            index: issued,
                            unit: unit,
                            deps: currentDeps,
                            remaining: scoreboardLatencyForMnemonic(
                                instr.mnemonic,
                                dataPathMode: dataPathMode,
                                multicycleConfig: multicycleConfig,
                                scoreboardConfig: scoreboardConfig
                            ),
                            state: .waitOperands
                        )
                    )
                    issued += 1
                } else {
                    stallStructural = used >= cap
                    stallWAW = hasWAW
                }
            }

            // Read operands + execute.
            for i in active.indices {
                switch active[i].state {
                case .waitOperands:
                    let olderWriters = active
                        .filter { $0.index < active[i].index && $0.state != .done }
                        .flatMap { $0.deps.writes }
                    let hasRaw = !Set(olderWriters).isDisjoint(with: active[i].deps.reads)

                    if hasRaw {
                        stallRAW += 1
                    } else {
                        active[i].state = .executing
                    }

                case .executing:
                    active[i].remaining -= 1
                    if active[i].remaining <= 0 {
                        active[i].state = .done
                    }

                case .done:
                    break
                }
            }

            // Write result with WAR check.
            if let doneIndex = active.firstIndex(where: { $0.state == .done }) {
                let writer = active[doneIndex]
                let hasWAR = active.contains { op in
                    op.index < writer.index && op.state == .waitOperands && !op.deps.reads.isDisjoint(with: writer.deps.writes)
                }

                if hasWAR {
                    stallWAR += 1
                } else {
                    active.remove(at: doneIndex)
                    completed += 1
                }
            }

            let activeSummary = active
                .prefix(4)
                .map { op in
                    let state: String
                    switch op.state {
                    case .waitOperands:
                        state = "W"
                    case .executing:
                        state = "E"
                    case .done:
                        state = "D"
                    }
                    return "I\(op.index + 1):\(op.unit)\(state)[\(op.remaining)]"
                }
                .joined(separator: " ")

            let line = "C\(cycle) issue=\(issued) active=\(active.count) done=\(completed) RAW=\(stallRAW) WAR=\(stallWAR) \(activeSummary)"
            trace.append(line)

            snapshots.append(
                CPUCycleSnapshot(
                    cycle: cycle,
                    pcBefore: max(issued - 1, 0),
                    pcAfter: issued,
                    instruction: "SCB \(line)",
                    t0: issued,
                    t1: active.count,
                    t2: completed,
                    s0: (stallStructural || stallWAW || stallRAW > 0) ? 1 : 0,
                    s1: stallWAR,
                    hi: 0,
                    lo: 0
                )
            )
        }

        return AdvancedSimulationResult(cycles: snapshots, trace: trace, totalCycles: snapshots.count)
    }

    private func simulateTomasulo(
        instructions: [AssembledInstruction],
        dataPathMode: DataPathCycleMode,
        multicycleConfig: MulticycleConfig,
        tomasuloConfig: TomasuloConfig,
        maxCycles: Int
    ) -> AdvancedSimulationResult {
        enum StationState {
            case waiting
            case executing
            case readyToWrite
        }

        struct Station {
            let name: String
            var opIndex: Int?
            var remaining: Int
            var state: StationState
            var waitingTags: Set<String>
            var writes: Set<String>
        }

        let deps = instructions.map { dependencies(for: $0) }

        var snapshots: [CPUCycleSnapshot] = []
        var trace: [String] = []

        var stations: [Station] = []
        stations += (1...max(1, tomasuloConfig.addFPUnits)).map { i in
            Station(name: "A\(i)", opIndex: nil, remaining: 0, state: .waiting, waitingTags: [], writes: [])
        }
        stations += (1...max(1, tomasuloConfig.multFPUnits)).map { i in
            Station(name: "M\(i)", opIndex: nil, remaining: 0, state: .waiting, waitingTags: [], writes: [])
        }
        stations += (1...max(1, tomasuloConfig.divFPUnits)).map { i in
            Station(name: "D\(i)", opIndex: nil, remaining: 0, state: .waiting, waitingTags: [], writes: [])
        }
        stations += (1...max(1, tomasuloConfig.loadFPUnits)).map { i in
            Station(name: "L\(i)", opIndex: nil, remaining: 0, state: .waiting, waitingTags: [], writes: [])
        }
        stations += (1...max(1, tomasuloConfig.storeFPUnits)).map { i in
            Station(name: "S\(i)", opIndex: nil, remaining: 0, state: .waiting, waitingTags: [], writes: [])
        }

        var registerTag: [String: String] = [:]

        var issued = 0
        var completed = 0
        var cycle = 0

        while cycle < maxCycles, completed < instructions.count {
            cycle += 1

            var issueStall = false
            var cdbStall = 0

            // Execute stage.
            for i in stations.indices {
                guard let opIndex = stations[i].opIndex else { continue }

                switch stations[i].state {
                case .waiting:
                    if stations[i].waitingTags.isEmpty {
                        stations[i].state = .executing
                        stations[i].remaining = tomasuloLatencyForMnemonic(
                            instructions[opIndex].mnemonic,
                            dataPathMode: dataPathMode,
                            multicycleConfig: multicycleConfig,
                            tomasuloConfig: tomasuloConfig
                        )
                    }

                case .executing:
                    stations[i].remaining -= 1
                    if stations[i].remaining <= 0 {
                        stations[i].state = .readyToWrite
                    }

                case .readyToWrite:
                    break
                }
            }

            // CDB: one broadcast per cycle.
            let ready = stations.indices.compactMap { i -> (Int, Int)? in
                guard let op = stations[i].opIndex, stations[i].state == .readyToWrite else { return nil }
                return (i, op)
            }

            if let winner = ready.min(by: { $0.1 < $1.1 }) {
                let stationIndex = winner.0
                let stationName = stations[stationIndex].name
                let writes = stations[stationIndex].writes

                // Broadcast to waiting stations.
                for i in stations.indices where i != stationIndex && stations[i].opIndex != nil {
                    stations[i].waitingTags.remove(stationName)
                }

                // Clear register tags for committed producer.
                for reg in writes where registerTag[reg] == stationName {
                    registerTag[reg] = nil
                }

                stations[stationIndex].opIndex = nil
                stations[stationIndex].remaining = 0
                stations[stationIndex].state = .waiting
                stations[stationIndex].waitingTags = []
                stations[stationIndex].writes = []
                completed += 1

                cdbStall = max(ready.count - 1, 0)
            }

            // Issue stage.
            if issued < instructions.count {
                let instr = instructions[issued]
                let wanted = tomasuloStationClassForMnemonic(instr.mnemonic)
                if let free = stations.firstIndex(where: { $0.opIndex == nil && $0.name.hasPrefix(wanted) }) {
                    let currentDeps = deps[issued]

                    var waitTags: Set<String> = []
                    for reg in currentDeps.reads {
                        if let tag = registerTag[reg] {
                            waitTags.insert(tag)
                        }
                    }

                    stations[free].opIndex = issued
                    stations[free].state = .waiting
                    stations[free].remaining = tomasuloLatencyForMnemonic(
                        instr.mnemonic,
                        dataPathMode: dataPathMode,
                        multicycleConfig: multicycleConfig,
                        tomasuloConfig: tomasuloConfig
                    )
                    stations[free].waitingTags = waitTags
                    stations[free].writes = currentDeps.writes

                    for reg in currentDeps.writes {
                        registerTag[reg] = stations[free].name
                    }

                    issued += 1
                } else {
                    issueStall = true
                }
            }

            let busyStations = stations.filter { $0.opIndex != nil }
            let busySummary = busyStations.prefix(4).map { station in
                let opLabel: String
                if let op = station.opIndex {
                    switch station.state {
                    case .waiting:
                        opLabel = "I\(op + 1):W"
                    case .executing:
                        opLabel = "I\(op + 1):E[\(station.remaining)]"
                    case .readyToWrite:
                        opLabel = "I\(op + 1):WB"
                    }
                } else {
                    opLabel = "-"
                }
                return "\(station.name):\(opLabel)"
            }.joined(separator: " ")

            let line = "C\(cycle) issue=\(issued) busy=\(busyStations.count) done=\(completed) cdbWait=\(cdbStall) \(busySummary)"
            trace.append(line)

            snapshots.append(
                CPUCycleSnapshot(
                    cycle: cycle,
                    pcBefore: max(issued - 1, 0),
                    pcAfter: issued,
                    instruction: "TOM \(line)",
                    t0: issued,
                    t1: busyStations.count,
                    t2: completed,
                    s0: issueStall ? 1 : 0,
                    s1: cdbStall,
                    hi: 0,
                    lo: 0
                )
            )
        }

        return AdvancedSimulationResult(cycles: snapshots, trace: trace, totalCycles: snapshots.count)
    }

    private struct InstructionDependencies {
        let reads: Set<String>
        let writes: Set<String>
    }

    private func dependencies(for instruction: AssembledInstruction) -> InstructionDependencies {
        let op = instruction.mnemonic
        let a = instruction.operands

        switch op {
        case "add", "sub", "and", "or", "xor", "nor", "slt", "sll", "srl", "sra":
            if a.count == 3 {
                return .init(reads: regs([a[1], a[2]]), writes: regs([a[0]]))
            }
        case "addi", "andi", "ori", "xori", "slti":
            if a.count == 3 {
                return .init(reads: regs([a[1]]), writes: regs([a[0]]))
            }
        case "li", "lui":
            if a.count == 2 {
                return .init(reads: [], writes: regs([a[0]]))
            }
        case "move", "neg", "not":
            if a.count == 2 {
                return .init(reads: regs([a[1]]), writes: regs([a[0]]))
            }
        case "la":
            if a.count == 2 {
                return .init(reads: [], writes: regs([a[0]]))
            }
        case "lw", "lb":
            if a.count == 2 {
                return .init(reads: regs([baseRegister(from: a[1])]), writes: regs([a[0]]))
            }
        case "sw", "sb":
            if a.count == 2 {
                return .init(reads: regs([a[0], baseRegister(from: a[1])]), writes: [])
            }
        case "beq", "bne", "bgt", "blt", "bge", "ble":
            if a.count >= 2 {
                return .init(reads: regs([a[0], a[1]]), writes: [])
            }
        case "jr":
            if a.count == 1 {
                return .init(reads: regs([a[0]]), writes: [])
            }
        case "jal":
            return .init(reads: [], writes: regs(["$ra"]))
        case "mult", "div":
            if a.count == 2 {
                return .init(reads: regs([a[0], a[1]]), writes: ["$hi", "$lo"])
            }
        case "mfhi":
            if a.count == 1 {
                return .init(reads: ["$hi"], writes: regs([a[0]]))
            }
        case "mflo":
            if a.count == 1 {
                return .init(reads: ["$lo"], writes: regs([a[0]]))
            }
        case "lwc1":
            if a.count == 2 {
                return .init(reads: regs([baseRegister(from: a[1])]), writes: regs([a[0]]))
            }
        case "swc1":
            if a.count == 2 {
                return .init(reads: regs([a[0], baseRegister(from: a[1])]), writes: [])
            }
        case "mfc0", "mfc1":
            if a.count == 2 {
                return .init(reads: regs([a[1]]), writes: regs([a[0]]))
            }
        case "mtc1":
            if a.count == 2 {
                return .init(reads: regs([a[0]]), writes: regs([a[1]]))
            }
        case "movs", "movd", "abss", "absd", "negs", "negd":
            if a.count == 2 {
                return .init(reads: regs([a[1]]), writes: regs([a[0]]))
            }
        case "adds", "subs", "muls", "divs", "addd", "subd", "muld", "divd":
            if a.count == 3 {
                return .init(reads: regs([a[1], a[2]]), writes: regs([a[0]]))
            }
        case "ceqs", "clts", "cles", "ceqd", "cltd", "cled":
            if a.count == 2 {
                return .init(reads: regs([a[0], a[1]]), writes: [])
            }
        case "cvtws", "cvtsw", "cvtwd", "cvtdw", "cvtsd", "cvtds":
            if a.count == 2 {
                return .init(reads: regs([a[1]]), writes: regs([a[0]]))
            }
        default:
            break
        }

        return .init(reads: [], writes: [])
    }

    private func regs(_ raw: [String?]) -> Set<String> {
        Set(raw.compactMap { $0 }.compactMap { normalizedRegisterName(from: $0) })
    }

    private func normalizedRegisterName(from token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dollar = trimmed.firstIndex(of: "$") else { return nil }
        var reg = String(trimmed[dollar...]).lowercased()

        if let end = reg.firstIndex(where: { !$0.isLetter && !$0.isNumber && $0 != "$" }) {
            reg = String(reg[..<end])
        }

        return reg.isEmpty ? nil : reg
    }

    private func baseRegister(from addressing: String) -> String? {
        guard let open = addressing.firstIndex(of: "("), let close = addressing.firstIndex(of: ")"), open < close else {
            return normalizedRegisterName(from: addressing)
        }
        let base = String(addressing[addressing.index(after: open)..<close])
        return normalizedRegisterName(from: base)
    }

    private func isLoadMnemonic(_ mnemonic: String) -> Bool {
        switch mnemonic {
        case "lw", "lb", "lwc1":
            return true
        default:
            return false
        }
    }

    private func isControlMnemonic(_ mnemonic: String) -> Bool {
        switch mnemonic {
        case "beq", "bne", "bgt", "blt", "bge", "ble", "j", "jal", "jr", "bc1t", "bc1f":
            return true
        default:
            return false
        }
    }

    private func segmentedFPClassForMnemonic(_ mnemonic: String) -> String? {
        if isFPAddMnemonic(mnemonic) { return "ADD" }
        if isFPMulMnemonic(mnemonic) { return "MUL" }
        if isFPDivMnemonic(mnemonic) { return "DIV" }
        return nil
    }

    private func segmentedUnitRow(for fpClass: String, config: FunctionalUnitsConfig) -> FunctionalUnitRow? {
        switch fpClass {
        case "ADD": return config.addFP
        case "MUL": return config.multFP
        case "DIV": return config.divFP
        default: return nil
        }
    }

    private func segmentedEXLatency(for mnemonic: String, config: FunctionalUnitsConfig) -> Int {
        guard let fpClass = segmentedFPClassForMnemonic(mnemonic),
              let row = segmentedUnitRow(for: fpClass, config: config) else {
            return 1
        }
        // In segmented mode the EX stage can accept one op per cycle; non-segmented blocks EX for full latency.
        return row.segmented ? 1 : max(1, row.latency)
    }

    private func scoreboardUnitForMnemonic(_ mnemonic: String) -> String {
        if isFPMulMnemonic(mnemonic) { return "MUL" }
        if isFPDivMnemonic(mnemonic) { return "DIV" }
        if isFPAddMnemonic(mnemonic) || isFloatingMnemonic(mnemonic) { return "ADD" }
        return "INT"
    }

    private func scoreboardLatencyForMnemonic(
        _ mnemonic: String,
        dataPathMode: DataPathCycleMode,
        multicycleConfig: MulticycleConfig,
        scoreboardConfig: ScoreboardConfig
    ) -> Int {
        if scoreboardUnitForMnemonic(mnemonic) == "INT" {
            if dataPathMode == .multicycle, isIntegerAddFamilyMnemonic(mnemonic) {
                return max(1, multicycleConfig.addLatency)
            }
            return max(1, scoreboardConfig.intLatency)
        }
        if scoreboardUnitForMnemonic(mnemonic) == "ADD" {
            return max(1, scoreboardConfig.addFPLatency)
        }
        if scoreboardUnitForMnemonic(mnemonic) == "MUL" {
            return max(1, scoreboardConfig.multFPLatency)
        }
        return max(1, scoreboardConfig.divFPLatency)
    }

    private func tomasuloStationClassForMnemonic(_ mnemonic: String) -> String {
        if mnemonic == "lw" || mnemonic == "lb" || mnemonic == "lwc1" { return "L" }
        if mnemonic == "sw" || mnemonic == "sb" || mnemonic == "swc1" { return "S" }
        if isFPMulMnemonic(mnemonic) { return "M" }
        if isFPDivMnemonic(mnemonic) { return "D" }
        return "A"
    }

    private func tomasuloLatencyForMnemonic(
        _ mnemonic: String,
        dataPathMode: DataPathCycleMode,
        multicycleConfig: MulticycleConfig,
        tomasuloConfig: TomasuloConfig
    ) -> Int {
        switch tomasuloStationClassForMnemonic(mnemonic) {
        case "L":
            return max(1, tomasuloConfig.loadFPLatency)
        case "S":
            return max(1, tomasuloConfig.storeFPLatency)
        case "M":
            return max(1, tomasuloConfig.multFPLatency)
        case "D":
            return max(1, tomasuloConfig.divFPLatency)
        default:
            if dataPathMode == .multicycle, isIntegerAddFamilyMnemonic(mnemonic) {
                return max(1, multicycleConfig.addLatency)
            }
            return max(1, tomasuloConfig.addFPLatency)
        }
    }

    private func isFloatingMnemonic(_ mnemonic: String) -> Bool {
        isFPAddMnemonic(mnemonic)
            || isFPMulMnemonic(mnemonic)
            || isFPDivMnemonic(mnemonic)
            || ["lwc1", "swc1", "mfc0", "mfc1", "mtc1", "bc1t", "bc1f", "movs", "movd", "mov.s", "mov.d"].contains(mnemonic)
    }

    private func isFPAddMnemonic(_ mnemonic: String) -> Bool {
        ["adds", "subs", "addd", "subd", "add.s", "sub.s", "add.d", "sub.d", "ceqs", "clts", "cles", "ceqd", "cltd", "cled", "c.eq.s", "c.lt.s", "c.le.s", "c.eq.d", "c.lt.d", "c.le.d", "cvtws", "cvtsw", "cvtwd", "cvtdw", "cvtsd", "cvtds", "abss", "absd", "negs", "negd"].contains(mnemonic)
    }

    private func isFPMulMnemonic(_ mnemonic: String) -> Bool {
        ["muls", "muld", "mul.s", "mul.d", "mult"].contains(mnemonic)
    }

    private func isFPDivMnemonic(_ mnemonic: String) -> Bool {
        ["divs", "divd", "div.s", "div.d", "div"].contains(mnemonic)
    }

    private func isIntegerAddFamilyMnemonic(_ mnemonic: String) -> Bool {
        ["add", "addi", "addiu", "sub", "and", "andi", "or", "ori", "xor", "xori", "slt", "slti", "move", "neg", "not", "sll", "srl", "sra", "li", "lui"].contains(mnemonic)
    }
}
