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
    @Environment(\.openWindow) private var openWindow
    @AppStorage("simula3ms.appearance") private var appearanceRawValue: String = AppAppearance.automatic.rawValue
    @AppStorage("simula3ms.language") private var languageRawValue: String = AppLanguageSelection.automatic.rawValue
    @State private var settings = SimulationSettings()
    @State private var simulationSession = SimulationSession()
    @State private var hasCompletedInitialLanguageSetup = false

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
                .environment(settings)
                .environment(simulationSession)
                .preferredColorScheme(selectedAppearance.colorScheme)
                .environment(\.locale, effectiveLocale)
                .onAppear {
                    syncAppleLanguageOverride(for: selectedLanguage)
                    hasCompletedInitialLanguageSetup = true
                }
                .onChange(of: languageRawValue) { _, newValue in
                    let selection = AppLanguageSelection(rawValue: newValue) ?? .automatic
                    syncAppleLanguageOverride(for: selection)
                    if hasCompletedInitialLanguageSetup {
                        promptForRestart(selection: selection)
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
                    ForEach(AppLanguageSelection.allCases) { language in
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

private extension Simula3MSApp {
    func syncAppleLanguageOverride(for selection: AppLanguageSelection) {
        if let code = selection.appleLanguagesOverrideCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
            UserDefaults.standard.set(code, forKey: "AppleLocale")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            UserDefaults.standard.removeObject(forKey: "AppleLocale")
        }
    }

    func promptForRestart(selection: AppLanguageSelection) {
        let languageCode = selection.languageCode
        let alert = NSAlert()
        switch languageCode {
        case "gl":
            alert.messageText = "Reinicio recomendado"
            alert.informativeText = "Para aplicar completamente o cambio de idioma, reinicia a aplicación."
            alert.addButton(withTitle: "Reiniciar agora")
            alert.addButton(withTitle: "Máis tarde")
        case "en":
            alert.messageText = "Restart recommended"
            alert.informativeText = "Restart the app to fully apply the language change."
            alert.addButton(withTitle: "Restart now")
            alert.addButton(withTitle: "Later")
        default:
            alert.messageText = "Reinicio recomendado"
            alert.informativeText = "Para aplicar completamente el cambio de idioma, reinicia la aplicación."
            alert.addButton(withTitle: "Reiniciar ahora")
            alert.addButton(withTitle: "Más tarde")
        }
        alert.alertStyle = .informational
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchApplication(languageOverrideCode: selection.appleLanguagesOverrideCode)
        }
    }

    func relaunchApplication(languageOverrideCode: String?) {
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let script: String
        if let code = languageOverrideCode {
            let escapedCode = code.replacingOccurrences(of: "'", with: "'\\''")
            script = "sleep 0.4; open '\(path)' --args -AppleLanguages '(\"\(escapedCode)\")'"
        } else {
            script = "sleep 0.4; open '\(path)'"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.terminate(nil)
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
        case .automatic: return L10n.tr("language.automatic", languageSelectionRaw: languageSelectionRaw)
        case .spanish: return "Castellano"
        case .english: return "English"
        case .galician: return "Galego (AppleLanguages, non 100%)"
        }
    }
}
