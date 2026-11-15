import SwiftUI
import AppKit
import CrossKitCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = SettingsStore.shared()
    let locator = ServerLocator()
    let manager: ServerManager
    let handler: BridgeHandler
    private var server: BridgeServer?

    @Published var statuses: [Language: ServerStatus] = [:]
    @Published var detectedPaths: [Language: [String]] = [:]
    @Published var bridgeError: String?

    private init() {
        manager = ServerManager(settings: settings, locator: locator)
        handler = BridgeHandler(manager: manager, settings: settings)
        handler.documentResolver = { request, language in XcodeDocumentLocator.resolve(request, language: language) }
        handler.openLocation = { location in XcodeDocumentLocator.open(location) }
        for language in Language.allCases {
            var status = ServerStatus(state: settings.isEnabled(language) ? .stopped : .disabled)
            status.binaryPath = nil
            statuses[language] = status
            settings.writeStatus(status, for: language)
        }
        refreshDetection()
        let manager = self.manager
        Task {
            await manager.setStatusHandler { language, status in
                Task { @MainActor in AppModel.shared.statuses[language] = status }
            }
        }
        startBridge()
    }

    private func startBridge() {
        let handler = self.handler
        let server = BridgeServer { request in await handler.handle(request) }
        do {
            try server.start()
            self.server = server
            bridgeError = nil
            NSLog("CrossKit bridge listening on %@", server.portName)
        } catch {
            bridgeError = error.localizedDescription
            NSLog("CrossKit bridge failed: %@", error.localizedDescription)
        }
    }

    func refreshDetection() {
        for language in Language.allCases {
            detectedPaths[language] = locator.candidates(for: language).map(\.path)
        }
    }

    /// Path that will be used: custom if set, otherwise the first auto-detected one.
    func effectivePath(_ language: Language) -> String? {
        settings.customServerPath(for: language) ?? detectedPaths[language]?.first
    }

    func isCustomPath(_ language: Language) -> Bool { settings.customServerPath(for: language) != nil }

    // MARK: Bindings (write-through to the shared App Group UserDefaults)

    func enabledBinding(_ language: Language) -> Binding<Bool> {
        Binding(
            get: { self.settings.isEnabled(language) },
            set: { enabled in
                self.objectWillChange.send()
                self.settings.setEnabled(enabled, for: language)
                let manager = self.manager
                Task { await manager.stop(language) }
            })
    }

    func featureBinding(_ feature: Feature, _ language: Language) -> Binding<Bool> {
        Binding(
            get: { self.settings.isFeatureEnabled(feature, for: language) },
            set: { enabled in
                self.objectWillChange.send()
                self.settings.setFeature(feature, enabled: enabled, for: language)
            })
    }

    var idleMinutes: Binding<Double> {
        Binding(
            get: { self.settings.idleTimeout / 60 },
            set: { minutes in
                self.objectWillChange.send()
                self.settings.idleTimeout = minutes * 60
            })
    }

    func setCustomPath(_ path: String?, for language: Language) {
        objectWillChange.send()
        settings.setCustomServerPath(path, for: language)
        restart(language)
    }

    func chooseBinary(for language: Language) {
        let panel = NSOpenPanel()
        panel.title = "Choose \(language.serverBinaryName)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        if let current = effectivePath(language) {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            setCustomPath(url.path, for: language)
        }
    }

    func restart(_ language: Language) {
        let manager = self.manager
        Task { await manager.restart(language) }
    }

    func stop(_ language: Language) {
        let manager = self.manager
        Task { await manager.stop(language) }
    }

    func openExtensionsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    func shutdownBlocking(timeout: TimeInterval) {
        server?.stop()
        let manager = self.manager
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await manager.shutdownAll()
            done.signal()
        }
        // Spin the run loop so main-actor hops can complete while we wait.
        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        ProcessRegistry.killAll()
    }
}
