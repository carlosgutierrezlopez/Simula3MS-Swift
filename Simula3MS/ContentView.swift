import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let simulaNew = Notification.Name("simula.new")
    static let simulaOpen = Notification.Name("simula.open")
    static let simulaSave = Notification.Name("simula.save")
    static let simulaSaveAs = Notification.Name("simula.saveAs")
    static let simulaSearch = Notification.Name("simula.search")
    static let simulaGoToLine = Notification.Name("simula.goToLine")
    static let simulaAssemble = Notification.Name("simula.assemble")
    static let simulaRun = Notification.Name("simula.run")
    static let simulaHelp = Notification.Name("simula.help")
    static let simulaOpenMulticycleConfig = Notification.Name("simula.openMulticycleConfig")
    static let simulaOpenSegmentedBasicConfig = Notification.Name("simula.openSegmentedBasicConfig")
    static let simulaOpenScoreboardConfig = Notification.Name("simula.openScoreboardConfig")
    static let simulaOpenTomasuloConfig = Notification.Name("simula.openTomasuloConfig")
    static let simulaShowEditorWindow = Notification.Name("simula.showEditorWindow")
    static let simulaOpenURL = Notification.Name("simula.openURL")
}

private struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ContentView: View {
    private let brandAccent = Color(red: 0.73, green: 0.08, blue: 0.36)
    @Environment(\.colorScheme) private var colorScheme

    @State private var sourceCode: String = ""

    @Environment(SimulationSettings.self) private var settings
    @Environment(SimulationSession.self) private var simulationSession
    @Environment(\.openWindow) private var openWindow
    @AppStorage("simula3ms.language") private var languageRawValue: String = AppLanguageSelection.automatic.rawValue

    @State private var selectedLineText: String = "1"
    @State private var editorSelection: TextSelection?
    @State private var lastAssemblyResult: AssemblyResult?
    @State private var lastAssembledSource: String?

    @State private var cycleSnapshots: [CPUCycleSnapshot] = []
    @State private var currentCycleIndex: Int = -1
    @State private var executionRegisters: [String: Int] = [:]
    @State private var simulationVisible = false

    @State private var isImporterPresented = false
    @State private var currentFileURL: URL?
    @State private var isSavePanelOpen = false
    @State private var saveShortcutMonitor: Any?
    @State private var notificationObservers: [NSObjectProtocol] = []

    @State private var isSearchSheetPresented = false
    @State private var isReplaceSheetPresented = false
    @State private var isGoToLineSheetPresented = false
    @State private var isQuickGuidePresented = false
    @State private var isMulticycleConfigPresented = false
    @State private var isScoreboardConfigPresented = false
    @State private var isFunctionalUnitsConfigPresented = false
    @State private var isTomasuloConfigPresented = false
    @State private var previousDataPath: DataPath = .monocycle
    @State private var previousScheduling: SchedulingModel = .basic
    @State private var isFindNavigatorPresented = false
    @State private var hostWindow: NSWindow?
    @State private var searchTerm = ""
    @State private var replaceTerm = ""
    @State private var replacementTerm = ""

    @State private var activeAlert: AppAlert?
    @State private var errorOutputText: String = ""

    private let assembler = AssemblerEngine()
    private let cpu = CPUEngine()
    private let advancedSimulator = AdvancedSimulationEngine()

    var body: some View {
        let root = AnyView(
            VStack(spacing: 10) {
            TextEditor(text: $sourceCode, selection: $editorSelection)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(.clear)
                .padding(12)
                .frame(minHeight: 320)
                .findNavigator(isPresented: $isFindNavigatorPresented)
                .glassEffect(
                    .regular.tint(colorScheme == .dark ? .white.opacity(0.14) : .white.opacity(0.90)),
                    in: .rect(cornerRadius: 14)
                )

            HStack(spacing: 18) {
                Button(L10n.tr("button.assemble", languageSelectionRaw: languageRawValue)) {
                    assembleCode()
                }
                .buttonStyle(.glass)
                .keyboardShortcut("b", modifiers: [.command])
                .frame(minWidth: 190)

                Button(L10n.tr("button.run", languageSelectionRaw: languageRawValue)) {
                    runSimulation()
                }
                .buttonStyle(.glassProminent)
                .tint(brandAccent)
                .keyboardShortcut("r", modifiers: [.command])
                .frame(minWidth: 190)
                .disabled(!canExecute)
            }

            ScrollView {
                Text(errorOutputText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(colorScheme == .dark ? .white : .black)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .frame(minHeight: 40, maxHeight: 40)

        }
        )

        let chrome = AnyView(
            root
                .background(WindowReader { window in
                    if hostWindow !== window {
                        hostWindow = window
                    }
                })
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 8)
                .toolbar { mainToolbar }
        )

        let importing = AnyView(
            chrome.fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.plainText],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        )

        return importing
        .alert(item: $activeAlert) { model in
            Alert(
                title: Text(model.title),
                message: Text(model.message),
                dismissButton: .default(Text(L10n.tr("button.ok", languageSelectionRaw: languageRawValue)))
            )
        }
        .onAppear {
            installSaveShortcutMonitor()
            installNotificationObservers()
            previousDataPath = settings.dataPath
            previousScheduling = settings.scheduling
        }
        .onDisappear {
            removeSaveShortcutMonitor()
            removeNotificationObservers()
        }
        .onChange(of: settings.dataPath) { _, newValue in
            guard newValue != previousDataPath else { return }
            previousDataPath = newValue
            if newValue == .multicycle {
                isMulticycleConfigPresented = true
            }
            if newValue != .segmented {
                settings.scheduling = .basic
            }
        }
        .onChange(of: settings.scheduling) { _, newValue in
            guard newValue != previousScheduling else { return }
            previousScheduling = newValue
            guard settings.dataPath == .segmented else { return }
            switch newValue {
            case .basic:
                isFunctionalUnitsConfigPresented = true
            case .scoreboard:
                isScoreboardConfigPresented = true
            case .tomasulo:
                isTomasuloConfigPresented = true
            }
        }
        .sheet(isPresented: $isSearchSheetPresented) {
            NavigationStack {
                Form {
                    TextField(L10n.tr("find.placeholder", languageSelectionRaw: languageRawValue), text: $searchTerm)
                }
                .navigationTitle(L10n.tr("find.title", languageSelectionRaw: languageRawValue))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("button.cancel", languageSelectionRaw: languageRawValue)) {
                            isSearchSheetPresented = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.tr("find.title", languageSelectionRaw: languageRawValue)) {
                            runSearch()
                            isSearchSheetPresented = false
                        }
                        .disabled(searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(180)])
        }
        .sheet(isPresented: $isReplaceSheetPresented) {
            NavigationStack {
                Form {
                    TextField(L10n.tr("replace.find", languageSelectionRaw: languageRawValue), text: $replaceTerm)
                    TextField(L10n.tr("replace.with", languageSelectionRaw: languageRawValue), text: $replacementTerm)
                }
                .navigationTitle(L10n.tr("replace.title", languageSelectionRaw: languageRawValue))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.tr("button.cancel", languageSelectionRaw: languageRawValue)) {
                            isReplaceSheetPresented = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.tr("replace.apply", languageSelectionRaw: languageRawValue)) {
                            runReplace()
                            isReplaceSheetPresented = false
                        }
                        .disabled(replaceTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(220)])
        }
        .sheet(isPresented: $isGoToLineSheetPresented) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.tr("goto.title", languageSelectionRaw: languageRawValue))
                    .font(.title3.weight(.semibold))
                TextField("", text: $selectedLineText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button(L10n.tr("button.cancel", languageSelectionRaw: languageRawValue)) {
                        isGoToLineSheetPresented = false
                    }
                    Button(L10n.tr("button.go", languageSelectionRaw: languageRawValue)) {
                        runGoToLine()
                        isGoToLineSheetPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        .sheet(isPresented: $isQuickGuidePresented) {
            QuickGuideView()
                .frame(minWidth: 760, minHeight: 560)
        }
        .sheet(isPresented: $isMulticycleConfigPresented) {
            MulticycleConfigSheet(
                config: Binding(
                    get: { settings.multicycleConfig },
                    set: { settings.multicycleConfig = $0 }
                )
            )
                .frame(width: 430, height: 220)
        }
        .sheet(isPresented: $isScoreboardConfigPresented) {
            ScoreboardConfigSheet(
                config: Binding(
                    get: { settings.scoreboardConfig },
                    set: { settings.scoreboardConfig = $0 }
                )
            )
                .frame(width: 460, height: 250)
        }
        .sheet(isPresented: $isFunctionalUnitsConfigPresented) {
            FunctionalUnitsConfigSheet(
                config: Binding(
                    get: { settings.functionalUnitsConfig },
                    set: { settings.functionalUnitsConfig = $0 }
                )
            )
                .frame(minWidth: 680, minHeight: 430)
        }
        .sheet(isPresented: $isTomasuloConfigPresented) {
            TomasuloConfigSheet(
                config: Binding(
                    get: { settings.tomasuloConfig },
                    set: { settings.tomasuloConfig = $0 }
                )
            )
                .frame(width: 460, height: 300)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDroppedFileProviders(providers)
        }
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                Text(L10n.tr("toolbar.appName", languageSelectionRaw: languageRawValue))
                    .font(.title3.weight(.semibold))
                Text("•")
                    .foregroundStyle(.secondary)
                Text(currentDocumentTitle)
                    .font(.title3.weight(.regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                openWindow(id: "main-window")
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(brandAccent)
            }
            .help(L10n.tr("help.newWindow", languageSelectionRaw: languageRawValue))

            Button {
                performNew()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(brandAccent)
            }
            .help(L10n.tr("help.clear", languageSelectionRaw: languageRawValue))
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button {
                isImporterPresented = true
            } label: {
                Image(systemName: "folder")
                    .foregroundStyle(brandAccent)
            }
            .help(L10n.tr("help.open", languageSelectionRaw: languageRawValue))
            .keyboardShortcut("o", modifiers: [.command])

            Button {
                performSave()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(brandAccent)
            }
            .help(L10n.tr("help.save", languageSelectionRaw: languageRawValue))

            Button {
                presentGoToLineDialog()
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(brandAccent)
            }
            .help(L10n.tr("help.goto", languageSelectionRaw: languageRawValue))
            .keyboardShortcut("g", modifiers: [.command])
        }
    }

    private func assembleCode() {
        if sourceCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastAssemblyResult = nil
            lastAssembledSource = nil
            simulationSession.reset()
            cycleSnapshots = []
            currentCycleIndex = -1
            executionRegisters = [:]
            simulationVisible = false
            errorOutputText = L10n.tr("status.emptyFile", languageSelectionRaw: languageRawValue)
            return
        }

        do {
            let result = try assembler.assemble(sourceCode)
            lastAssemblyResult = result
            lastAssembledSource = sourceCode
            errorOutputText = "\(L10n.tr("status.assembledOk", languageSelectionRaw: languageRawValue)). \(L10n.tr("status.instructions", languageSelectionRaw: languageRawValue)): \(result.instructions.count) · \(L10n.tr("status.dataVars", languageSelectionRaw: languageRawValue)): \(result.dataEntries.count)"
            simulationSession.reset()
            cycleSnapshots = []
            currentCycleIndex = -1
            executionRegisters = [:]
            simulationVisible = false
        } catch AssemblyError.issues(let issues) {
            lastAssemblyResult = nil
            lastAssembledSource = nil
            simulationSession.reset()
            cycleSnapshots = []
            currentCycleIndex = -1
            executionRegisters = [:]
            simulationVisible = false
            let details = issues
                .map { "\(L10n.tr("status.linePrefix", languageSelectionRaw: languageRawValue)) \($0.lineNumber): \($0.message)" }
                .joined(separator: "\n")
            errorOutputText = details
        } catch {
            lastAssemblyResult = nil
            lastAssembledSource = nil
            simulationSession.reset()
            cycleSnapshots = []
            currentCycleIndex = -1
            executionRegisters = [:]
            simulationVisible = false
            errorOutputText = error.localizedDescription
        }
    }

    private func runSimulation() {
        guard canExecute, let result = lastAssemblyResult else {
            activeAlert = AppAlert(
                title: L10n.tr("alert.runUnavailable.title", languageSelectionRaw: languageRawValue),
                message: L10n.tr("alert.runUnavailable.message", languageSelectionRaw: languageRawValue)
            )
            return
        }

        do {
            let execution = try cpu.execute(
                program: result.instructions,
                labels: result.labels,
                dataEntries: result.dataEntries,
                dataLabelAddresses: result.dataLabelAddresses,
                branchMode: settings.branchPolicy.executionMode,
                ioMode: settings.ioModel.executionMode,
                inputText: settings.simulatedInputText
            )

            let advancedResult = advancedSimulator.simulate(
                instructions: result.instructions,
                mode: settings.scheduling.advancedMode,
                dataPathMode: settings.dataPath.cycleMode,
                multicycleConfig: settings.multicycleConfig,
                functionalUnitsConfig: settings.functionalUnitsConfig,
                scoreboardConfig: settings.scoreboardConfig,
                tomasuloConfig: settings.tomasuloConfig
            )

            cycleSnapshots = advancedResult.cycles
            currentCycleIndex = advancedResult.cycles.isEmpty ? -1 : 0
            executionRegisters = execution.registers
            simulationSession.cycleSnapshots = advancedResult.cycles
            simulationSession.currentCycleIndex = advancedResult.cycles.isEmpty ? -1 : 0
            simulationSession.executionRegisters = execution.registers
            simulationSession.floatingRegisters = execution.floatingRegisters
            simulationSession.dataMemoryWords = execution.dataMemoryWords
            simulationSession.textRows = execution.textRows
            simulationSession.branchOutcomeByInstructionIndex = buildBranchOutcomeMap(
                instructions: result.instructions,
                trace: execution.trace
            )
            simulationSession.documentTitle = currentDocumentTitle
            simulationSession.isPresented = true
            openWindow(id: "simulation-window")
            hostWindow?.orderOut(nil)
            simulationVisible = false
            errorOutputText = ""
        } catch {
            simulationSession.reset()
            cycleSnapshots = []
            currentCycleIndex = -1
            executionRegisters = [:]
            simulationVisible = false
            errorOutputText = error.localizedDescription
            activeAlert = AppAlert(title: L10n.tr("alert.executionError.title", languageSelectionRaw: languageRawValue), message: error.localizedDescription)
        }
    }

    private func runSearch() {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            activeAlert = AppAlert(title: L10n.tr("alert.notice.title", languageSelectionRaw: languageRawValue), message: L10n.tr("alert.searchEmpty", languageSelectionRaw: languageRawValue))
            return
        }

        let lines = sourceCode.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var matches: [Int] = []

        for (index, line) in lines.enumerated() where line.contains(term) {
            matches.append(index + 1)
        }

        if let first = matches.first {
            selectedLineText = "\(first)"
        }

        activeAlert = AppAlert(
            title: L10n.tr("alert.search.title", languageSelectionRaw: languageRawValue),
            message: "\(L10n.tr("alert.search.matchesPrefix", languageSelectionRaw: languageRawValue)): \(matches.isEmpty ? L10n.tr("alert.search.none", languageSelectionRaw: languageRawValue) : matches.map(String.init).joined(separator: ", "))"
        )
    }

    private func runReplace() {
        let from = replaceTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty else {
            activeAlert = AppAlert(title: L10n.tr("alert.notice.title", languageSelectionRaw: languageRawValue), message: L10n.tr("alert.replaceEmpty", languageSelectionRaw: languageRawValue))
            return
        }

        let previous = sourceCode
        sourceCode = sourceCode.replacingOccurrences(of: from, with: replacementTerm)
        let replacements = max(previous.components(separatedBy: from).count - 1, 0)

        lastAssemblyResult = nil
        lastAssembledSource = nil
        cycleSnapshots = []
        currentCycleIndex = -1
        executionRegisters = [:]
        simulationVisible = false

        activeAlert = AppAlert(title: L10n.tr("alert.replace.title", languageSelectionRaw: languageRawValue), message: "\(L10n.tr("alert.replace.donePrefix", languageSelectionRaw: languageRawValue)): \(replacements)")
    }

    private func runGoToLine() {
        let lines = sourceCode.split(separator: "\n", omittingEmptySubsequences: false)
        guard let lineNumber = Int(selectedLineText), lineNumber >= 1, lineNumber <= max(lines.count, 1) else {
            activeAlert = AppAlert(title: L10n.tr("goto.title", languageSelectionRaw: languageRawValue), message: "\(L10n.tr("alert.goto.invalid", languageSelectionRaw: languageRawValue)): 1...\(max(lines.count, 1))")
            return
        }
        var index = sourceCode.startIndex
        var currentLine = 1
        while currentLine < lineNumber, index < sourceCode.endIndex {
            if sourceCode[index] == "\n" {
                currentLine += 1
            }
            index = sourceCode.index(after: index)
        }
        editorSelection = TextSelection(insertionPoint: index)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let fileURL = try result.get().first else { return }
            loadSource(from: fileURL)
        } catch {
            activeAlert = AppAlert(title: L10n.tr("alert.fileError.title", languageSelectionRaw: languageRawValue), message: "\(L10n.tr("alert.fileOpenError", languageSelectionRaw: languageRawValue)): \(error.localizedDescription)")
        }
    }

    private func handleDroppedFileProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }

        _ = provider.loadObject(ofClass: URL.self) { item, _ in
            guard let url = item else { return }
            Task { @MainActor in
                loadSource(from: url)
                hostWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        return true
    }

    private func loadSource(from fileURL: URL) {
        do {
            let hasAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: fileURL)
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            guard let text else {
                activeAlert = AppAlert(title: L10n.tr("alert.fileError.title", languageSelectionRaw: languageRawValue), message: L10n.tr("alert.fileEncoding", languageSelectionRaw: languageRawValue))
                return
            }

            sourceCode = text
            currentFileURL = fileURL
            selectedLineText = "1"
            lastAssemblyResult = nil
            lastAssembledSource = nil
            cycleSnapshots = []
            currentCycleIndex = -1
            executionRegisters = [:]
            simulationVisible = false
        } catch {
            activeAlert = AppAlert(title: L10n.tr("alert.fileError.title", languageSelectionRaw: languageRawValue), message: "\(L10n.tr("alert.fileOpenError", languageSelectionRaw: languageRawValue)): \(error.localizedDescription)")
        }
    }

    private func performSave() {
        if let fileURL = currentFileURL {
            writeSource(to: fileURL)
            return
        }

        performSaveAs()
    }

    private func performSaveAs() {
        guard !isSavePanelOpen else { return }
        isSavePanelOpen = true

        let panel = NSSavePanel()
        panel.title = L10n.tr("panel.saveTitle", languageSelectionRaw: languageRawValue)
        panel.nameFieldStringValue = suggestedSaveFilename
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [ASMSourceDocument.asmSourceType]
        panel.isExtensionHidden = false
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else {
            isSavePanelOpen = false
            activeAlert = AppAlert(
                title: L10n.tr("alert.fileError.title", languageSelectionRaw: languageRawValue),
                message: L10n.tr("alert.noActiveWindow", languageSelectionRaw: languageRawValue)
            )
            return
        }

        panel.beginSheetModal(for: window) { response in
            self.isSavePanelOpen = false
            guard response == .OK, let fileURL = panel.url else { return }
            self.writeSource(to: fileURL)
            self.currentFileURL = fileURL
        }
    }

    private var suggestedSaveFilename: String {
        if let fileURL = currentFileURL {
            let fileName = fileURL.lastPathComponent
            if fileName.lowercased().hasSuffix(".s") {
                return fileName
            }
            return fileURL.deletingPathExtension().lastPathComponent + ".s"
        }
        return "untitled.s"
    }

    private func writeSource(to fileURL: URL) {
        let hasAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try sourceCode.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            activeAlert = AppAlert(title: L10n.tr("alert.fileError.title", languageSelectionRaw: languageRawValue), message: "\(L10n.tr("alert.fileSaveError", languageSelectionRaw: languageRawValue)): \(error.localizedDescription)")
        }
    }

    private func performNew() {
        sourceCode = ""
        lastAssemblyResult = nil
        lastAssembledSource = nil
        simulationSession.reset()
        currentFileURL = nil
        cycleSnapshots = []
        currentCycleIndex = -1
        executionRegisters = [:]
        simulationVisible = false
        errorOutputText = ""
    }

    private func installSaveShortcutMonitor() {
        guard saveShortcutMonitor == nil else { return }
        saveShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return event }

            guard key == "s" else { return event }

            if modifiers == [.command] {
                performSave()
                return nil
            }

            if modifiers == [.command, .shift] {
                performSaveAs()
                return nil
            }

            return event
        }
    }

    private func removeSaveShortcutMonitor() {
        guard let monitor = saveShortcutMonitor else { return }
        NSEvent.removeMonitor(monitor)
        saveShortcutMonitor = nil
    }

    private func installNotificationObservers() {
        guard notificationObservers.isEmpty else { return }
        let center = NotificationCenter.default

        notificationObservers.append(center.addObserver(forName: .simulaSave, object: nil, queue: .main) { _ in
            performSave()
        })
        notificationObservers.append(center.addObserver(forName: .simulaSaveAs, object: nil, queue: .main) { _ in
            performSaveAs()
        })
        notificationObservers.append(center.addObserver(forName: .simulaNew, object: nil, queue: .main) { _ in
            performNew()
        })
        notificationObservers.append(center.addObserver(forName: .simulaOpen, object: nil, queue: .main) { _ in
            isImporterPresented = true
        })
        notificationObservers.append(center.addObserver(forName: .simulaOpenURL, object: nil, queue: .main) { notification in
            guard let url = notification.object as? URL else { return }
            let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            if let targetWindow, hostWindow !== targetWindow, NSApp.windows.count > 1 {
                return
            }
            loadSource(from: url)
            hostWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        })
        notificationObservers.append(center.addObserver(forName: .simulaSearch, object: nil, queue: .main) { _ in
            guard hostWindow === NSApp.keyWindow else { return }
            isFindNavigatorPresented = true
        })
        notificationObservers.append(center.addObserver(forName: .simulaGoToLine, object: nil, queue: .main) { _ in
            presentGoToLineDialog()
        })
        notificationObservers.append(center.addObserver(forName: .simulaAssemble, object: nil, queue: .main) { _ in
            assembleCode()
        })
        notificationObservers.append(center.addObserver(forName: .simulaRun, object: nil, queue: .main) { _ in
            runSimulation()
        })
        notificationObservers.append(center.addObserver(forName: .simulaHelp, object: nil, queue: .main) { _ in
            isQuickGuidePresented = true
        })
        notificationObservers.append(center.addObserver(forName: .simulaOpenMulticycleConfig, object: nil, queue: .main) { _ in
            isMulticycleConfigPresented = true
        })
        notificationObservers.append(center.addObserver(forName: .simulaOpenSegmentedBasicConfig, object: nil, queue: .main) { _ in
            isFunctionalUnitsConfigPresented = true
        })
        notificationObservers.append(center.addObserver(forName: .simulaOpenScoreboardConfig, object: nil, queue: .main) { _ in
            isScoreboardConfigPresented = true
        })
        notificationObservers.append(center.addObserver(forName: .simulaOpenTomasuloConfig, object: nil, queue: .main) { _ in
            isTomasuloConfigPresented = true
        })
        notificationObservers.append(center.addObserver(forName: .simulaShowEditorWindow, object: nil, queue: .main) { _ in
            hostWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        })
    }

    private func removeNotificationObservers() {
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func presentGoToLineDialog() {
        isGoToLineSheetPresented = true
    }

    private func stepForward() {
        guard !cycleSnapshots.isEmpty else { return }
        currentCycleIndex = min(currentCycleIndex + 1, cycleSnapshots.count - 1)
    }

    private func stepBackward() {
        guard !cycleSnapshots.isEmpty else { return }
        currentCycleIndex = max(currentCycleIndex - 1, 0)
    }

    private var currentCycleDescription: String {
        guard currentCycleIndex >= 0, currentCycleIndex < cycleSnapshots.count else {
            return L10n.tr("sim.noCycleSelected", languageSelectionRaw: languageRawValue)
        }

        let cycle = cycleSnapshots[currentCycleIndex]
        return """
        \(L10n.tr("sim.cycle", languageSelectionRaw: languageRawValue)): \(cycle.cycle)
        PC: \(cycle.pcBefore) -> \(cycle.pcAfter)
        \(L10n.tr("sim.instructionShort", languageSelectionRaw: languageRawValue)): \(cycle.instruction)
        """
    }

    private var registerSummaryText: String {
        if currentCycleIndex >= 0, currentCycleIndex < cycleSnapshots.count {
            let cycle = cycleSnapshots[currentCycleIndex]
            return """
            $t0=\(cycle.t0)    $t1=\(cycle.t1)    $t2=\(cycle.t2)
            $s0=\(cycle.s0)    $s1=\(cycle.s1)
            $hi=\(cycle.hi)    $lo=\(cycle.lo)
            """
        }

        let keys = ["$t0", "$t1", "$t2", "$s0", "$s1", "$v0", "$a0", "$hi", "$lo"]
        return keys.map { "\($0)=\(executionRegisters[$0] ?? 0)" }.joined(separator: "   ")
    }

    private var cycleTableText: String {
        guard !cycleSnapshots.isEmpty else {
            return L10n.tr("sim.noExecutionYet", languageSelectionRaw: languageRawValue)
        }

        func fixed(_ text: String, _ width: Int) -> String {
            if text.count >= width {
                return String(text.prefix(width))
            }
            return text + String(repeating: " ", count: width - text.count)
        }

        let header = " " + [
            fixed("CIC", 4),
            fixed("PC_IN", 7),
            fixed("PC_OUT", 8),
            fixed("INSTR", 28),
            fixed("T0", 7),
            fixed("T1", 7),
            fixed("T2", 7)
        ].joined()

        let rows = Array(cycleSnapshots.prefix(160)).enumerated().map { index, cycle in
            let prefix = (index == currentCycleIndex) ? ">" : " "
            return prefix + [
                fixed("\(cycle.cycle)", 4),
                fixed("\(cycle.pcBefore)", 7),
                fixed("\(cycle.pcAfter)", 8),
                fixed(cycle.instruction, 28),
                fixed("\(cycle.t0)", 7),
                fixed("\(cycle.t1)", 7),
                fixed("\(cycle.t2)", 7)
            ].joined()
        }

        return ([header] + rows).joined(separator: "\n")
    }

    private var currentDocumentTitle: String {
        currentFileURL?.lastPathComponent ?? "untitled"
    }

    private var canExecute: Bool {
        guard lastAssemblyResult != nil else { return false }
        return lastAssembledSource == sourceCode
    }

    private func buildBranchOutcomeMap(
        instructions: [AssembledInstruction],
        trace: [String]
    ) -> [Int: Bool] {
        let branchMnemonics: Set<String> = ["beq", "bne", "bc1t", "bc1f"]
        var lineOutcome: [Int: Bool] = [:]

        for line in trace {
            guard let lRange = line.range(of: "L"),
                  let colon = line[lRange.upperBound...].firstIndex(of: ":"),
                  let lineNumber = Int(line[lRange.upperBound..<colon]) else {
                continue
            }

            if line.contains(" no tomado") {
                lineOutcome[lineNumber] = false
            } else if line.contains(" tomado") {
                lineOutcome[lineNumber] = true
            }
        }

        var map: [Int: Bool] = [:]
        for (idx, instruction) in instructions.enumerated() {
            guard branchMnemonics.contains(instruction.mnemonic),
                  let taken = lineOutcome[instruction.lineNumber] else {
                continue
            }
            map[idx + 1] = taken
        }

        return map
    }

}

