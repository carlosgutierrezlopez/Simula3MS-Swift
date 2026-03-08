import Foundation

struct SimulationValidationResult {
    let passed: Int
    let failed: Int
    let lines: [String]

    var summaryText: String {
        (["Validacion interna:"] + lines + ["Resultado: \(passed) OK / \(failed) FAIL"]).joined(separator: "\n")
    }
}

@MainActor
enum SimulationValidationSuite {
    static func runAll() -> SimulationValidationResult {
        let tests: [(String, () throws -> Void)] = [
            ("Assembler arma programa base", testAssemblerBasic),
            ("Assembler soporta etiqueta en línea", testInlineLabel),
            ("Assembler normaliza mnemónicos con punto", testDottedMnemonicNormalization),
            ("CPU ejecuta suma entera", testCPUAdd),
            ("CPU branch fijo no ejecuta delay slot", testFixedBranchSkipsDelaySlot),
            ("CPU soporte branch retardado", testDelayedBranch),
            ("CPU carga y guarda memoria", testLoadStoreWord),
            ("CPU salta con jal/jr", testJalAndJr),
            ("CPU syscall imprime string", testSyscallPrintString),
            ("CPU syscall lee entero de entrada", testSyscallReadInt),
            ("CPU syscall imprime float", testSyscallPrintFloat),
            ("CPU syscall lee string", testSyscallReadString),
            ("Segmentado genera trazas de hazard", testSegmentedHazardTrace),
            ("Scoreboard responde a latencias", testScoreboardLatencyEffect),
            ("Tomasulo responde a unidades", testTomasuloUnitsEffect),
            ("Golden: aritmética base por modos", testGoldenArithmeticModes),
            ("Golden: branch fijo vs retardado", testGoldenBranchModes),
            ("Golden: memoria por modos", testGoldenMemoryModes),
            ("Planificador avanzado genera ciclos", testAdvancedEngine)
        ]

        var passed = 0
        var failed = 0
        var lines: [String] = []

        for (name, block) in tests {
            do {
                try block()
                passed += 1
                lines.append("[OK] \(name)")
            } catch {
                failed += 1
                lines.append("[FAIL] \(name): \(error.localizedDescription)")
            }
        }

        return SimulationValidationResult(passed: passed, failed: failed, lines: lines)
    }

    private static func testAssemblerBasic() throws {
        let assembler = AssemblerEngine()
        let source = """
        .text
        .globl main
        main:
            li $t0, 1
            syscall
        """

        let result = try assembler.assemble(source)
        guard result.instructions.count == 2 else {
            throw ValidationError("Se esperaban 2 instrucciones, hay \(result.instructions.count)")
        }
    }

    private static func testInlineLabel() throws {
        let assembler = AssemblerEngine()
        let source = """
        .text
        .globl main
        main: li $t0, 1
              j fin
        fin:  syscall
        """

        let result = try assembler.assemble(source)
        guard result.labels["main"] != nil, result.labels["fin"] != nil else {
            throw ValidationError("No se detectaron etiquetas en línea")
        }
    }

    private static func testDottedMnemonicNormalization() throws {
        let assembler = AssemblerEngine()
        let source = """
        .text
        .globl main
        main:
            add.s $f0, $f1, $f2
            c.eq.d $f4, $f6
            cvt.w.d $f8, $f10
            li $v0, 10
            syscall
        """

        let result = try assembler.assemble(source)
        let got = result.instructions.map(\.mnemonic)
        let expected = ["adds", "ceqd", "cvtwd", "li", "syscall"]
        guard got == expected else {
            throw ValidationError("Normalizacion esperada=\(expected) obtenida=\(got)")
        }
    }

    private static func testCPUAdd() throws {
        let assembler = AssemblerEngine()
        let cpu = CPUEngine()

        let source = """
        .text
        .globl main
        main:
            li $t0, 7
            li $t1, 5
            add $t2, $t0, $t1
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let exec = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .disabled
        )

        guard exec.registers["$t2"] == 12 else {
            throw ValidationError("$t2 esperado=12 obtenido=\(exec.registers["$t2"] ?? -1)")
        }
    }

    private static func testDelayedBranch() throws {
        let assembler = AssemblerEngine()
        let cpu = CPUEngine()

        let source = """
        .text
        .globl main
        main:
            li $t0, 0
            li $t1, 0
            beq $t0, $t1, destino
            li $t2, 99
        destino:
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let exec = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .delayed,
            ioMode: .disabled
        )

