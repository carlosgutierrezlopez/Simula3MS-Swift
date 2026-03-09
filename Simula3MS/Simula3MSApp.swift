//
//  Simula3MSApp.swift
//  Simula3MS
//
//  Created by Carlos G. L. on 6/3/26.
//

import SwiftUI

private enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automático"
        case .light: return "Claro"
        case .dark: return "Oscuro"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@main
struct Simula3MSApp: App {
    @NSApplicationDelegateAdaptor(Simula3MSAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage("simula3ms.appearance") private var appearanceRawValue: String = AppAppearance.automatic.rawValue
    @AppStorage("simula3ms.language") private var languageRawValue: String = AppLanguageSelection.automatic.rawValue
    private let appTerminationCoordinator = AppTerminationCoordinator.shared
    @State private var settings = SimulationSettings()
    @State private var simulationSession = SimulationSession()
    @State private var hasCompletedInitialLanguageSetup = false
    @State private var hasRestoredPendingRelaunchDocuments = false
    @State private var isRevertingLanguageSelection = false

    init() {
        let raw = UserDefaults.standard.string(forKey: "simula3ms.language") ?? AppLanguageSelection.automatic.rawValue
        let selection = AppLanguageSelection(rawValue: raw) ?? .automatic
        syncAppleLanguageOverride(for: selection)
    }

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearanceRawValue) ?? .automatic
    }

    private var selectedLanguage: AppLanguageSelection {
        AppLanguageSelection(rawValue: languageRawValue) ?? .automatic
    }

    private var effectiveLocale: Locale {
        Locale(identifier: selectedLanguage.languageCode)
    }

    var body: some Scene {
        WindowGroup(id: "main-window") {
            ContentView()
                .environment(appTerminationCoordinator)
                .environment(settings)
                .environment(simulationSession)
                .preferredColorScheme(selectedAppearance.colorScheme)
                .environment(\.locale, effectiveLocale)
                .environment(\.layoutDirection, selectedLanguage.layoutDirection)
                .onAppear {
                    syncAppleLanguageOverride(for: selectedLanguage)
                    hasCompletedInitialLanguageSetup = true
                    restorePendingRelaunchDocumentsIfNeeded()
                }
                .onChange(of: languageRawValue) { oldValue, newValue in
                    guard !isRevertingLanguageSelection else {
                        isRevertingLanguageSelection = false
                        return
                    }
                    let selection = AppLanguageSelection(rawValue: newValue) ?? .automatic
                    syncAppleLanguageOverride(for: selection)
                    if hasCompletedInitialLanguageSetup {
                        promptForRestart(selection: selection, previousRawValue: oldValue)
                    }
                }
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    openWindow(id: "main-window")
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .simulaOpenURL, object: url)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
        .defaultSize(width: 620, height: 672)
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Divider()
                Picker(L10n.tr("menu.appearance", languageSelectionRaw: languageRawValue), selection: $appearanceRawValue) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.localizedTitle(languageSelectionRaw: languageRawValue)).tag(appearance.rawValue)
                    }
                }

                Picker(L10n.tr("menu.language", languageSelectionRaw: languageRawValue), selection: $languageRawValue) {
                    ForEach(AppLanguageSelection.menuCases) { language in
                        Text(language.localizedTitle(languageSelectionRaw: languageRawValue)).tag(language.rawValue)
                    }
                }
            }

            CommandMenu(L10n.tr("menu.settings", languageSelectionRaw: languageRawValue)) {
                Picker(L10n.tr("menu.io", languageSelectionRaw: languageRawValue), selection: $settings.ioModel) {
                    ForEach(IOModel.allCases) { mode in
                        Text(mode.localizedTitle(languageSelectionRaw: languageRawValue)).tag(mode)
                    }
                }

                Menu(L10n.tr("menu.datapath", languageSelectionRaw: languageRawValue)) {
                    Button {
                        settings.dataPath = .monocycle
                    } label: {
                        if settings.dataPath == .monocycle {
                            Label(settings.dataPath.localizedTitle(languageSelectionRaw: languageRawValue), systemImage: "checkmark")
                        } else {
                            Text(DataPath.monocycle.localizedTitle(languageSelectionRaw: languageRawValue))
                        }
                    }

                    Button {
                        settings.dataPath = .multicycle
                        NotificationCenter.default.post(name: .simulaOpenMulticycleConfig, object: nil)
                    } label: {
                        if settings.dataPath == .multicycle {
                            Label(DataPath.multicycle.localizedTitle(languageSelectionRaw: languageRawValue), systemImage: "checkmark")
                        } else {
                            Text(DataPath.multicycle.localizedTitle(languageSelectionRaw: languageRawValue))
                        }
                    }

                    Menu(L10n.tr("menu.segmented", languageSelectionRaw: languageRawValue)) {
                        Button {
                            settings.dataPath = .segmented
                            settings.scheduling = .basic
                            NotificationCenter.default.post(name: .simulaOpenSegmentedBasicConfig, object: nil)
                        } label: {
                            if settings.dataPath == .segmented && settings.scheduling == .basic {
                                Label(SchedulingModel.basic.localizedTitle(languageSelectionRaw: languageRawValue), systemImage: "checkmark")
                            } else {
                                Text(SchedulingModel.basic.localizedTitle(languageSelectionRaw: languageRawValue))
                            }
                        }

                        Button {
                            settings.dataPath = .segmented
                            settings.scheduling = .scoreboard
                            NotificationCenter.default.post(name: .simulaOpenScoreboardConfig, object: nil)
                        } label: {
                            if settings.dataPath == .segmented && settings.scheduling == .scoreboard {
                                Label(SchedulingModel.scoreboard.localizedTitle(languageSelectionRaw: languageRawValue), systemImage: "checkmark")
                            } else {
                                Text(SchedulingModel.scoreboard.localizedTitle(languageSelectionRaw: languageRawValue))
                            }
                        }

                        Button {
                            settings.dataPath = .segmented
                            settings.scheduling = .tomasulo
                            NotificationCenter.default.post(name: .simulaOpenTomasuloConfig, object: nil)
                        } label: {
                            if settings.dataPath == .segmented && settings.scheduling == .tomasulo {
                                Label(SchedulingModel.tomasulo.localizedTitle(languageSelectionRaw: languageRawValue), systemImage: "checkmark")
                            } else {
                                Text(SchedulingModel.tomasulo.localizedTitle(languageSelectionRaw: languageRawValue))
                            }
                        }
                    }
                }

                Picker(L10n.tr("menu.branches", languageSelectionRaw: languageRawValue), selection: $settings.branchPolicy) {
                    ForEach(BranchPolicy.allCases) { policy in
                        Text(policy.localizedTitle(languageSelectionRaw: languageRawValue)).tag(policy)
                    }
                }
            }

            CommandGroup(replacing: .newItem) {
                Button(L10n.tr("menu.newWindow", languageSelectionRaw: languageRawValue)) {
                    openWindow(id: "main-window")
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button(L10n.tr("menu.clear", languageSelectionRaw: languageRawValue)) {
                    NotificationCenter.default.post(name: .simulaNew, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button(L10n.tr("menu.open", languageSelectionRaw: languageRawValue)) {
                    NotificationCenter.default.post(name: .simulaOpen, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button(L10n.tr("menu.save", languageSelectionRaw: languageRawValue)) {
                    NotificationCenter.default.post(name: .simulaSave, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button(L10n.tr("menu.saveAs", languageSelectionRaw: languageRawValue)) {
                    NotificationCenter.default.post(name: .simulaSaveAs, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button(L10n.tr("menu.search", languageSelectionRaw: languageRawValue)) {
                    NotificationCenter.default.post(name: .simulaSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button(L10n.tr("menu.goto", languageSelectionRaw: languageRawValue)) {
                    NotificationCenter.default.post(name: .simulaGoToLine, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command])

                Button(L10n.tr("menu.assemble", languageSelectionRaw: languageRawValue)) {
                    NotificationCenter.default.post(name: .simulaAssemble, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button(L10n.tr("menu.run", languageSelectionRaw: languageRawValue)) {
                    NotificationCenter.default.post(name: .simulaRun, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }

            CommandGroup(replacing: .help) {
                Button {
                    NotificationCenter.default.post(name: .simulaHelp, object: nil)
                } label: {
                    Label(L10n.tr("menu.help", languageSelectionRaw: languageRawValue), systemImage: "lightbulb")
                }
                .keyboardShortcut("?", modifiers: [.command])
            }
        }

        WindowGroup(id: "simulation-window") {
            SimulationWindowView()
                .environment(settings)
                .environment(simulationSession)
                .preferredColorScheme(selectedAppearance.colorScheme)
                .environment(\.locale, effectiveLocale)
        }
        .defaultSize(width: 980, height: 760)
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class Simula3MSAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppTerminationCoordinator.shared.reset()
        AppTerminationCoordinator.shared.restorePendingRelaunchDocuments()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTerminationCoordinator.shared.beginApplicationTermination()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppTerminationCoordinator.shared.performPendingRelaunchIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
@Observable
final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()
    private let pendingRelaunchDocumentsKey = "simula3ms.pendingRelaunchDocuments"

    private struct PendingRelaunchDocument: Codable {
        let path: String
        let bookmarkData: Data
    }

    private final class WindowSession {
        weak var window: NSWindow?
        let hasUnsavedChanges: () -> Bool
        let currentDocumentURL: () -> URL?
        let requestTerminationDecision: (@escaping (Bool) -> Void) -> Void

        init(
            window: NSWindow,
            hasUnsavedChanges: @escaping () -> Bool,
            currentDocumentURL: @escaping () -> URL?,
            requestTerminationDecision: @escaping (@escaping (Bool) -> Void) -> Void
        ) {
            self.window = window
            self.hasUnsavedChanges = hasUnsavedChanges
            self.currentDocumentURL = currentDocumentURL
            self.requestTerminationDecision = requestTerminationDecision
        }
    }

    private var sessions: [ObjectIdentifier: WindowSession] = [:]
    private var pendingTerminationWindows: [ObjectIdentifier] = []
    private var hasPendingRelaunch = false
    private var pendingRelaunchLanguageCodes: [String]?
    private var pendingRelaunchDocuments: [PendingRelaunchDocument] = []
    private var restoredPendingDocuments: [PendingRelaunchDocument] = []
    private(set) var isTerminationInProgress = false

    func register(
        window: NSWindow,
        hasUnsavedChanges: @escaping () -> Bool,
        currentDocumentURL: @escaping () -> URL?,
        requestTerminationDecision: @escaping (@escaping (Bool) -> Void) -> Void
    ) {
        cleanupSessions()
        let identifier = ObjectIdentifier(window)
        sessions[identifier] = WindowSession(
            window: window,
            hasUnsavedChanges: hasUnsavedChanges,
            currentDocumentURL: currentDocumentURL,
            requestTerminationDecision: requestTerminationDecision
        )
    }

    func unregister(window: NSWindow) {
        sessions.removeValue(forKey: ObjectIdentifier(window))
    }

    func reset() {
        sessions.removeAll()
        pendingTerminationWindows.removeAll()
        hasPendingRelaunch = false
        pendingRelaunchLanguageCodes = nil
        pendingRelaunchDocuments.removeAll()
        restoredPendingDocuments.removeAll()
        isTerminationInProgress = false
    }

    func queueApplicationRelaunch(languageCodes: [String]?) {
        cleanupSessions()
        hasPendingRelaunch = true
        pendingRelaunchLanguageCodes = languageCodes
        pendingRelaunchDocuments = sessions.values.compactMap {
            guard let url = $0.currentDocumentURL() else { return nil }
            return makePendingRelaunchDocument(for: url)
        }
    }

    func clearPendingRelaunch() {
        hasPendingRelaunch = false
        pendingRelaunchLanguageCodes = nil
        pendingRelaunchDocuments.removeAll()
    }

    func registerPendingRelaunchDocument(_ url: URL) {
        guard let document = makePendingRelaunchDocument(for: url) else { return }
        if !pendingRelaunchDocuments.contains(where: { $0.path == document.path }) {
            pendingRelaunchDocuments.append(document)
        }
    }

    func unregisterPendingRelaunchDocument(_ url: URL?) {
        guard let path = url?.path else { return }
        pendingRelaunchDocuments.removeAll { $0.path == path }
    }

    func restorePendingRelaunchDocuments() {
        guard let data = UserDefaults.standard.data(forKey: pendingRelaunchDocumentsKey) else {
            restoredPendingDocuments = []
            UserDefaults.standard.removeObject(forKey: pendingRelaunchDocumentsKey)
            return
        }

        restoredPendingDocuments = (try? PropertyListDecoder().decode([PendingRelaunchDocument].self, from: data)) ?? []
        UserDefaults.standard.removeObject(forKey: pendingRelaunchDocumentsKey)
    }

    func pendingRelaunchDocumentCount() -> Int {
        restoredPendingDocuments.count
    }

    func claimNextPendingRelaunchDocument() -> URL? {
        while !restoredPendingDocuments.isEmpty {
            let document = restoredPendingDocuments.removeFirst()
            var isStale = false

            if let url = try? URL(
                resolvingBookmarkData: document.bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }

            let fallbackURL = URL(fileURLWithPath: document.path)
            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                return fallbackURL
            }
        }

        return nil
    }

    func performPendingRelaunchIfNeeded() {
        guard hasPendingRelaunch else {
            UserDefaults.standard.removeObject(forKey: pendingRelaunchDocumentsKey)
            return
        }

        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        guard !path.isEmpty else {
            pendingRelaunchLanguageCodes = nil
            pendingRelaunchDocuments.removeAll()
            return
        }

        if pendingRelaunchDocuments.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingRelaunchDocumentsKey)
        } else {
            if let data = try? PropertyListEncoder().encode(pendingRelaunchDocuments) {
                UserDefaults.standard.set(data, forKey: pendingRelaunchDocumentsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: pendingRelaunchDocumentsKey)
            }
        }

        let script: String

        if let codes = pendingRelaunchLanguageCodes, !codes.isEmpty {
            let escapedCodes = codes
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ", ")
            script = "sleep 0.4; open '\(path)' --args -AppleLanguages '(\(escapedCodes))'"
        } else {
            script = "sleep 0.4; open '\(path)'"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        hasPendingRelaunch = false
        pendingRelaunchLanguageCodes = nil
        pendingRelaunchDocuments.removeAll()
    }

    func beginApplicationTermination() -> NSApplication.TerminateReply {
        guard !isTerminationInProgress else {
            return .terminateLater
        }

        cleanupSessions()

        let unsavedWindowIdentifiers = NSApp.orderedWindows.compactMap { window -> ObjectIdentifier? in
            let identifier = ObjectIdentifier(window)
            guard let session = sessions[identifier], session.hasUnsavedChanges() else {
                return nil
            }
            return identifier
        }

        guard !unsavedWindowIdentifiers.isEmpty else {
            return .terminateNow
        }

        isTerminationInProgress = true
        pendingTerminationWindows = unsavedWindowIdentifiers
        continueTerminationSequence()
        return .terminateLater
    }

    private func continueTerminationSequence() {
        while let identifier = pendingTerminationWindows.first {
            pendingTerminationWindows.removeFirst()

            guard let session = sessions[identifier], let window = session.window else {
                continue
            }

            guard window.isVisible, session.hasUnsavedChanges() else {
                continue
            }

            session.requestTerminationDecision { [weak self] shouldContinue in
                guard let self else { return }
                if shouldContinue {
                    self.continueTerminationSequence()
                } else {
                    self.finishTermination(shouldTerminate: false)
                }
            }
            return
        }

        finishTermination(shouldTerminate: true)
    }

    private func finishTermination(shouldTerminate: Bool) {
        cleanupSessions()
        pendingTerminationWindows.removeAll()
        isTerminationInProgress = false
        if !shouldTerminate {
            hasPendingRelaunch = false
            pendingRelaunchLanguageCodes = nil
            pendingRelaunchDocuments.removeAll()
        }
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    private func cleanupSessions() {
        sessions = sessions.filter { _, session in
            session.window != nil
        }
    }

    private func makePendingRelaunchDocument(for url: URL) -> PendingRelaunchDocument? {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return nil
        }

        return PendingRelaunchDocument(path: url.path, bookmarkData: bookmarkData)
    }
}

private extension Simula3MSApp {
    func syncAppleLanguageOverride(for selection: AppLanguageSelection) {
        if let codes = selection.appleLanguagesOverrideCodes, let primaryCode = codes.first {
            UserDefaults.standard.set(codes, forKey: "AppleLanguages")
            UserDefaults.standard.set(primaryCode, forKey: "AppleLocale")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            UserDefaults.standard.removeObject(forKey: "AppleLocale")
        }
    }

    func promptForRestart(selection: AppLanguageSelection, previousRawValue: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("alert.restartRecommended.title", languageSelectionRaw: selection.rawValue)
        alert.informativeText = L10n.tr("alert.restartRecommended.message", languageSelectionRaw: selection.rawValue)
        alert.addButton(withTitle: L10n.tr("button.restartNow", languageSelectionRaw: selection.rawValue))
        alert.addButton(withTitle: L10n.tr("button.cancel", languageSelectionRaw: selection.rawValue))
        alert.alertStyle = .informational
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchApplication(languageOverrideCodes: selection.appleLanguagesOverrideCodes)
        } else {
            let previousSelection = AppLanguageSelection(rawValue: previousRawValue) ?? .automatic
            syncAppleLanguageOverride(for: previousSelection)
            isRevertingLanguageSelection = true
            languageRawValue = previousSelection.rawValue
        }
    }

    func relaunchApplication(languageOverrideCodes: [String]?) {
        appTerminationCoordinator.queueApplicationRelaunch(languageCodes: languageOverrideCodes)
        NSApp.terminate(nil)
    }

    func restorePendingRelaunchDocumentsIfNeeded() {
        guard !hasRestoredPendingRelaunchDocuments else { return }
        hasRestoredPendingRelaunchDocuments = true

        let additionalWindowCount = max(appTerminationCoordinator.pendingRelaunchDocumentCount() - 1, 0)
        guard additionalWindowCount > 0 else { return }

        for index in 0..<additionalWindowCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.06 * Double(index))) {
                openWindow(id: "main-window")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

private extension AppAppearance {
    func localizedTitle(languageSelectionRaw: String) -> String {
        switch self {
        case .automatic: return L10n.tr("appearance.automatic", languageSelectionRaw: languageSelectionRaw)
        case .light: return L10n.tr("appearance.light", languageSelectionRaw: languageSelectionRaw)
        case .dark: return L10n.tr("appearance.dark", languageSelectionRaw: languageSelectionRaw)
        }
    }
}

private extension AppLanguageSelection {
    func localizedTitle(languageSelectionRaw: String) -> String {
        switch self {
        case .automatic:
            return L10n.tr("language.automatic", languageSelectionRaw: languageSelectionRaw)
        default:
            return nativeMenuTitle
        }
    }
}