private struct QuickGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("simula3ms.language") private var languageRawValue: String = AppLanguageSelection.automatic.rawValue

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(guideText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
            }
            .navigationTitle(L10n.tr("guide.title", languageSelectionRaw: languageRawValue))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("guide.close", languageSelectionRaw: languageRawValue)) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var guideText: String {
        switch (AppLanguageSelection(rawValue: languageRawValue) ?? .automatic).languageCode {
        case "en":
            return """
            This guide summarizes the basic steps to start working with Simula3MS.

            1. Once the Simula3MS window is open, there are two options:
            • Load a file that was previously edited.
            • Edit new code in assembly language.

            2. After editing or loading the file, the next step is to assemble it by pressing the Assemble button. From here there are two possible outcomes:
            • If the code has no syntax errors, the Run button is enabled to open the simulation window.
            • If the code is not correct, the bottom area of the window shows the full error list and the first one appears highlighted. After fixing errors, press Assemble again and repeat step 2.

            3. Choose the execution configuration. There are three options in the Settings menu: Input/Output, Datapath, and branch techniques.
            • Input/Output. I/O is disabled by default. You can choose polling I/O or interrupt-based I/O.
            • Datapath. The default option is Single-cycle. If you select Multi-cycle or any pipelined option, a new window opens to configure floating-point operation latency.
            • Branch techniques. Simula3MS currently allows two branch techniques: delayed branch and fixed branch. Both are disabled by default, and enabling either one implies basic pipelining.

            4. Pressing Run opens the simulation window. There you can see full program execution (Run button), or inspect instruction-by-instruction execution cycle by cycle (Next cycle / Previous cycle buttons).
            """
        case "gl":
            return """
            Esta guía resume os pasos básicos para comezar a traballar con Simula3MS.

            1. Unha vez aberta a ventá de Simula3MS, hai dúas opcións:
            • Cargar un ficheiro editado con anterioridade.
            • Editar novo código en linguaxe ensambladora.

            2. Unha vez editado ou cargado o ficheiro, o seguinte paso é ensamblalo premendo en Ensamblar. A partir de aquí hai dous posibles resultados:
            • Se o código non ten erros sintácticos, activarase Executar para acceder á ventá de simulación.
            • Se o código non é correcto, na parte inferior aparecerá a lista de erros e o primeiro quedará remarcado. Unha vez corrixidos, prémanse de novo Ensamblar e repítese o paso 2.

            3. Escoller a configuración para executar o código. Hai tres opcións no menú Configuración: Entrada/Saída, Camiño de datos e técnicas de salto.
            • Entrada/Saída. A E/S aparece desactivada por defecto. Pódese escoller entre E/S con enquisa ou E/S con interrupcións.
            • Camiño de datos. A opción por defecto é Monociclo. Se se escolle Multiciclo ou calquera opción segmentada, ábrese unha nova ventá para configurar a latencia das operacións en punto flotante.
            • Técnicas de salto. Simula3MS permite seleccionar salto retardado e salto fixo. Ambas técnicas aparecen desactivadas por defecto, e activar calquera delas implica segmentación básica.

            4. Premendo Executar accédese á ventá de simulación. Nela móstrase a execución completa do programa (Executar), ou a execución de cada instrución en cada ciclo (Ciclo seguinte / Ciclo anterior).
            """
        default:
            return """
        Esta guía resume los pasos básicos para empezar a trabajar con Simula3MS.

        1. Una vez abierta la ventana de Simula3MS, hay dos opciones:
        • Cargar un fichero que haya sido editado con anterioridad.
        • Editar un nuevo código en lenguaje ensamblador.

        2. Una vez editado o cargado el fichero, el siguiente paso es ensamblarlo. Para ello, hay que pulsar el botón Ensamblar. A partir de aquí hay dos posibles resultados:
        • Si el código que queremos ejecutar no tiene errores sintácticos, se activará el botón Ejecutar, que permite acceder a la ventana de simulación.
        • En caso de que el código no sea correcto, en la parte inferior de la ventana aparecerá un listado con todos los errores y el primero de ellos aparecerá remarcado. Se puede acceder a los siguientes, en caso de que los hubiera, por medio del botón Error siguiente. Una vez corregidos estos fallos, se vuelve a pulsar el botón Ensamblar y se repite el paso 2.

        3. Escoger la configuración para ejecutar el código. Hay tres posibles opciones en el menú Configuración: Entrada/Salida, Camino de datos y técnicas de salto.
        • Entrada/Salida. La E/S aparece desactivada por defecto. Se puede escoger entre E/S con encuesta o E/S con interrupciones.
        • Camino de datos. La opción seleccionada por defecto es Monociclo. Si se selecciona Multiciclo o cualquier otra opción de la implementación segmentada, se abre una ventana nueva que permite configurar la latencia de las operaciones en punto flotante.
        • Técnicas de salto. Actualmente, Simula3MS permite la selección de dos técnicas de salto: salto retardado y salto fijo. Ambas técnicas aparecen desactivadas por defecto, y la selección de cualquiera de ellas implica segmentación básica.

        4. Pulsando el botón Ejecutar se accede a la ventana de simulación. En esta ventana se muestra el resultado de la ejecución completa del programa (con el botón Ejecutar), o se puede ver la ejecución de cada instrucción en cada ciclo (con los botones Ciclo siguiente y Ciclo anterior).
        """
        }
    }
}