        guard exec.registers["$t2"] == 99 else {
            throw ValidationError("Slot retardado no aplicado; $t2=\(exec.registers["$t2"] ?? -1)")
        }
    }

    private static func testFixedBranchSkipsDelaySlot() throws {
        let assembler = AssemblerEngine()
        let cpu = CPUEngine()

        let source = """
        .text
        .globl main
        main:
            li $t0, 0
            li $t1, 0
            beq $t0, $t1, destino
            li $t2, 99
        destino:
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let exec = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .disabled
        )

        guard exec.registers["$t2"] == 0 else {
            throw ValidationError("En branch fijo no debe ejecutarse delay slot; $t2=\(exec.registers["$t2"] ?? -1)")
        }
    }

    private static func testLoadStoreWord() throws {
        let assembler = AssemblerEngine()
        let cpu = CPUEngine()

        let source = """
        .data
        val: .word 0

        .text
        .globl main
        main:
            li $t0, 42
            la $t1, val
            sw $t0, 0($t1)
            lw $t2, 0($t1)
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let exec = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .disabled
        )

        guard exec.registers["$t2"] == 42 else {
            throw ValidationError("LW/SW esperado=42 obtenido=\(exec.registers["$t2"] ?? -1)")
        }
    }

    private static func testJalAndJr() throws {
        let assembler = AssemblerEngine()
        let cpu = CPUEngine()

        let source = """
        .text
        .globl main
        main:
            li $t0, 1
            jal rutina
            li $v0, 10
            syscall
        rutina:
            addi $t0, $t0, 4
            jr $ra
        """

        let asm = try assembler.assemble(source)
        let exec = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .disabled
        )

        guard exec.registers["$t0"] == 5 else {
            throw ValidationError("JAL/JR esperado $t0=5 obtenido=\(exec.registers["$t0"] ?? -1)")
        }
    }

    private static func testSyscallPrintString() throws {
        let assembler = AssemblerEngine()
        let cpu = CPUEngine()

        let source = """
        .data
        msg: .asciiz "OK"

        .text
        .globl main
        main:
            la $a0, msg
            li $v0, 4
            syscall
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let exec = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .mapped
        )

        guard exec.ioOutput.contains("OK") else {
            throw ValidationError("Salida esperada contiene 'OK', salida='\(exec.ioOutput)'")
        }
    }

    private static func testSyscallReadInt() throws {
        let assembler = AssemblerEngine()
        let cpu = CPUEngine()

        let source = """
        .text
        .globl main
        main:
            li $v0, 5
            syscall
            move $t0, $v0
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let exec = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .mapped,
            inputText: "123"
        )

        guard exec.registers["$t0"] == 123 else {
            throw ValidationError("Lectura de entero esperada=123 obtenida=\(exec.registers["$t0"] ?? -1)")
        }
    }

    private static func testSyscallPrintFloat() throws {
        let assembler = AssemblerEngine()
        let cpu = CPUEngine()

        let source = """
        .text
        .globl main
        main:
            li $t0, 1069547520
            mtc1 $t0, $f12
            li $v0, 2
            syscall
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let exec = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .mapped
        )

        guard exec.ioOutput.contains("1.5") else {
            throw ValidationError("Salida float esperada contiene '1.5', salida='\(exec.ioOutput)'")
        }
    }

    private static func testSyscallReadString() throws {
        let assembler = AssemblerEngine()
        let cpu = CPUEngine()

        let source = """
        .data
        buf: .space 32

        .text
        .globl main
        main:
            li $v0, 8
            la $a0, buf
            li $a1, 32
            syscall
            li $v0, 4
            la $a0, buf
            syscall
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let exec = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .mapped,
            inputText: "texto prueba\n"
        )

        guard exec.ioOutput.contains("texto prueba") else {
            throw ValidationError("Salida string esperada contiene 'texto prueba', salida='\(exec.ioOutput)'")
        }
    }

    private static func testAdvancedEngine() throws {
        let assembler = AssemblerEngine()
        let advanced = AdvancedSimulationEngine()

        let source = """
        .text
        .globl main
        main:
            li $t0, 1
            li $t1, 2
            add $t2, $t0, $t1
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let result = advanced.simulate(instructions: asm.instructions, mode: .scoreboard)

        guard result.totalCycles > 0 else {
            throw ValidationError("No se generaron ciclos en planificador")
        }
    }

    private static func testSegmentedHazardTrace() throws {
        let assembler = AssemblerEngine()
        let advanced = AdvancedSimulationEngine()

        let source = """
        .text
        .globl main
        main:
            lw $t0, 0($t1)
            add $t2, $t0, $t3
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let result = advanced.simulate(
            instructions: asm.instructions,
            mode: .segmented
        )

        guard result.trace.contains(where: { $0.contains("hazards[") }) else {
            throw ValidationError("Segmentado sin traza de hazards")
        }
    }

    private static func testScoreboardLatencyEffect() throws {
        let assembler = AssemblerEngine()
        let advanced = AdvancedSimulationEngine()

        let source = """
        .text
        .globl main
        main:
            li $t0, 1
            addi $t0, $t0, 1
            addi $t0, $t0, 1
            addi $t0, $t0, 1
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let fast = advanced.simulate(
            instructions: asm.instructions,
            mode: .scoreboard,
            scoreboardConfig: ScoreboardConfig(intUnits: 1, intLatency: 1, addFPUnits: 1, addFPLatency: 2, multFPUnits: 1, multFPLatency: 4, divFPUnits: 1, divFPLatency: 7),
            maxCycles: 500
        )
        let slow = advanced.simulate(
            instructions: asm.instructions,
            mode: .scoreboard,
            scoreboardConfig: ScoreboardConfig(intUnits: 1, intLatency: 6, addFPUnits: 1, addFPLatency: 2, multFPUnits: 1, multFPLatency: 4, divFPUnits: 1, divFPLatency: 7),
            maxCycles: 500
        )

        guard slow.totalCycles > fast.totalCycles else {
            throw ValidationError("Scoreboard no refleja cambio de latencias (fast=\(fast.totalCycles), slow=\(slow.totalCycles))")
        }
    }

    private static func testTomasuloUnitsEffect() throws {
        let assembler = AssemblerEngine()
        let advanced = AdvancedSimulationEngine()

        let source = """
        .text
        .globl main
        main:
            add.s $f0, $f1, $f2
            add.s $f3, $f4, $f5
            add.s $f6, $f7, $f8
            add.s $f9, $f10, $f11
            li $v0, 10
            syscall
        """

        let asm = try assembler.assemble(source)
        let oneUnit = advanced.simulate(
            instructions: asm.instructions,
            mode: .tomasulo,
            tomasuloConfig: TomasuloConfig(addFPUnits: 1, addFPLatency: 2, multFPUnits: 1, multFPLatency: 4, divFPUnits: 1, divFPLatency: 7, loadFPUnits: 1, loadFPLatency: 2, storeFPUnits: 1, storeFPLatency: 1)
        )
        let twoUnits = advanced.simulate(
            instructions: asm.instructions,
            mode: .tomasulo,
            tomasuloConfig: TomasuloConfig(addFPUnits: 2, addFPLatency: 2, multFPUnits: 1, multFPLatency: 4, divFPUnits: 1, divFPLatency: 7, loadFPUnits: 1, loadFPLatency: 2, storeFPUnits: 1, storeFPLatency: 1)
        )

        guard twoUnits.totalCycles < oneUnit.totalCycles else {
            throw ValidationError("Tomasulo no refleja aumento de unidades (1u=\(oneUnit.totalCycles), 2u=\(twoUnits.totalCycles))")
        }
    }

    // Referencias estables para detectar regresiones entre cambios.
    private static func testGoldenArithmeticModes() throws {
        let source = """
        .text
        .globl main
        main:
            li $t0, 1
            li $t1, 2
            add $t2, $t0, $t1
            addi $t2, $t2, 5
            li $v0, 10
            syscall
        """

        let assembler = AssemblerEngine()
        let cpu = CPUEngine()
        let advanced = AdvancedSimulationEngine()
        let asm = try assembler.assemble(source)

        let fixed = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .disabled
        )
        guard fixed.steps == 6, fixed.registers["$t2"] == 8 else {
            throw ValidationError("Golden aritmética CPU esperado steps=6,t2=8 obtenido steps=\(fixed.steps),t2=\(fixed.registers["$t2"] ?? -1)")
        }

        let segmented = advanced.simulate(instructions: asm.instructions, mode: .segmented)
        let scoreboard = advanced.simulate(instructions: asm.instructions, mode: .scoreboard)
        let tomasulo = advanced.simulate(instructions: asm.instructions, mode: .tomasulo)
        guard segmented.totalCycles == 11, scoreboard.totalCycles == 12, tomasulo.totalCycles == 14 else {
            throw ValidationError("Golden aritmética ciclos esperado SEG=11,SCB=12,TOM=14 obtenido SEG=\(segmented.totalCycles),SCB=\(scoreboard.totalCycles),TOM=\(tomasulo.totalCycles)")
        }
    }

    private static func testGoldenBranchModes() throws {
        let source = """
        .text
        .globl main
        main:
            li $t0, 0
            li $t1, 0
            beq $t0, $t1, L1
            li $t2, 99
        L1:
            li $v0, 10
            syscall
        """

        let assembler = AssemblerEngine()
        let cpu = CPUEngine()
        let advanced = AdvancedSimulationEngine()
        let asm = try assembler.assemble(source)

        let fixed = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .disabled
        )
        let delayed = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .delayed,
            ioMode: .disabled
        )
        guard fixed.steps == 5, fixed.registers["$t2"] == 0 else {
            throw ValidationError("Golden branch fijo esperado steps=5,t2=0 obtenido steps=\(fixed.steps),t2=\(fixed.registers["$t2"] ?? -1)")
        }
        guard delayed.steps == 6, delayed.registers["$t2"] == 99 else {
            throw ValidationError("Golden branch retardado esperado steps=6,t2=99 obtenido steps=\(delayed.steps),t2=\(delayed.registers["$t2"] ?? -1)")
        }

        let segmented = advanced.simulate(instructions: asm.instructions, mode: .segmented)
        let scoreboard = advanced.simulate(instructions: asm.instructions, mode: .scoreboard)
        let tomasulo = advanced.simulate(instructions: asm.instructions, mode: .tomasulo)
        guard segmented.totalCycles == 12, scoreboard.totalCycles == 12, tomasulo.totalCycles == 12 else {
            throw ValidationError("Golden branch ciclos esperado SEG=12,SCB=12,TOM=12 obtenido SEG=\(segmented.totalCycles),SCB=\(scoreboard.totalCycles),TOM=\(tomasulo.totalCycles)")
        }
    }

    private static func testGoldenMemoryModes() throws {
        let source = """
        .data
        val: .word 0

        .text
        .globl main
        main:
            li $t0, 42
            la $t1, val
            sw $t0, 0($t1)
            lw $t2, 0($t1)
            li $v0, 10
            syscall
        """

        let assembler = AssemblerEngine()
        let cpu = CPUEngine()
        let advanced = AdvancedSimulationEngine()
        let asm = try assembler.assemble(source)

        let fixed = try cpu.execute(
            program: asm.instructions,
            labels: asm.labels,
            dataEntries: asm.dataEntries,
            dataLabelAddresses: asm.dataLabelAddresses,
            branchMode: .fixed,
            ioMode: .disabled
        )
        guard fixed.steps == 6, fixed.registers["$t2"] == 42 else {
            throw ValidationError("Golden memoria CPU esperado steps=6,t2=42 obtenido steps=\(fixed.steps),t2=\(fixed.registers["$t2"] ?? -1)")
        }

        let segmented = advanced.simulate(instructions: asm.instructions, mode: .segmented)
        let scoreboard = advanced.simulate(instructions: asm.instructions, mode: .scoreboard)
        let tomasulo = advanced.simulate(instructions: asm.instructions, mode: .tomasulo)
        guard segmented.totalCycles == 11, scoreboard.totalCycles == 12, tomasulo.totalCycles == 10 else {
            throw ValidationError("Golden memoria ciclos esperado SEG=11,SCB=12,TOM=10 obtenido SEG=\(segmented.totalCycles),SCB=\(scoreboard.totalCycles),TOM=\(tomasulo.totalCycles)")
        }
    }
}

private struct ValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
