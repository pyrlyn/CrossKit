import Foundation

/// The platform a Kotlin target compiles for.
public enum KotlinPlatform: String, Codable, Sendable {
    case jvm
    case native
    /// JS, Wasm and Android: CrossKit can build them but not run or debug them.
    case other
}

/// One target of a Kotlin Gradle module, e.g. `jvm`, `desktop` (a renamed JVM target) or `macosArm64`.
public struct KotlinTargetInfo: Codable, Equatable, Hashable, Sendable {
    /// Gradle target name (used in task names: `jvmTest`, `linkDebugExecutableMacosArm64`).
    public var name: String
    /// DSL function that declared it (`jvm`, `macosArm64`, …).
    public var preset: String
    public var platform: KotlinPlatform

    public init(name: String, preset: String, platform: KotlinPlatform) {
        self.name = name
        self.preset = preset
        self.platform = platform
    }

    /// Native targets the current Mac can run.
    public var runsOnHost: Bool {
        switch platform {
        case .jvm: return true
        case .native: return preset == KotlinProject.hostNativePreset
        case .other: return false
        }
    }

    public var displayName: String {
        switch platform {
        case .jvm: return name == "jvm" ? "JVM" : "JVM (\(name))"
        case .native: return name == preset ? "Native \(name)" : "Native \(name) (\(preset))"
        case .other: return name
        }
    }

    /// `macosArm64` → `MacosArm64` (Gradle task suffix).
    public var taskSuffix: String { name.prefix(1).uppercased() + name.dropFirst() }
}

/// How the user picked a Kotlin target in settings or a launch configuration.
public enum KotlinTargetChoice: Equatable, Sendable {
    /// From the file's source set, else JVM, else the host's native target.
    case auto
    /// The module's first JVM target.
    case jvm
    /// The module's native target for this Mac.
    case native
    /// A target by its Gradle name.
    case named(String)

    public init(_ raw: String?) {
        switch raw?.trimmingCharacters(in: .whitespaces) ?? "" {
        case "", "auto": self = .auto
        case "jvm": self = .jvm
        case "native": self = .native
        case let name: self = .named(name)
        }
    }

    public var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .jvm: return "jvm"
        case .native: return "native"
        case .named(let name): return name
        }
    }

    public var displayName: String {
        switch self {
        case .auto: return "Auto (from the source set)"
        case .jvm: return "JVM"
        case .native: return "Kotlin/Native (this Mac)"
        case .named(let name): return name
        }
    }
}

public enum KotlinTargetError: Error, LocalizedError, Equatable {
    case noTarget(String)
    case notRunnable(String)

    public var errorDescription: String? {
        switch self {
        case .noTarget(let detail): return detail
        case .notRunnable(let detail): return detail
        }
    }
}

/// What CrossKit knows about a Kotlin Gradle module from its build script (no Gradle call needed).
public struct KotlinProject: Equatable, Sendable {
    /// The module directory (the one with build.gradle(.kts)).
    public var moduleDirectory: URL
    public var isMultiplatform: Bool
    public var targets: [KotlinTargetInfo]
    /// The Compose Multiplatform Gradle plugin is applied.
    public var usesCompose: Bool
    /// A native target declares `binaries { executable … }`.
    public var declaresNativeExecutable: Bool

    public init(moduleDirectory: URL, isMultiplatform: Bool, targets: [KotlinTargetInfo], usesCompose: Bool = false,
                declaresNativeExecutable: Bool = false) {
        self.declaresNativeExecutable = declaresNativeExecutable
        self.moduleDirectory = moduleDirectory
        self.isMultiplatform = isMultiplatform
        self.targets = targets
        self.usesCompose = usesCompose
    }

    /// Native targets a Kotlin/Native compiler on this Mac produces runnable binaries for.
    public static var hostNativePreset: String {
        #if arch(arm64)
        return "macosArm64"
        #else
        return "macosX64"
        #endif
    }