private struct WindowReader: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

@Observable
final class SimulationSession {
    var cycleSnapshots: [CPUCycleSnapshot] = []
    var currentCycleIndex: Int = -1
    var executionRegisters: [String: Int] = [:]
    var floatingRegisters: [String: UInt32] = [:]
    var dataMemoryWords: [MemoryWord] = []
    var textRows: [TextRow] = []
    var branchOutcomeByInstructionIndex: [Int: Bool] = [:]
    var documentTitle: String = "untitled"
    var isPresented: Bool = false

    func reset() {
        cycleSnapshots = []
        currentCycleIndex = -1
        executionRegisters = [:]
        floatingRegisters = [:]
        dataMemoryWords = []
        textRows = []
        branchOutcomeByInstructionIndex = [:]
        documentTitle = "untitled"
        isPresented = false
    }
}

struct SimulationWindowView: View {
    private let brandAccent = Color(red: 0.73, green: 0.08, blue: 0.36)
    @Environment(SimulationSettings.self) private var settings
    @Environment(SimulationSession.self) private var simulationSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("simula3ms.language") private var languageRawValue: String = AppLanguageSelection.automatic.rawValue
    @State private var breakpointEnabled = false
    @State private var breakpointText = "0x00400000"
    @State private var breakpointHitMessage: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(String(format: L10n.tr("sim.modeHeader", languageSelectionRaw: languageRawValue), settings.dataPath.localizedTitle(languageSelectionRaw: languageRawValue)))
                    .font(.headline.weight(.regular))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(simulationSession.documentTitle)
                    .font(.headline.weight(.regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
                Button(L10n.tr("sim.backToEditor", languageSelectionRaw: languageRawValue)) {
                    simulationSession.isPresented = false
                    NotificationCenter.default.post(name: .simulaShowEditorWindow, object: nil)
                    dismiss()
                }
                .buttonStyle(.glass)
                .tint(brandAccent)
            }

            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.tr("sim.registers", languageSelectionRaw: languageRawValue))
                            .font(.headline)
                        Text(cp0RegistersText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)

