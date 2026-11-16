import Foundation

/// Builds, launches and tracks debug sessions for the bridge handler and the Debugger window.
public final class DebugService: @unchecked Sendable {
    public typealias TerminalLauncher = @Sendable (_ script: URL) throws -> Void

    public var planner: LaunchPlanner
    /// Opens a `.command` script in Terminal (replaced in tests).
    public var terminalLauncher: TerminalLauncher
    /// Called whenever a session changes (the host mirrors it into the UI).
    public var onChange: (@Sendable (DebugSessionSnapshot) -> Void)?
    private let lock = NSLock()
    private var sessions: [String: DebugSession] = [:]

    public init(planner: LaunchPlanner, terminalLauncher: @escaping TerminalLauncher = DebugService.openInTerminal) {
        self.planner = planner
        self.terminalLauncher = terminalLauncher
    }

    public static let openInTerminal: TerminalLauncher = { script in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", script.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw DebugError.launchFailed("could not open Terminal") }
    }

    public func session(_ id: String) -> DebugSession? { lock.withLock { sessions[id] } }
    public var allSessions: [DebugSession] { lock.withLock { Array(sessions.values) } }

    public func stopAll() async {
        for session in allSessions { await session.stop() }
    }

    // MARK: Start

    public func start(language: Language, file: URL, text bufferText: String, cursorLine bufferLine: Int, target: DebugTarget) async throws -> DebugLaunchInfo {
        let (text, cursorLine) = Self.matchSavedFile(file: file, text: bufferText, line: bufferLine)
        var plan = try planner.plan(language: language, file: file, text: text, cursorLine: cursorLine, target: target)
        let resolver = planner.resolver
        let id = UUID().uuidString
        let sessionDirectory = planner.workDirectory.appendingPathComponent("sessions/\(id.prefix(8))")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        // 1. Build.
        var lastOutput = ""
        for command in plan.build {
            guard let exe = command.first else { continue }
            let env = resolver.environment(language: language, executable: URL(fileURLWithPath: exe))
            let outcome = try await TestExecutor.run(
                TestCommand(kind: .zigTest, executable: exe, arguments: Array(command.dropFirst()), workingDirectory: plan.projectRoot,
                            environment: env, reportsDirectory: nil),
                timeout: planner.settings.testTimeout)
            lastOutput = outcome.output
            if outcome.timedOut || outcome.exitCode != 0 {
                throw DebugError.buildFailed(command.map(Self.shellQuote).joined(separator: " "), output: outcome.output)
            }
        }

        // 2. Program.
        let program: String
        var jvmCommand: [String]?
        switch plan.programSource {
        case .path(let path):
            program = path
        case .cargoArtifact(let target, let test):
            guard let exe = LaunchPlanner.cargoExecutable(fromJSONLines: lastOutput, target: target, test: test, sourceFile: nil) else {
                throw DebugError.noProgram("cargo built no executable for \(file.lastPathComponent). Add a binary target (src/main.rs) or set a program in the launch configuration.")
            }
            program = exe
        case .zigInstall(let preferred):
            let bin = URL(fileURLWithPath: plan.projectRoot).appendingPathComponent("zig-out/bin")
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []).sorted()
                .filter { FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent($0).path) }
            guard let name = files.first(where: { $0 == preferred }) ?? files.first(where: { $0 == file.deletingPathExtension().lastPathComponent }) ?? files.first else {
                throw DebugError.noProgram("`zig build install` produced no executable in zig-out/bin. Add b.installArtifact(exe) to build.zig or set a program in the launch configuration.")
            }
            program = bin.appendingPathComponent(name).path
        case .jvmMain(let mainClass):
            guard let line = lastOutput.split(separator: "\n").last(where: { $0.hasPrefix("CROSSKIT_CLASSPATH=") }) else {
                throw DebugError.noProgram("Gradle did not report a runtime classpath. Is the Kotlin JVM plugin applied in \(plan.projectRoot)?")
            }
            let classpath = String(line.dropFirst("CROSSKIT_CLASSPATH=".count))
            program = mainClass
            jvmCommand = ["-cp", classpath, mainClass] + plan.arguments
        case .gradleTest(let command):
            program = command.first ?? "gradle"
            jvmCommand = command
        }
        if plan.language != .kotlin, !FileManager.default.isExecutableFile(atPath: program) {
            throw DebugError.noProgram("Program not found: \(program)")
        }

        let snapshot = DebugSessionSnapshot(
            id: id, title: plan.title, language: language, debugger: plan.debugger, target: target, program: program,
            projectRoot: plan.projectRoot, startedAt: Date(), state: .starting, breakpoints: plan.breakpoints)
        let session = DebugSession(snapshot: snapshot) { [weak self] snap in self?.onChange?(snap) }
        lock.withLock { sessions[id] = session }
        session.update { _ in }

        let bp = plan.breakpoints.first
        let where_ = bp.map { "\(($0.file as NSString).lastPathComponent):\($0.line + 1)" } ?? "none"
        var info = DebugLaunchInfo(sessionID: id, language: language, debugger: plan.debugger, program: program, title: plan.title,
                                   breakpoint: bp, message: "")
        info.warning = Self.unsavedWarning(file: file, text: text)

        // 3. Launch.
        do {
            switch plan.debugger {
            case .lldbDAP, .codelldb:
                let env = resolver.environment(language: language, executable: URL(fileURLWithPath: program))
                try await session.startDAP(adapter: plan.debuggerPath, plan: plan, program: program, environment: env)
                info.message = "Debugging \(plan.title) with \(plan.debugger.toolName); breakpoint at \(where_). Controls are in CrossKit › Debugger."
            case .lldb:
                let script = try writeLLDBScript(plan: plan, program: program, directory: sessionDirectory)
                try terminalLauncher(script)
                session.update { $0.state = .external }
                info.message = "Started lldb in Terminal for \(plan.title); breakpoint at \(where_)."
            case .jdb, .jdwpAttach:
                plan.jdwpPort = plan.jdwpPort == 0 ? Self.freePort() : plan.jdwpPort
                let address = "127.0.0.1:\(plan.jdwpPort)"
                try await startJVM(session: session, plan: plan, command: jvmCommand ?? [], address: address)
                let bpCommand = "stop at \(plan.jvmBreakpointClass ?? program):\((bp?.line ?? 0) + 1)"
                // jdb from the same JDK as the chosen java (a custom java path in settings included).
                let sibling = URL(fileURLWithPath: plan.debuggerPath).deletingLastPathComponent().appendingPathComponent("jdb").path
                let jdb = FileManager.default.isExecutableFile(atPath: sibling) ? sibling : planner.debuggers.jdb()?.path ?? "jdb"
                let attach = "\(Self.shellQuote(jdb)) -attach \(address)"
                session.update { $0.jdwpAddress = address; $0.attachCommand = attach; $0.state = .waitingForDebugger }
                info.jdwpAddress = address
                if plan.debugger == .jdb {
                    let script = try writeJDBScript(jdb: jdb, address: address, breakpoint: bpCommand, plan: plan, directory: sessionDirectory)
                    try terminalLauncher(script)
                    info.message = "JVM waits on \(address); jdb opened in Terminal with `\(bpCommand)`."
                } else {
                    info.message = "JVM waits for a debugger on \(address) (JDWP). Attach from your IDE (IntelliJ IDEA: Run › Attach to Process or a Remote JVM Debug configuration) and set a breakpoint at \(where_)."
                }
            }
        } catch {
            session.update { $0.state = .failed; $0.error = error.localizedDescription }
            await session.stop()
            session.update { $0.state = .failed }
            throw error
        }
        return info
    }

    // MARK: JVM

    private func startJVM(session: DebugSession, plan: LaunchPlan, command: [String], address: String) async throws {
        var env = planner.resolver.environment(language: .kotlin, executable: URL(fileURLWithPath: plan.debuggerPath))
        for (k, v) in plan.environment { env[k] = v }
        let executable: String
        var arguments: [String]
        let agent = "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=\(address)"
        if case .gradleTest = plan.programSource {
            executable = command[0]
            arguments = Array(command.dropFirst()) + ["-Pcrosskit.jdwp=\(address)"]
        } else {
            executable = plan.debuggerPath
            arguments = [agent] + command
        }
        let listening = ListenFlag()
        let process = try ChildProcess(
            executable: executable, arguments: arguments, environment: env, currentDirectory: plan.workingDirectory,
            onStdout: { [weak session] data in
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                if text.contains("Listening for transport dt_socket") { listening.set() }
                session?.appendOutput(text)
            },
            onStderr: { [weak session] data in
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                if text.contains("Listening for transport dt_socket") { listening.set() }
                session?.appendOutput(text)
            },
            onExit: { [weak session] code in
                session?.update { s in
                    s.exitCode = Int(code)
                    if s.state.isActive || s.state == .waitingForDebugger { s.state = .exited }
                }
            })
        session.jvm = process
        session.update { $0.debuggeePID = Int(process.pid); $0.state = .starting }
        let timeout: TimeInterval = { if case .gradleTest = plan.programSource { return planner.settings.testTimeout }; return 60 }()
        let deadline = Date().addingTimeInterval(timeout)
        while !listening.isSet {
            if !process.isRunning {
                throw DebugError.launchFailed("the JVM exited before the debugger could attach.\n\(String(session.snapshot.output.suffix(2000)))")
            }
            if Date() > deadline { throw DebugError.launchFailed("the JVM did not open JDWP on \(address) within \(Int(timeout))s.") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private final class ListenFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    // MARK: Terminal scripts

    /// lldb commands: create the target, set the breakpoint, launch with args/env/cwd.
    public static func lldbCommands(plan: LaunchPlan, program: String) -> String {
        var lines = ["target create \(lldbQuote(program))"]
        if !plan.environment.isEmpty {
            lines.append("settings set target.env-vars " + plan.environment.sorted { $0.key < $1.key }.map { lldbQuote("\($0.key)=\($0.value)") }.joined(separator: " "))
        }
        for bp in plan.breakpoints {
            lines.append("breakpoint set --file \(lldbQuote(bp.file)) --line \(bp.line + 1)")
        }
        var launch = "process launch -w \(lldbQuote(plan.workingDirectory))"
        if !plan.arguments.isEmpty { launch += " -- " + plan.arguments.map(lldbQuote).joined(separator: " ") }
        lines.append(launch)
        return lines.joined(separator: "\n") + "\n"
    }

    func writeLLDBScript(plan: LaunchPlan, program: String, directory: URL) throws -> URL {
        let commands = directory.appendingPathComponent("lldb-commands")
        try Self.lldbCommands(plan: plan, program: program).write(to: commands, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("CrossKit Debug.command")
        try """
        #!/bin/sh
        # CrossKit: \(Self.commentLine(plan.title))
        cd \(Self.shellQuote(plan.workingDirectory))
        exec \(Self.shellQuote(plan.debuggerPath)) -s \(Self.shellQuote(commands.path))

        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func writeJDBScript(jdb: String, address: String, breakpoint: String, plan: LaunchPlan, directory: URL) throws -> URL {
        // jdb reads .jdbrc from the current directory on start.
        try "\(breakpoint)\nrun\n".write(to: directory.appendingPathComponent(".jdbrc"), atomically: true, encoding: .utf8)
        let sources = ["src/main/kotlin", "src/test/kotlin", "src/main/java", "src/test/java"]
            .map { URL(fileURLWithPath: plan.projectRoot).appendingPathComponent($0).path }.joined(separator: ":")
        let script = directory.appendingPathComponent("CrossKit Debug.command")
        try """
        #!/bin/sh
        # CrossKit: \(Self.commentLine(plan.title))
        cd \(Self.shellQuote(directory.path))
        exec \(Self.shellQuote(jdb)) -sourcepath \(Self.shellQuote(sources)) -attach \(address)

        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    // MARK: Helpers

    /// The debugger sees the saved file. If the buffer only differs by unsaved `// [CrossKit]` annotation
    /// lines, drop them and shift the cursor line so the breakpoint lands on the right source line.
    static func matchSavedFile(file: URL, text: String, line: Int) -> (String, Int) {
        guard let disk = try? String(contentsOf: file, encoding: .utf8) else { return (text, line) }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trim(disk) != trim(text) else { return (text, line) }
        let lines = text.components(separatedBy: "\n")
        let annotations = lines.indices.filter { EditorCommandEngine.isAnnotation(lines[$0]) }
        guard !annotations.isEmpty else { return (text, line) }
        let cleaned = lines.enumerated().filter { !annotations.contains($0.offset) }.map(\.element).joined(separator: "\n")
        guard trim(cleaned) == trim(disk) else { return (text, line) }
        return (cleaned, line - annotations.filter { $0 < line }.count)
    }

    static func unsavedWarning(file: URL, text: String) -> String? {
        let disk = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return disk.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
            ? nil : "The editor buffer has unsaved changes; the debugger uses the saved file, so lines may not match."
    }

    /// Text for a `#` comment in a shell script: a line break would end the comment and run the rest.
    static func commentLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ")
    }

    public static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func lldbQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 5005 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : 5005
    }
}
