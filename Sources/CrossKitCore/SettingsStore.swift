import Foundation

public struct ServerStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case stopped, starting, running, restarting, error, disabled, notFound
    }

    public var state: State
    public var pid: Int32?
    public var binaryPath: String?
    public var rootPath: String?
    public var lastError: String?
    public var restartCount: Int
    public var updatedAt: Date

    public init(state: State = .stopped, pid: Int32? = nil, binaryPath: String? = nil, rootPath: String? = nil,
                lastError: String? = nil, restartCount: Int = 0, updatedAt: Date = Date()) {
        self.state = state
        self.pid = pid
        self.binaryPath = binaryPath
        self.rootPath = rootPath
        self.lastError = lastError
        self.restartCount = restartCount
        self.updatedAt = updatedAt
    }
}

/// All user settings, persisted in UserDefaults of the shared App Group so the host app and the
/// extension read the same values. Missing keys fall back to built-in defaults.
public final class SettingsStore: @unchecked Sendable {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static func shared() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: SharedPaths.appGroupIdentifier) ?? .standard)
    }

    private func key(_ language: Language, _ name: String) -> String { "\(language.rawValue).\(name)" }

    // MARK: Language enablement

    public func isEnabled(_ language: Language) -> Bool {
        defaults.object(forKey: key(language, "enabled")) as? Bool ?? true
    }

    public func setEnabled(_ enabled: Bool, for language: Language) {
        defaults.set(enabled, forKey: key(language, "enabled"))
    }

    // MARK: Server binary

    /// A user-chosen binary; nil means auto-detect.
    public func customServerPath(for language: Language) -> String? {
        guard let path = defaults.string(forKey: key(language, "serverPath")), !path.isEmpty else { return nil }
        return path
    }

    public func setCustomServerPath(_ path: String?, for language: Language) {
        if let path, !path.isEmpty {
            defaults.set(path, forKey: key(language, "serverPath"))
        } else {
            defaults.removeObject(forKey: key(language, "serverPath"))
        }
    }

    public func arguments(for language: Language) -> [String] {
        defaults.stringArray(forKey: key(language, "arguments")) ?? language.defaultArguments
    }

    public func setArguments(_ arguments: [String]?, for language: Language) {
        defaults.set(arguments, forKey: key(language, "arguments"))
    }

    public func fileExtensions(for language: Language) -> [String] {
        defaults.stringArray(forKey: key(language, "extensions")) ?? language.defaultExtensions
    }

    public func setFileExtensions(_ extensions: [String]?, for language: Language) {
        defaults.set(extensions, forKey: key(language, "extensions"))
    }

    // MARK: Features

    public func isFeatureEnabled(_ feature: Feature, for language: Language) -> Bool {
        defaults.object(forKey: key(language, "feature.\(feature.rawValue)")) as? Bool ?? true
    }

    public func setFeature(_ feature: Feature, enabled: Bool, for language: Language) {
        defaults.set(enabled, forKey: key(language, "feature.\(feature.rawValue)"))
    }

    // MARK: Tests

    /// The user's runner choice; nil means auto-detect per project.
    public func testRunner(for language: Language) -> TestRunnerKind? {
        defaults.string(forKey: key(language, "testRunner")).flatMap(TestRunnerKind.init(rawValue:))
    }

    public func setTestRunner(_ kind: TestRunnerKind?, for language: Language) {
        if let kind { defaults.set(kind.rawValue, forKey: key(language, "testRunner")) } else {
            defaults.removeObject(forKey: key(language, "testRunner"))
        }
    }

    /// Custom zig / cargo / gradle binary; nil means auto-detect.
    public func testExecutablePath(for language: Language) -> String? {
        guard let path = defaults.string(forKey: key(language, "testExecutable")), !path.isEmpty else { return nil }
        return path
    }

    public func setTestExecutablePath(_ path: String?, for language: Language) {
        if let path, !path.isEmpty { defaults.set(path, forKey: key(language, "testExecutable")) } else {
            defaults.removeObject(forKey: key(language, "testExecutable"))
        }
    }

    /// Extra arguments appended to every test command (e.g. `--offline`, `--release`).
    public func testArguments(for language: Language) -> [String] {
        defaults.stringArray(forKey: key(language, "testArguments")) ?? []
    }

    public func setTestArguments(_ arguments: [String], for language: Language) {
        defaults.set(arguments, forKey: key(language, "testArguments"))
    }

    public var testTimeout: TimeInterval {
        get { defaults.object(forKey: "testTimeoutSeconds") as? Double ?? 15 * 60 }
        set { defaults.set(newValue, forKey: "testTimeoutSeconds") }
    }

    // MARK: Lifecycle

    /// Servers idle longer than this are shut down. 0 disables idle shutdown.
    public var idleTimeout: TimeInterval {
        get { defaults.object(forKey: "idleTimeoutSeconds") as? Double ?? 15 * 60 }
        set { defaults.set(newValue, forKey: "idleTimeoutSeconds") }
    }

    // MARK: Status (written by the host, readable by the extension)

    public func status(for language: Language) -> ServerStatus {
        guard let data = defaults.data(forKey: key(language, "status")),
              let status = try? JSONDecoder().decode(ServerStatus.self, from: data) else {
            return ServerStatus()
        }
        return status
    }

    public func writeStatus(_ status: ServerStatus, for language: Language) {
        if let data = try? JSONEncoder().encode(status) {
            defaults.set(data, forKey: key(language, "status"))
        }
    }

    // MARK: Helpers

    public func language(forPath path: String) -> Language? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return Language.allCases.first { fileExtensions(for: $0).map { $0.lowercased() }.contains(ext) }
    }

    public func resetToDefaults(for language: Language) {
        for name in ["enabled", "serverPath", "arguments", "extensions", "testRunner", "testExecutable", "testArguments"] {
            defaults.removeObject(forKey: key(language, name))
        }
        for feature in Feature.allCases {
            defaults.removeObject(forKey: key(language, "feature.\(feature.rawValue)"))
        }
    }
}