                        Divider()

                        Text(L10n.tr("sim.generalRegisters", languageSelectionRaw: languageRawValue))
                            .font(.headline)
                        Text(generalRegistersText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)

                        Divider()

                        Text(L10n.tr("sim.fpRegisters", languageSelectionRaw: languageRawValue))
                            .font(.headline)
                        Text(floatingRegistersText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(maxWidth: 380, minHeight: 460, maxHeight: 460)
                .glassEffect(in: .rect(cornerRadius: 14))

                if let mapName = activePipelineDiagramName {
                    FrameDrivenGIFView(
                        resourceName: mapName,
                        frameIndex: max(simulationSession.currentCycleIndex, 0)
                    )
                        .frame(maxWidth: .infinity, minHeight: 460, maxHeight: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(.tertiary, lineWidth: 1)
                        )
                        .overlay(alignment: .topTrailing) {
                            Text(currentCycleBadgeText)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                                .padding(10)
                        }
                        .overlay(alignment: .bottomLeading) {
                            if let snapshot = currentSnapshot {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(snapshot.instruction)
                                        .font(.caption2.monospaced())
                                        .lineLimit(2)

                                    if !pipelineStageChips.isEmpty {
                                        HStack(spacing: 6) {
                                            ForEach(pipelineStageChips, id: \.name) { chip in
                                                HStack(spacing: 4) {
                                                    Text(chip.name)
                                                        .font(.caption2.weight(.semibold))
                                                    Text(chip.value)
                                                        .font(.caption2.monospaced())
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(
                                                    chip.isActive ?
                                                        AnyShapeStyle(brandAccent.opacity(0.75)) :
                                                        AnyShapeStyle(.thinMaterial),
                                                    in: Capsule()
                                                )
                                                .foregroundStyle(chip.isActive ? Color.white : Color.primary)
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .padding(10)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if simulationSession.cycleSnapshots.count > 1 {
                                GeometryReader { proxy in
                                    let total = max(simulationSession.cycleSnapshots.count - 1, 1)
                                    let progress = CGFloat(max(simulationSession.currentCycleIndex, 0)) / CGFloat(total)
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(.ultraThinMaterial)
                                        Capsule()
                                            .fill(brandAccent.opacity(0.85))
                                            .frame(width: max(10, proxy.size.width * progress))
                                    }
                                }
                                .frame(width: 180, height: 8)
                                .padding(12)
                            }
                        }
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.tertiary, lineWidth: 1)
                        .overlay {
                            Text(L10n.tr("sim.mapMissing", languageSelectionRaw: languageRawValue))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 460, maxHeight: 460)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("sim.dataSegment", languageSelectionRaw: languageRawValue))
                        .font(.headline)

                    ScrollView {
                        Text(dataSegmentText)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 170, maxHeight: 210)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .glassEffect(in: .rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("sim.textSegment", languageSelectionRaw: languageRawValue))
                        .font(.headline)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(simulationSession.textRows) { row in
                                let isCurrent = currentCyclePC == row.address
                                Text(formattedTextRow(row))
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isCurrent ? brandAccent.opacity(0.55) : Color.clear)
                                    )
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(minHeight: 170, maxHeight: 210)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .glassEffect(in: .rect(cornerRadius: 14))
            }

            HStack(spacing: 10) {
                Button {
                    stepInstructionBackward()
                } label: {
                    Label(L10n.tr("sim.stepPrev", languageSelectionRaw: languageRawValue), systemImage: "backward.end.fill")
                }
                .buttonStyle(.glass)
                .disabled(simulationSession.currentCycleIndex <= 0)

                Button {
                    stepInstructionForward()
                } label: {
                    Label(L10n.tr("sim.stepNext", languageSelectionRaw: languageRawValue), systemImage: "forward.end.fill")
                }
                .buttonStyle(.glass)
                .disabled(simulationSession.cycleSnapshots.isEmpty || simulationSession.currentCycleIndex >= simulationSession.cycleSnapshots.count - 1)

                Button {
                    stepCycleBackward()
                } label: {
                    Label(L10n.tr("sim.cyclePrev", languageSelectionRaw: languageRawValue), systemImage: "backward.fill")
                }
                .buttonStyle(.glass)
                .disabled(simulationSession.currentCycleIndex <= 0)

                Button {
                    stepCycleForward()
                } label: {
                    Label(L10n.tr("sim.cycleNext", languageSelectionRaw: languageRawValue), systemImage: "forward.fill")
                }
                .buttonStyle(.glass)
                .disabled(simulationSession.cycleSnapshots.isEmpty || simulationSession.currentCycleIndex >= simulationSession.cycleSnapshots.count - 1)

                Button {
                    runUntilStop()
                } label: {
                    Label(L10n.tr("button.run", languageSelectionRaw: languageRawValue), systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(brandAccent)
                .disabled(simulationSession.cycleSnapshots.isEmpty || simulationSession.currentCycleIndex >= simulationSession.cycleSnapshots.count - 1)

                Spacer()

                Toggle(L10n.tr("sim.breakpoint", languageSelectionRaw: languageRawValue), isOn: $breakpointEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Text(L10n.tr("sim.breakpoint", languageSelectionRaw: languageRawValue))
                    .foregroundStyle(.secondary)
                TextField("0x00400000", text: $breakpointText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.subheadline, design: .monospaced))
                    .frame(width: 120)

                Text("\(L10n.tr("sim.cycle", languageSelectionRaw: languageRawValue)) \(max(simulationSession.currentCycleIndex + 1, 0))/\(simulationSession.cycleSnapshots.count)")
                    .font(.headline)
            }

            if let message = breakpointHitMessage {
                Text(message)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
        .onDisappear {
            simulationSession.isPresented = false
            NotificationCenter.default.post(name: .simulaShowEditorWindow, object: nil)
        }
    }

    private func stepCycleForward() {
        guard !simulationSession.cycleSnapshots.isEmpty else { return }
        let next = min(simulationSession.currentCycleIndex + 1, simulationSession.cycleSnapshots.count - 1)
        moveForward(to: next)
    }

    private func stepCycleBackward() {
        guard !simulationSession.cycleSnapshots.isEmpty else { return }
        simulationSession.currentCycleIndex = max(simulationSession.currentCycleIndex - 1, 0)
    }

    private func stepInstructionForward() {
        let cycles = simulationSession.cycleSnapshots
        let i = simulationSession.currentCycleIndex
        guard i >= 0, i < cycles.count else { return }
        let anchor = instructionKey(for: cycles[i])
        guard let j = cycles.indices.first(where: { $0 > i && instructionKey(for: cycles[$0]) != anchor }) else {
            moveForward(to: cycles.count - 1)
            return
        }
        moveForward(to: j)
    }

    private func stepInstructionBackward() {
        let cycles = simulationSession.cycleSnapshots
        let i = simulationSession.currentCycleIndex
        guard i > 0, i < cycles.count else {
            simulationSession.currentCycleIndex = 0
            return
        }

        let anchor = instructionKey(for: cycles[i])
        guard let j = cycles.indices.reversed().first(where: { $0 < i && instructionKey(for: cycles[$0]) != anchor }) else {
            simulationSession.currentCycleIndex = 0
            return
        }

        let targetKey = instructionKey(for: cycles[j])
        var start = j
        while start > 0, instructionKey(for: cycles[start - 1]) == targetKey {
            start -= 1
        }
        simulationSession.currentCycleIndex = start
    }

    private func runUntilStop() {
        guard !simulationSession.cycleSnapshots.isEmpty else { return }
        let start = simulationSession.currentCycleIndex
        let end = simulationSession.cycleSnapshots.count - 1
        moveForward(to: end, fromIndex: start)
    }

    private func moveForward(to targetIndex: Int, fromIndex: Int? = nil) {
        let old = fromIndex ?? simulationSession.currentCycleIndex
        guard targetIndex >= old else {
            simulationSession.currentCycleIndex = max(targetIndex, 0)
            breakpointHitMessage = nil
            return
        }

        let finalIndex = indexStoppingAtBreakpoint(from: old, to: targetIndex)
        simulationSession.currentCycleIndex = finalIndex
    }

    private func indexStoppingAtBreakpoint(from oldIndex: Int, to targetIndex: Int) -> Int {
        guard breakpointEnabled,
              let address = parsedBreakpointAddress else {
            breakpointHitMessage = nil
            return targetIndex
        }

        guard !simulationSession.cycleSnapshots.isEmpty else {
            breakpointHitMessage = nil
            return targetIndex
        }

        let lower = max(oldIndex + 1, 0)
        let upper = min(targetIndex, simulationSession.cycleSnapshots.count - 1)
        guard lower <= upper else {
            breakpointHitMessage = nil
            return targetIndex
        }

        for idx in lower...upper {
            if pcAddress(for: simulationSession.cycleSnapshots[idx]) == address {
                breakpointHitMessage = "\(L10n.tr("sim.breakpointStopped", languageSelectionRaw: languageRawValue)) \(String(format: "0x%08X", address)) (\(L10n.tr("sim.cycle", languageSelectionRaw: languageRawValue).lowercased()) \(simulationSession.cycleSnapshots[idx].cycle))"
                return idx
            }
        }

        breakpointHitMessage = nil
        return targetIndex
    }

    private func instructionKey(for cycle: CPUCycleSnapshot) -> String {
        // "Paso" avanza por instrucción (PC), no por variaciones de texto del ciclo.
        "\(cycle.pcBefore)"
    }

    private var currentCycleDescription: String {
        guard simulationSession.currentCycleIndex >= 0, simulationSession.currentCycleIndex < simulationSession.cycleSnapshots.count else {
            return L10n.tr("sim.noCycleSelected", languageSelectionRaw: languageRawValue)
        }

        let cycle = simulationSession.cycleSnapshots[simulationSession.currentCycleIndex]
        return """
        Ciclo: \(cycle.cycle)
        PC: \(cycle.pcBefore) -> \(cycle.pcAfter)
        Instr: \(cycle.instruction)
        """
    }

    private var cp0RegistersText: String {
        func hex32(_ value: Int) -> String {
            String(format: "0x%08X", UInt32(bitPattern: Int32(truncatingIfNeeded: value)))
        }

        func row(_ keys: [String]) -> String {
            keys.map { key in
                "\(key)=\(hex32(registerValue(for: key)))"
            }.joined(separator: "   ")
        }

        return [
            row(["$pc", "$epc", "$cause"]),
            row(["$status", "$badvaddr", "$hi", "$lo"])
        ].joined(separator: "\n")
    }

    private var generalRegistersText: String {
        func hex32(_ value: Int) -> String {
            String(format: "0x%08X", UInt32(bitPattern: Int32(truncatingIfNeeded: value)))
        }

        func row(_ keys: [String]) -> String {
            keys.map { key in
                "\(key)=\(hex32(registerValue(for: key)))"
            }.joined(separator: "   ")
        }

        let generalRows = [
            row(["$zero", "$at", "$v0", "$v1"]),
            row(["$a0", "$a1", "$a2", "$a3"]),
            row(["$t0", "$t1", "$t2", "$t3"]),
            row(["$t4", "$t5", "$t6", "$t7"]),
            row(["$t8", "$t9", "$s0", "$s1"]),
            row(["$s2", "$s3", "$s4", "$s5"]),
            row(["$s6", "$s7", "$k0", "$k1"]),
            row(["$gp", "$sp", "$fp", "$ra"])
        ]

        return generalRows.joined(separator: "\n")
    }

    private var floatingRegistersText: String {
        let fpRows = stride(from: 0, through: 28, by: 4).map { start in
            (start..<(start + 4)).map { index -> String in
                let key = "$f\(index)"
                let bits = simulationSession.floatingRegisters[key] ?? 0
                return "\(key)=\(String(format: "0x%08X", bits))"
            }.joined(separator: "   ")
        }

        return fpRows.joined(separator: "\n")
    }

    private var dataSegmentText: String {
        guard !simulationSession.dataMemoryWords.isEmpty else {
            return L10n.tr("sim.noMemoryData", languageSelectionRaw: languageRawValue)
        }
        let rows = stride(from: 0, to: simulationSession.dataMemoryWords.count, by: 4).map { start in
            let slice = simulationSession.dataMemoryWords[start..<min(start + 4, simulationSession.dataMemoryWords.count)]
            return slice.map { word in
                String(format: "[0x%08X] 0x%08X", word.address, UInt32(bitPattern: Int32(truncatingIfNeeded: word.value)))
            }.joined(separator: "   ")
        }

        return """
        MEMORIA
        \(rows.joined(separator: "\n"))

        PILA
        [0x70000000]
        """
    }

    private var textSegmentText: String {
        guard !simulationSession.textRows.isEmpty else {
            return L10n.tr("sim.noInstructions", languageSelectionRaw: languageRawValue)
        }

        let currentPC = currentCyclePC
        return simulationSession.textRows.map { row in
            let marker = (currentPC != nil && row.address == currentPC) ? "▶ " : "  "
            return marker + String(
                format: "[0x%08X] 0x%08X   %@",
                row.address,
                UInt32(bitPattern: Int32(truncatingIfNeeded: row.machineCode)),
                row.instruction
            )
        }.joined(separator: "\n")
    }

    private struct ActiveStageState {
        let stage: Int
        let stageName: String
        let instructionIndex: Int
        let mnemonic: String
    }

    private var activePipelineDiagramName: String? {
        let stageState = currentActiveStageState
        let mnemonic = stageState?.mnemonic ?? currentInstructionMnemonic
        let stage = stageState?.stage ?? max(1, (simulationSession.currentCycleIndex % 5) + 1)
        let snapshot = currentSnapshot

        let candidate: String
        switch settings.dataPath {
        case .monocycle:
            candidate = monocycleDiagramName(for: mnemonic)
        case .multicycle:
            candidate = multicycleDiagramName(for: mnemonic, stage: stage)
        case .segmented:
            if let snapshot,
               let forwarding = segmentedForwardingDiagramName(snapshot: snapshot),
               resourceExists(named: forwarding) {
                candidate = forwarding
            } else if let snapshot,
                      let instructionIndex = stageState?.instructionIndex,
                      let hazardDriven = segmentedHazardDiagramName(snapshot: snapshot, mnemonic: mnemonic, stage: stage),
                      resourceExists(named: hazardDriven) {
                candidate = segmentedControlOutcomeAdjustedDiagram(
                    hazardDiagram: hazardDriven,
                    mnemonic: mnemonic,
                    stage: stage,
                    instructionIndex: instructionIndex
                ) ?? hazardDriven
            } else {
                candidate = segmentedInstructionDiagramName(for: mnemonic, stage: stage)
            }
        }

        if resourceExists(named: candidate) {
            return candidate
        }
        if settings.dataPath == .segmented {
            if resourceExists(named: "segmentado") {
                return "segmentado"
            }
            if resourceExists(named: "caminodatos") {
                return "caminodatos"
            }
        }
        if settings.dataPath == .multicycle, resourceExists(named: "multiciclo") {
            return "multiciclo"
        }
        if settings.dataPath == .monocycle, resourceExists(named: "monociclo") {
            return "monociclo"
        }
        return resourceExists(named: "caminodatos") ? "caminodatos" : nil
    }

    private var currentInstructionMnemonic: String {
        guard let address = currentCyclePC,
              let row = simulationSession.textRows.first(where: { $0.address == address }) else {
            return ""
        }
        return normalizedMnemonic(from: row.instruction)
    }

    private var currentActiveStageState: ActiveStageState? {
        guard let snapshot = currentSnapshot,
              snapshot.instruction.hasPrefix("SEG ") else {
            return nil
        }

        let stageOrder: [(String, Int)] = [("WB", 5), ("MEM", 4), ("EX", 3), ("ID", 2), ("IF", 1)]
        for (stageName, stageNumber) in stageOrder {
            if let index = segmentedInstructionIndex(in: snapshot.instruction, stage: stageName),
               let mnemonic = mnemonicForInstruction(index: index) {
                return ActiveStageState(stage: stageNumber, stageName: stageName, instructionIndex: index, mnemonic: mnemonic)
            }
        }

        return nil
    }

    private func segmentedInstructionIndex(in summary: String, stage: String) -> Int? {
        let key = "\(stage):I"
        guard let range = summary.range(of: key) else { return nil }
        var digits = ""
        var idx = range.upperBound
        while idx < summary.endIndex {
            let ch = summary[idx]
            if ch.isNumber {
                digits.append(ch)
                idx = summary.index(after: idx)
            } else {
                break
            }
        }
        return Int(digits)
    }

    private func mnemonicForInstruction(index: Int) -> String? {
        guard index > 0, index <= simulationSession.textRows.count else { return nil }
        return normalizedMnemonic(from: simulationSession.textRows[index - 1].instruction)
    }

    private func normalizedMnemonic(from instructionText: String) -> String {
        instructionText
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map { String($0).lowercased() } ?? ""
    }

    private func monocycleDiagramName(for mnemonic: String) -> String {
        switch mnemonic {
        case "lw": return "lw"
        case "sw": return "sw"
        case "lwc1": return "lwc1"
        case "swc1": return "swc1"
        case "beq", "bne": return "beq"
        case "bc1t", "bc1f": return "bc1t"
        case "jr": return "jr"
        case "j", "jump": return "jump"
        case "jal": return "jal"
        case "ceq.s", "c.eq.s", "ceq": return "ceq"
        case "mov.s", "mov": return "mov"
        case "neg.s", "neg": return "neg"
        case "add.s", "sub.s", "mul.s", "div.s": return "r_flot"
        case "addi", "addiu", "andi", "ori", "xori", "slti", "lui": return "inmed"
        case "": return "monociclo"
        default: return "r"
        }
    }

    private func multicycleDiagramName(for mnemonic: String, stage: Int) -> String {
        switch stage {
        case 1:
            return isFloatingMnemonic(mnemonic) ? "etapa1f" : "etapa1"
        case 2:
            if isConditionalBranchMnemonic(mnemonic) { return "etapa2_saltocond" }
            if isMemoryMnemonic(mnemonic) { return "etapa2_accmem" }
            if mnemonic.hasPrefix("mov") { return "etapa2_mov" }
            return isFloatingMnemonic(mnemonic) ? "etapa2f" : "etapa2"
        case 3:
            if mnemonic.hasPrefix("mov") { return "etapa3_mov" }
            if mnemonic.hasPrefix("neg") { return "etapa3_neg" }
            if isUnconditionalJumpMnemonic(mnemonic) { return "etapa3_salto_incond" }
            if isMemoryMnemonic(mnemonic) { return "etapa3_accmem" }
            if isImmediateMnemonic(mnemonic) { return "etapa3_inmed" }
            if isFloatingCompareMnemonic(mnemonic) { return "etapa3_c" }
            return isFloatingMnemonic(mnemonic) ? "rf_etapa3" : "r_etapa3"
        case 4:
            if mnemonic == "lw" { return "etapa4_load" }
            if mnemonic == "sw" { return "etapa4_store" }
            if mnemonic == "lwc1" { return "etapa4_lwc1" }
            if mnemonic == "swc1" { return "etapa4_swc1" }
            if mnemonic.hasPrefix("neg") { return "etapa4_neg" }
            if isImmediateMnemonic(mnemonic) { return "etapa4_inmed" }
            return isFloatingMnemonic(mnemonic) ? "rf_etapa4" : "r_etapa4"
        default:
            return mnemonic == "lwc1" ? "etapa5_lwc1" : "etapa5"
        }
    }

    private func segmentedInstructionDiagramName(for mnemonic: String, stage: Int) -> String {
        let suffix: String
        switch stage {
        case 1: suffix = "if"
        case 2: suffix = "id"
        case 3: suffix = "ex"
        case 4: suffix = "mem"
        default: suffix = "wb"
        }

        if mnemonic == "jr" {
            // En Java: {"R_IF","jrID","jrEX","jrMEM","jrWB"}
            return suffix == "if" ? "r_if" : "jr\(suffix)"
        }
        if mnemonic == "jal" { return "jal\(suffix)" }
        if isJumpMnemonic(mnemonic) { return "jump\(suffix)" }
        if mnemonic == "beq" { return "beq\(suffix)" }
        if mnemonic == "bne" || mnemonic == "bc1t" || mnemonic == "bc1f" {
            // En Java para segmentado heredan SaltoCondicional -> beqIF/ID/EX/MEM/WB
            return "beq\(suffix)"
        }
        if mnemonic == "lw" || mnemonic == "lwc1" { return "carga\(suffix)" }
        if mnemonic == "sw" || mnemonic == "swc1" { return "almacenamiento\(suffix)" }
        if isImmediateMnemonic(mnemonic) { return "inmediatas\(suffix)" }
        if isFPAddMnemonic(mnemonic) {
            if stage == 1 { return "sumapf_if" }
            if stage == 2 { return "sumapf_id" }
            if stage == 3 { return "r_ex" }
            if stage == 4 { return "r_mem" }
            return "r_wb"
        }
        if isFPMulMnemonic(mnemonic) {
            if stage == 1 { return "mulpf_if" }
            if stage == 2 { return "mulpf_id" }
            if stage == 3 { return "r_ex" }
            if stage == 4 { return "r_mem" }
            return "r_wb"
        }
        if isFPDivMnemonic(mnemonic) {
            if stage == 1 { return "divpf_if" }
            if stage == 2 { return "divpf_id" }
            if stage == 3 { return "r_ex" }
            if stage == 4 { return "r_mem" }
            return "r_wb"
        }
        if mnemonic == "nop" { return "nop" }
        return "r_\(suffix)"
    }

    private func segmentedHazardDiagramName(snapshot: CPUCycleSnapshot, mnemonic: String, stage: Int) -> String? {
        let hazards = parseHazards(from: snapshot.instruction)
        if hazards.loadUse {
            return "burbuja"
        }
        if hazards.control {
            if stage == 1 {
                return "if_flush"
            }
            if mnemonic == "bne" {
                return "bne_no"
            }
            if mnemonic == "bc1t" {
                return "bc1t_no"
            }
            if mnemonic == "bc1f" {
                return "bc1f_no"
            }
            return "beq_no"
        }
        if hazards.exLatency || hazards.fpu {
            if stage <= 2 {
                return "riesgo"
            }
            return "r_ex"
        }
        if stage == 2 {
            return "no_riesgo"
        }
        return nil
    }

    private func segmentedControlOutcomeAdjustedDiagram(
        hazardDiagram: String,
        mnemonic: String,
        stage: Int,
        instructionIndex: Int
    ) -> String? {
        guard isConditionalBranchMnemonic(mnemonic),
              let taken = simulationSession.branchOutcomeByInstructionIndex[instructionIndex] else {
            return hazardDiagram
        }

        if !taken {
            switch mnemonic {
            case "bne":
                return "bne_no"
            case "bc1t":
                return "bc1t_no"
            case "bc1f":
                return "bc1f_no"
            default:
                return "beq_no"
            }
        }

        if stage == 1 {
            return "if_flush"
        }
        return nil
    }

    private func segmentedForwardingDiagramName(snapshot: CPUCycleSnapshot) -> String? {
        guard snapshot.instruction.hasPrefix("SEG ") else { return nil }
        let map = segmentedStageIndexMap(from: snapshot.instruction)
        guard let idIndex = map["ID"] else { return nil }

        let idDeps = decodedInstructionDependencies(index: idIndex)
        let reads = idDeps.reads
        guard !reads.isEmpty else { return nil }

        if let memIndex = map["MEM"] {
            let memWrites = decodedInstructionDependencies(index: memIndex).writes
            if let reg = reads.first(where: { memWrites.contains($0) }) {
                return reg == idDeps.rt ? "antmem_rt" : "antmem_rs"
            }
        }

        if let wbIndex = map["WB"] {
            let wbWrites = decodedInstructionDependencies(index: wbIndex).writes
            if let reg = reads.first(where: { wbWrites.contains($0) }) {
                return reg == idDeps.rt ? "antwb_rt" : "antwb_rs"
            }
        }

        return nil
    }

    private struct DecodedDependencies {
        var reads: Set<String> = []
        var writes: Set<String> = []
        var rs: String?
        var rt: String?
    }

    private func segmentedStageIndexMap(from summary: String) -> [String: Int] {
        var map: [String: Int] = [:]
        for stage in ["IF", "ID", "EX", "MEM", "WB"] {
            if let idx = segmentedInstructionIndex(in: summary, stage: stage) {
                map[stage] = idx
            }
        }
        return map
    }

    private func decodedInstructionDependencies(index: Int) -> DecodedDependencies {
        guard index > 0, index <= simulationSession.textRows.count else { return DecodedDependencies() }
        let row = simulationSession.textRows[index - 1]
        return decodedInstructionDependencies(from: row.instruction)
    }

    private func decodedInstructionDependencies(from text: String) -> DecodedDependencies {
        let cleaned = text
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
        let tokens = cleaned.split { $0 == " " || $0 == "\t" }.map(String.init)
        guard let mnemonic = tokens.first?.lowercased() else { return DecodedDependencies() }
        let ops = Array(tokens.dropFirst())

        func norm(_ value: String) -> String {
            let raw = value.lowercased()
            if raw.hasPrefix("$") {
                return raw
            }
            return "$" + raw
        }

        func isReg(_ value: String) -> Bool {
            value.hasPrefix("$")
        }

        var deps = DecodedDependencies()
        switch mnemonic {
        case "add", "sub", "and", "or", "xor", "nor", "slt":
            if ops.count >= 3, isReg(ops[0]), isReg(ops[1]), isReg(ops[2]) {
                deps.writes.insert(norm(ops[0]))
                deps.rs = norm(ops[1]); deps.rt = norm(ops[2])
                deps.reads.formUnion([norm(ops[1]), norm(ops[2])])
            }
        case "addi", "andi", "ori", "xori", "slti":
            if ops.count >= 2, isReg(ops[0]), isReg(ops[1]) {
                deps.writes.insert(norm(ops[0]))
                deps.rs = norm(ops[1])
                deps.reads.insert(norm(ops[1]))
            }
        case "lw", "lb", "lwc1":
            if ops.count >= 2, isReg(ops[0]), isReg(ops[1]) {
                deps.writes.insert(norm(ops[0]))
                deps.rs = norm(ops[1])
                deps.reads.insert(norm(ops[1]))
            }
        case "sw", "sb", "swc1":
            if ops.count >= 2, isReg(ops[0]), isReg(ops[1]) {
                deps.rs = norm(ops[1]); deps.rt = norm(ops[0])
                deps.reads.formUnion([norm(ops[1]), norm(ops[0])])
            }
        case "beq", "bne":
            if ops.count >= 2, isReg(ops[0]), isReg(ops[1]) {
                deps.rs = norm(ops[0]); deps.rt = norm(ops[1])
                deps.reads.formUnion([norm(ops[0]), norm(ops[1])])
            }
        case "move", "neg", "not":
            if ops.count >= 2, isReg(ops[0]), isReg(ops[1]) {
                deps.writes.insert(norm(ops[0]))
                deps.rs = norm(ops[1])
                deps.reads.insert(norm(ops[1]))
            }
        case "jal", "j", "jr", "nop", "syscall":
            break
        default:
            if ops.count >= 3, isReg(ops[0]), isReg(ops[1]), isReg(ops[2]) {
                deps.writes.insert(norm(ops[0]))
                deps.rs = norm(ops[1]); deps.rt = norm(ops[2])
                deps.reads.formUnion([norm(ops[1]), norm(ops[2])])
            }
        }
        return deps
    }

    private struct ParsedHazards {
        var loadUse = false
        var control = false
        var exLatency = false
        var fpu = false
    }

    private func parseHazards(from instructionSummary: String) -> ParsedHazards {
        var value = ParsedHazards()
        value.loadUse = instructionSummary.contains("LU=1")
        value.control = instructionSummary.contains("CTRL=1")
        value.exLatency = instructionSummary.contains("EXLAT=1")
        value.fpu = instructionSummary.contains("FPU=1")
        return value
    }

    private func isImmediateMnemonic(_ mnemonic: String) -> Bool {
        ["addi", "addiu", "andi", "ori", "xori", "slti", "lui"].contains(mnemonic)
    }

    private func isMemoryMnemonic(_ mnemonic: String) -> Bool {
        ["lw", "sw", "lwc1", "swc1"].contains(mnemonic)
    }

    private func isJumpMnemonic(_ mnemonic: String) -> Bool {
        ["j", "jump"].contains(mnemonic)
    }

    private func isUnconditionalJumpMnemonic(_ mnemonic: String) -> Bool {
        ["j", "jump", "jal", "jr"].contains(mnemonic)
    }

    private func isConditionalBranchMnemonic(_ mnemonic: String) -> Bool {
        ["beq", "bne", "bc1t", "bc1f"].contains(mnemonic)
    }

    private func isFloatingMnemonic(_ mnemonic: String) -> Bool {
        isFPAddMnemonic(mnemonic)
            || isFPMulMnemonic(mnemonic)
            || isFPDivMnemonic(mnemonic)
            || ["lwc1", "swc1", "mfc1", "mtc1", "mov.s", "mov.d", "movs", "movd", "abss", "absd", "negs", "negd", "bc1t", "bc1f"].contains(mnemonic)
    }

    private func isFloatingCompareMnemonic(_ mnemonic: String) -> Bool {
        ["ceq", "ceq.s", "c.eq.s", "ceqs", "ceqd", "clts", "cles", "cltd", "cled"].contains(mnemonic)
    }

    private func isFPAddMnemonic(_ mnemonic: String) -> Bool {
        ["add.s", "sub.s", "add.d", "sub.d", "adds", "subs", "addd", "subd", "abss", "absd", "negs", "negd", "ceqs", "clts", "cles", "ceqd", "cltd", "cled", "cvtws", "cvtsw", "cvtwd", "cvtdw", "cvtsd", "cvtds"].contains(mnemonic)
    }

    private func isFPMulMnemonic(_ mnemonic: String) -> Bool {
        ["mul.s", "mul.d", "muls", "muld"].contains(mnemonic)
    }

    private func isFPDivMnemonic(_ mnemonic: String) -> Bool {
        ["div.s", "div.d", "divs", "divd"].contains(mnemonic)
    }

    private func resourceExists(named name: String) -> Bool {
        gifURL(named: name) != nil || NSImage(named: name) != nil
    }

    private func gifURL(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: "Resources") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "gif") {
            return url
        }
        return nil
    }

    private func formattedTextRow(_ row: TextRow) -> String {
        String(
            format: "[0x%08X] 0x%08X   %@",
            row.address,
            UInt32(bitPattern: Int32(truncatingIfNeeded: row.machineCode)),
            row.instruction
        )
    }

    private var cycleTableText: String {
        guard !simulationSession.cycleSnapshots.isEmpty else {
            return L10n.tr("sim.noExecutionYet", languageSelectionRaw: languageRawValue)
        }

        func fixed(_ text: String, _ width: Int) -> String {
            if text.count >= width {
                return String(text.prefix(width))
            }
            return text + String(repeating: " ", count: width - text.count)
        }

        let header = " " + [
            fixed("CIC", 4),
            fixed("PC_IN", 7),
            fixed("PC_OUT", 8),
            fixed("INSTR", 28),
            fixed("T0", 7),
            fixed("T1", 7),
            fixed("T2", 7)
        ].joined()

        let rows = Array(simulationSession.cycleSnapshots.prefix(160)).enumerated().map { index, cycle in
            let prefix = (index == simulationSession.currentCycleIndex) ? ">" : " "
            return prefix + [
                fixed("\(cycle.cycle)", 4),
                fixed("\(cycle.pcBefore)", 7),
                fixed("\(cycle.pcAfter)", 8),
                fixed(cycle.instruction, 28),
                fixed("\(cycle.t0)", 7),
                fixed("\(cycle.t1)", 7),
                fixed("\(cycle.t2)", 7)
            ].joined()
        }

        return ([header] + rows).joined(separator: "\n")
    }

    private var currentCyclePC: Int? {
        guard simulationSession.currentCycleIndex >= 0,
              simulationSession.currentCycleIndex < simulationSession.cycleSnapshots.count else {
            return nil
        }
        let pcIndex = simulationSession.cycleSnapshots[simulationSession.currentCycleIndex].pcBefore
        if pcIndex >= 0, pcIndex < simulationSession.textRows.count {
            return simulationSession.textRows[pcIndex].address
        }
        return nil
    }

    private var parsedBreakpointAddress: Int? {
        let raw = breakpointText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("0x") {
            return Int(raw.dropFirst(2), radix: 16)
        }
        return Int(raw)
    }

    private func pcAddress(for snapshot: CPUCycleSnapshot) -> Int? {
        let index = snapshot.pcBefore
        guard index >= 0, index < simulationSession.textRows.count else { return nil }
        return simulationSession.textRows[index].address
    }

    private var currentCycleBadgeText: String {
        guard simulationSession.currentCycleIndex >= 0,
              simulationSession.currentCycleIndex < simulationSession.cycleSnapshots.count else {
            return L10n.tr("sim.noCycleShort", languageSelectionRaw: languageRawValue)
        }
        let cycle = simulationSession.cycleSnapshots[simulationSession.currentCycleIndex]
        let pcAddress: String
        if let address = currentCyclePC {
            pcAddress = String(format: "0x%08X", address)
        } else {
            pcAddress = String(format: "idx:%d", cycle.pcBefore)
        }
        return "C\(cycle.cycle)  PC \(pcAddress)"
    }

    private struct PipelineStageChip {
        let name: String
        let value: String
        let isActive: Bool
    }

    private var pipelineStageChips: [PipelineStageChip] {
        guard let instruction = currentSnapshot?.instruction else { return [] }
        let stageOrder = ["IF", "ID", "EX", "MEM", "WB"]
        var chips: [PipelineStageChip] = []

        for stage in stageOrder {
            guard let range = instruction.range(of: "\(stage):") else { continue }
            let tail = instruction[range.upperBound...]
            let value = tail.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? "-"
            let active = value != "-" && value != "--"
            chips.append(PipelineStageChip(name: stage, value: value, isActive: active))
        }

        return chips
    }

    private func registerValue(for key: String) -> Int {
        guard let cycle = currentSnapshot else {
            return simulationSession.executionRegisters[key] ?? 0
        }
        switch key {
        case "$pc":
            return cycle.pcBefore
        case "$t0":
            return cycle.t0
        case "$t1":
            return cycle.t1
        case "$t2":
            return cycle.t2
        case "$s0":
            return cycle.s0
        case "$s1":
            return cycle.s1
        case "$hi":
            return cycle.hi
        case "$lo":
            return cycle.lo
        default:
            return simulationSession.executionRegisters[key] ?? 0
        }
    }

    private var currentSnapshot: CPUCycleSnapshot? {
        guard simulationSession.currentCycleIndex >= 0,
              simulationSession.currentCycleIndex < simulationSession.cycleSnapshots.count else {
            return nil
        }
        return simulationSession.cycleSnapshots[simulationSession.currentCycleIndex]
    }
}

struct MulticycleConfig: Equatable {
    var addLatency: Int = 1
    var mulLatency: Int = 1
    var divLatency: Int = 1
}

struct FunctionalUnitRow: Equatable {
    var segmented: Bool = true
    var units: Int = 1
    var latency: Int = 1
}

struct FunctionalUnitsConfig: Equatable {
    var intUnits: Int = 1
    var intLatency: Int = 1
    var addFP = FunctionalUnitRow(segmented: true, units: 2, latency: 2)
    var multFP = FunctionalUnitRow(segmented: true, units: 2, latency: 4)
    var divFP = FunctionalUnitRow(segmented: false, units: 1, latency: 7)
}

struct ScoreboardConfig: Equatable {
    var intUnits: Int = 1
    var intLatency: Int = 1
    var addFPUnits: Int = 2
    var addFPLatency: Int = 2
    var multFPUnits: Int = 2
    var multFPLatency: Int = 4
    var divFPUnits: Int = 1
    var divFPLatency: Int = 7
}

struct TomasuloConfig: Equatable {
    var addFPUnits: Int = 2
    var addFPLatency: Int = 2
    var multFPUnits: Int = 2
    var multFPLatency: Int = 4
    var divFPUnits: Int = 1
    var divFPLatency: Int = 7
    var loadFPUnits: Int = 1
    var loadFPLatency: Int = 2
    var storeFPUnits: Int = 1
    var storeFPLatency: Int = 1
}

private struct MulticycleConfigSheet: View {
    @Binding var config: MulticycleConfig
    @Environment(\.dismiss) private var dismiss
    @AppStorage("simula3ms.language") private var languageRawValue: String = AppLanguageSelection.automatic.rawValue
    @State private var draft: MulticycleConfig

    init(config: Binding<MulticycleConfig>) {
        _config = config
        _draft = State(initialValue: config.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow(L10n.tr("cfg.addsub", languageSelectionRaw: languageRawValue), value: $draft.addLatency)
                stepperRow(L10n.tr("cfg.mul", languageSelectionRaw: languageRawValue), value: $draft.mulLatency)
                stepperRow(L10n.tr("cfg.div", languageSelectionRaw: languageRawValue), value: $draft.divLatency)
            }
            .padding(16)
            .navigationTitle(L10n.tr("cfg.multicycle.title", languageSelectionRaw: languageRawValue))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("button.cancel", languageSelectionRaw: languageRawValue)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("cfg.accept", languageSelectionRaw: languageRawValue)) {
                        config = draft
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stepperRow(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
                .frame(width: 160, alignment: .leading)
            Spacer()
            Stepper("\(value.wrappedValue)", value: value, in: 1...99)
                .frame(width: 140, alignment: .trailing)
        }
    }
}

private struct ScoreboardConfigSheet: View {
    @Binding var config: ScoreboardConfig
    @Environment(\.dismiss) private var dismiss
    @AppStorage("simula3ms.language") private var languageRawValue: String = AppLanguageSelection.automatic.rawValue
    @State private var draft: ScoreboardConfig

    init(config: Binding<ScoreboardConfig>) {
        _config = config
        _draft = State(initialValue: config.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Text(L10n.tr("cfg.units", languageSelectionRaw: languageRawValue))
                        .frame(width: 120, alignment: .center)
                    Text(L10n.tr("cfg.latency", languageSelectionRaw: languageRawValue))
                        .frame(width: 120, alignment: .center)
                }
                scoreRow(L10n.tr("cfg.int", languageSelectionRaw: languageRawValue), units: $draft.intUnits, latency: $draft.intLatency, unitRange: 1...2, latencyRange: 1...1)
                scoreRow(L10n.tr("cfg.addFP", languageSelectionRaw: languageRawValue), units: $draft.addFPUnits, latency: $draft.addFPLatency, unitRange: 1...4, latencyRange: 1...5)
                scoreRow(L10n.tr("cfg.multFP", languageSelectionRaw: languageRawValue), units: $draft.multFPUnits, latency: $draft.multFPLatency, unitRange: 1...4, latencyRange: 1...10)
                scoreRow(L10n.tr("cfg.divFP", languageSelectionRaw: languageRawValue), units: $draft.divFPUnits, latency: $draft.divFPLatency, unitRange: 1...4, latencyRange: 1...10)
            }
            .padding(16)
            .navigationTitle(L10n.tr("cfg.scoreboard.title", languageSelectionRaw: languageRawValue))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("button.cancel", languageSelectionRaw: languageRawValue)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("cfg.accept", languageSelectionRaw: languageRawValue)) {
                        config = draft
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func scoreRow(
        _ title: String,
        units: Binding<Int>,
        latency: Binding<Int>,
        unitRange: ClosedRange<Int>,
        latencyRange: ClosedRange<Int>
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Spacer()
            Stepper("\(units.wrappedValue)", value: units, in: unitRange)
                .frame(width: 120)
            Stepper("\(latency.wrappedValue)", value: latency, in: latencyRange)
                .frame(width: 120)
        }
    }
}

private struct FunctionalUnitsConfigSheet: View {
    @Binding var config: FunctionalUnitsConfig
    @Environment(\.dismiss) private var dismiss
    @AppStorage("simula3ms.language") private var languageRawValue: String = AppLanguageSelection.automatic.rawValue
    @State private var draft: FunctionalUnitsConfig