    static let nativePresets: Set<String> = [
        "macosArm64", "macosX64", "iosArm64", "iosX64", "iosSimulatorArm64", "watchosArm32", "watchosArm64",
        "watchosDeviceArm64", "watchosX64", "watchosSimulatorArm64", "tvosArm64", "tvosX64", "tvosSimulatorArm64",
        "linuxX64", "linuxArm64", "mingwX64", "androidNativeArm32", "androidNativeArm64", "androidNativeX86", "androidNativeX64",
    ]
    static let otherPresets: Set<String> = ["js", "wasmJs", "wasmWasi", "androidTarget", "android"]

    private static let targetCall = try! NSRegularExpression(
        pattern: #"(?m)^\s*("# + (["jvm"] + nativePresets.sorted() + otherPresets.sorted()).joined(separator: "|")
            + #")\s*(?:\(\s*(?:name\s*=\s*)?"([A-Za-z_]\w*)"|\(|\{|$)"#)

    /// Parses `build.gradle(.kts)` text. Non-multiplatform JVM modules get a single `jvm` target.
    public static func parse(buildScript text: String, moduleDirectory: URL) -> KotlinProject {
        let code = text.components(separatedBy: "\n").map { line -> String in
            guard let r = line.range(of: "//") else { return line }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
        let multiplatform = code.contains("kotlin(\"multiplatform\")") || code.contains("org.jetbrains.kotlin.multiplatform")
            || code.range(of: #"plugins\.kotlin\.?[mM]ultiplatform|kotlinMultiplatform"#, options: .regularExpression) != nil
        let compose = code.contains("org.jetbrains.compose") || code.range(of: #"plugins\.(jetbrains\.)?compose\b|composeMultiplatform"#, options: .regularExpression) != nil
            || code.contains("compose.desktop")
        guard multiplatform else {
            return KotlinProject(moduleDirectory: moduleDirectory, isMultiplatform: false,
                                 targets: [KotlinTargetInfo(name: "jvm", preset: "jvm", platform: .jvm)], usesCompose: compose)
        }
        var targets: [KotlinTargetInfo] = []
        let ns = code as NSString
        for match in targetCall.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let preset = ns.substring(with: match.range(at: 1))
            let name = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : preset
            let platform: KotlinPlatform = preset == "jvm" ? .jvm : nativePresets.contains(preset) ? .native : .other
            let info = KotlinTargetInfo(name: name == "android" ? "androidTarget" : name, preset: preset, platform: platform)
            if !targets.contains(where: { $0.name == info.name }) { targets.append(info) }
        }
        let executable = code.range(of: #"\bexecutable\s*[({]"#, options: .regularExpression) != nil
        return KotlinProject(moduleDirectory: moduleDirectory, isMultiplatform: true, targets: targets, usesCompose: compose,
                             declaresNativeExecutable: executable)
    }

    /// Reads the module that contains `file` (nearest build.gradle(.kts) at or above it, up to `root`).
    public static func load(file: URL, root: URL) -> KotlinProject? {
        // Keep the caller's spelling of the path (standardizing turns /private/var into /var); normalize only to compare.
        var dir = file.deletingLastPathComponent()
        let stop = root.standardizedFileURL.path
        while true {
            for name in ["build.gradle.kts", "build.gradle"] {
                let script = dir.appendingPathComponent(name)
                if let text = try? String(contentsOf: script, encoding: .utf8) {
                    return parse(buildScript: text, moduleDirectory: dir)
                }
            }
            let current = dir.standardizedFileURL.path
            if current == stop || current == "/" || !current.hasPrefix(stop) { return nil }
            dir = dir.deletingLastPathComponent()
        }
    }

    public var jvmTargets: [KotlinTargetInfo] { targets.filter { $0.platform == .jvm } }
    public var nativeTargets: [KotlinTargetInfo] { targets.filter { $0.platform == .native } }
    public var hostNativeTarget: KotlinTargetInfo? { nativeTargets.first { $0.runsOnHost } }

    /// `src/<sourceSet>/kotlin/…` → `<sourceSet>` (e.g. `jvmMain`, `commonTest`).
    public static func sourceSet(of file: URL, moduleDirectory: URL) -> String? {
        let module = moduleDirectory.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(module + "/src/") else { return nil }
        let rest = path.dropFirst(module.count + 5)
        guard let set = rest.split(separator: "/").first else { return nil }
        return String(set)
    }

    /// The target a file builds for, given the user's choice.
    ///
    /// Source sets decide first: `jvmMain`/`desktopTest` belong to that target; `nativeMain`, `appleMain`,
    /// `macosMain`, … to the host's native target. Shared code (`commonMain`) uses the choice; `auto` prefers JVM.
    public func target(for file: URL, choice: KotlinTargetChoice) throws -> KotlinTargetInfo {
        if !isMultiplatform { return targets[0] }
        guard !targets.isEmpty else {
            throw KotlinTargetError.noTarget("No Kotlin targets found in \(moduleDirectory.lastPathComponent)'s build script. Declare jvm() or a native target such as \(Self.hostNativePreset)() in kotlin { }.")
        }
        if let set = Self.sourceSet(of: file, moduleDirectory: moduleDirectory) {
            let base = set.replacingOccurrences(of: #"(Main|Test)$"#, with: "", options: .regularExpression)
            if let exact = targets.first(where: { $0.name == base }) { return exact }
            let nativeSets: Set<String> = ["native", "apple", "macos", "posix", "unix", "darwin"]
            if nativeSets.contains(base) || base.hasPrefix("macos") {
                if let host = hostNativeTarget { return host }
            }
        }
        switch choice {
        case .named(let name):
            if let match = targets.first(where: { $0.name == name || $0.preset == name }) { return match }
            throw KotlinTargetError.noTarget("Kotlin target \"\(name)\" is not declared in \(moduleDirectory.lastPathComponent). Available: \(targets.map(\.name).joined(separator: ", ")).")
        case .jvm:
            if let jvm = jvmTargets.first { return jvm }
            throw KotlinTargetError.noTarget("\(moduleDirectory.lastPathComponent) has no JVM target. Add jvm() to kotlin { } or pick a native target in CrossKit settings.")
        case .native:
            if let host = hostNativeTarget { return host }
            throw KotlinTargetError.noTarget("\(moduleDirectory.lastPathComponent) has no Kotlin/Native target for this Mac. Add \(Self.hostNativePreset)() to kotlin { } or pick the JVM target in CrossKit settings.")
        case .auto:
            if let jvm = jvmTargets.first { return jvm }
            if let host = hostNativeTarget { return host }
            return targets[0]
        }
    }

    // MARK: Gradle task names and outputs

    /// `test` for a plain JVM module, `<target>Test` for multiplatform (`jvmTest`, `macosArm64Test`).
    public func testTask(for target: KotlinTargetInfo) -> String {
        isMultiplatform ? "\(target.name)Test" : "test"
    }

    /// JUnit XML reports written by the test task.
    public func testReportsDirectory(for target: KotlinTargetInfo) -> URL {
        moduleDirectory.appendingPathComponent("build/test-results/\(testTask(for: target))")
    }

    public func linkExecutableTask(for target: KotlinTargetInfo, debug: Bool = true) -> String {
        "link\(debug ? "Debug" : "Release")Executable\(target.taskSuffix)"
    }

    public func linkTestTask(for target: KotlinTargetInfo) -> String { "linkDebugTest\(target.taskSuffix)" }

    public func nativeExecutableDirectory(for target: KotlinTargetInfo, debug: Bool = true) -> URL {
        moduleDirectory.appendingPathComponent("build/bin/\(target.name)/\(debug ? "debug" : "release")Executable")
    }

    public func nativeTestBinary(for target: KotlinTargetInfo) -> URL {
        moduleDirectory.appendingPathComponent("build/bin/\(target.name)/debugTest/test.kexe")
    }

    /// The `.kexe` a link task produced (the newest one when the module declares several executables).
    public static func nativeExecutable(in directory: URL) -> URL? {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "kexe" && fm.isExecutableFile(atPath: $0.path) }
        return files.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// Kotlin/Native's LLDB pretty printers (`konan_lldb.py`), newest Kotlin first.
    public static func konanLLDBScript(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let konan = home.appendingPathComponent(".konan")
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: konan.path)) ?? [])
            .filter { $0.hasPrefix("kotlin-native-prebuilt-") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for dir in dirs {
            let script = konan.appendingPathComponent(dir).appendingPathComponent("tools/konan_lldb.py")
            if FileManager.default.fileExists(atPath: script.path) { return script }
        }
        return nil
    }
}