    init(config: Binding<FunctionalUnitsConfig>) {
        _config = config
        _draft = State(initialValue: config.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Text(L10n.tr("cfg.units", languageSelectionRaw: languageRawValue))
                        .frame(width: 120, alignment: .center)
                    Text(L10n.tr("cfg.latency", languageSelectionRaw: languageRawValue))
                        .frame(width: 120, alignment: .center)
                }
                HStack {
                    Text(L10n.tr("cfg.int", languageSelectionRaw: languageRawValue))
                        .frame(width: 90, alignment: .leading)
                    Spacer()
                    Stepper("\(draft.intUnits)", value: $draft.intUnits, in: 1...1)
                        .frame(width: 120)
                    Stepper("\(draft.intLatency)", value: $draft.intLatency, in: 1...1)
                        .frame(width: 120)
                }
                functionalRow(title: L10n.tr("cfg.addFP", languageSelectionRaw: languageRawValue), row: $draft.addFP)
                functionalRow(title: L10n.tr("cfg.multFP", languageSelectionRaw: languageRawValue), row: $draft.multFP)
                functionalRow(title: L10n.tr("cfg.divFP", languageSelectionRaw: languageRawValue), row: $draft.divFP)
            }
            .padding(16)
            .navigationTitle(L10n.tr("cfg.functional.title", languageSelectionRaw: languageRawValue))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("button.cancel", languageSelectionRaw: languageRawValue)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("cfg.accept", languageSelectionRaw: languageRawValue)) {
                        config = draft
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func functionalRow(title: String, row: Binding<FunctionalUnitRow>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .frame(width: 90, alignment: .leading)
                Spacer()
                Stepper("\(row.wrappedValue.units)", value: row.units, in: 1...4)
                    .frame(width: 120)
                Stepper("\(row.wrappedValue.latency)", value: row.latency, in: latencyRange(for: title))
                    .frame(width: 120)
            }
            Picker("", selection: row.segmented) {
                Text(L10n.tr("cfg.segmented.yes", languageSelectionRaw: languageRawValue)).tag(true)
                Text(L10n.tr("cfg.segmented.no", languageSelectionRaw: languageRawValue)).tag(false)
            }
            .pickerStyle(.radioGroup)
        }
    }

    private func latencyRange(for title: String) -> ClosedRange<Int> {
        switch title {
        case L10n.tr("cfg.addFP", languageSelectionRaw: languageRawValue): return 1...5
        case L10n.tr("cfg.multFP", languageSelectionRaw: languageRawValue), L10n.tr("cfg.divFP", languageSelectionRaw: languageRawValue): return 1...10
        default: return 1...10
        }
    }
}

private struct TomasuloConfigSheet: View {
    @Binding var config: TomasuloConfig
    @Environment(\.dismiss) private var dismiss
    @AppStorage("simula3ms.language") private var languageRawValue: String = AppLanguageSelection.automatic.rawValue
    @State private var draft: TomasuloConfig

    init(config: Binding<TomasuloConfig>) {
        _config = config
        _draft = State(initialValue: config.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer()
                    Text(L10n.tr("cfg.units", languageSelectionRaw: languageRawValue))
                        .frame(width: 120, alignment: .center)
                    Text(L10n.tr("cfg.latency", languageSelectionRaw: languageRawValue))
                        .frame(width: 120, alignment: .center)
                }
                row(L10n.tr("cfg.addFP", languageSelectionRaw: languageRawValue), units: $draft.addFPUnits, latency: $draft.addFPLatency, unitRange: 1...4, latencyRange: 1...5)
                row(L10n.tr("cfg.multFP", languageSelectionRaw: languageRawValue), units: $draft.multFPUnits, latency: $draft.multFPLatency, unitRange: 1...4, latencyRange: 1...10)
                row(L10n.tr("cfg.divFP", languageSelectionRaw: languageRawValue), units: $draft.divFPUnits, latency: $draft.divFPLatency, unitRange: 1...4, latencyRange: 1...10)
                row(L10n.tr("cfg.loadFP", languageSelectionRaw: languageRawValue), units: $draft.loadFPUnits, latency: $draft.loadFPLatency, unitRange: 1...4, latencyRange: 2...2)
                row(L10n.tr("cfg.storeFP", languageSelectionRaw: languageRawValue), units: $draft.storeFPUnits, latency: $draft.storeFPLatency, unitRange: 1...4, latencyRange: 1...1)
            }
            .padding(16)
            .navigationTitle(L10n.tr("cfg.tomasulo.title", languageSelectionRaw: languageRawValue))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("button.cancel", languageSelectionRaw: languageRawValue)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("cfg.accept", languageSelectionRaw: languageRawValue)) {
                        config = draft
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(
        _ title: String,
        units: Binding<Int>,
        latency: Binding<Int>,
        unitRange: ClosedRange<Int>,
        latencyRange: ClosedRange<Int>
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
            Spacer()
            Stepper("\(units.wrappedValue)", value: units, in: unitRange)
                .frame(width: 120)
            Stepper("\(latency.wrappedValue)", value: latency, in: latencyRange)
                .frame(width: 120)
        }
    }
}

private struct FrameDrivenGIFView: NSViewRepresentable {
    let resourceName: String
    let frameIndex: Int

    final class Coordinator {
        var cachedFrames: [NSImage] = []
        var cachedResourceName: String = ""
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        updateImage(on: imageView, coordinator: context.coordinator)
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        updateImage(on: nsView, coordinator: context.coordinator)
    }

    private func updateImage(on imageView: NSImageView, coordinator: Coordinator) {
        if coordinator.cachedResourceName != resourceName {
            coordinator.cachedResourceName = resourceName
            coordinator.cachedFrames = loadFrames(for: resourceName)
        }

        if !coordinator.cachedFrames.isEmpty {
            let index = frameIndex % coordinator.cachedFrames.count
            imageView.image = coordinator.cachedFrames[index]
        } else {
            imageView.image = fallbackImage(for: resourceName)
        }
    }

    private func fallbackImage(for name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: "Resources") {
            return NSImage(contentsOf: url)
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "gif") {
            return NSImage(contentsOf: url)
        }
        return NSImage(named: name)
    }

    private func loadFrames(for name: String) -> [NSImage] {
        let url =
            Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: "Resources")
            ?? Bundle.main.url(forResource: name, withExtension: "gif")

        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return []
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return [] }

        var frames: [NSImage] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            if let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) {
                frames.append(NSImage(cgImage: cgImage, size: .zero))
            }
        }
        return frames
    }
}

@Observable
final class SimulationSettings {
    var ioModel: IOModel = .memoryMapped
    var dataPath: DataPath = .monocycle
    var scheduling: SchedulingModel = .basic
    var branchPolicy: BranchPolicy = .delayedFloating
    var simulatedInputText: String = ""
    var multicycleConfig = MulticycleConfig()
    var functionalUnitsConfig = FunctionalUnitsConfig()
    var scoreboardConfig = ScoreboardConfig()
    var tomasuloConfig = TomasuloConfig()
}

enum IOModel: String, CaseIterable, Identifiable {
    case memoryMapped = "Mapeada"
    case interrupts = "Interrupciones"
    case disabled = "Desactivada"

    var id: String { rawValue }

    var executionMode: IOExecutionMode {
        switch self {
        case .memoryMapped:
            return .mapped
        case .interrupts:
            return .interrupts
        case .disabled:
            return .disabled
        }
    }
}

extension IOModel {
    func localizedTitle(languageSelectionRaw: String) -> String {
        switch self {
        case .memoryMapped: return L10n.tr("io.mapped", languageSelectionRaw: languageSelectionRaw)
        case .interrupts: return L10n.tr("io.interrupts", languageSelectionRaw: languageSelectionRaw)
        case .disabled: return L10n.tr("io.disabled", languageSelectionRaw: languageSelectionRaw)
        }
    }
}

enum DataPath: String, CaseIterable, Identifiable {
    case monocycle = "Monociclo"
    case multicycle = "Multiciclo"
    case segmented = "Segmentado"

    var id: String { rawValue }

    var cycleMode: DataPathCycleMode {
        switch self {
        case .monocycle:
            return .monocycle
        case .multicycle:
            return .multicycle
        case .segmented:
            return .multicycle
        }
    }
}

extension DataPath {
    func localizedTitle(languageSelectionRaw: String) -> String {
        switch self {
        case .monocycle: return L10n.tr("datapath.monocycle", languageSelectionRaw: languageSelectionRaw)
        case .multicycle: return L10n.tr("datapath.multicycle", languageSelectionRaw: languageSelectionRaw)
        case .segmented: return L10n.tr("datapath.segmented", languageSelectionRaw: languageSelectionRaw)
        }
    }
}

enum SchedulingModel: String, CaseIterable, Identifiable {
    case basic = "Básico"
    case scoreboard = "Marcador"
    case tomasulo = "Tomasulo"

    var id: String { rawValue }

    var advancedMode: AdvancedSchedulingMode {
        switch self {
        case .basic:
            return .segmented
        case .scoreboard:
            return .scoreboard
        case .tomasulo:
            return .tomasulo
        }
    }
}

extension SchedulingModel {
    func localizedTitle(languageSelectionRaw: String) -> String {
        switch self {
        case .basic: return L10n.tr("scheduling.basic", languageSelectionRaw: languageSelectionRaw)
        case .scoreboard: return L10n.tr("scheduling.scoreboard", languageSelectionRaw: languageSelectionRaw)
        case .tomasulo: return L10n.tr("scheduling.tomasulo", languageSelectionRaw: languageSelectionRaw)
        }
    }
}

enum BranchPolicy: String, CaseIterable, Identifiable {
    case delayedFloating = "Salto retardado flotante"
    case fixedFloating = "Salto fijo flotante"

    var id: String { rawValue }

    var executionMode: BranchExecutionMode {
        switch self {
        case .delayedFloating:
            return .delayed
        case .fixedFloating:
            return .fixed
        }
    }
}

extension BranchPolicy {
    func localizedTitle(languageSelectionRaw: String) -> String {
        switch self {
        case .delayedFloating: return L10n.tr("branch.delayedFloating", languageSelectionRaw: languageSelectionRaw)
        case .fixedFloating: return L10n.tr("branch.fixedFloating", languageSelectionRaw: languageSelectionRaw)
        }
    }
}

#Preview {
    ContentView()
        .environment(SimulationSettings())
        .environment(SimulationSession())
}
