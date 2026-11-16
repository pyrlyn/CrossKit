import XCTest
@testable import CrossKitCore

/// Debug smoke tests through the extension path:
/// EditorCommandEngine → BridgeClient → BridgeServer → BridgeHandler → DebugService → debugger.
/// Each starts a session, hits the breakpoint at the cursor, runs to a clean exit, and checks that
/// no process is left behind. Skips when the toolchain or debugger is missing.
final class DebugEndToEndTests: XCTestCase {
    struct Harness {
        var root: URL
        var settings: SettingsStore
        var handler: BridgeHandler
        var transport: BridgeClient
        var server: BridgeServer
        var suite: String
        var scripts: ScriptCollector

        func file(_ path: String) -> URL { root.appendingPathComponent(path) }

        func buffer(_ path: String, line: Int) throws -> EditorBuffer {
            let url = file(path)
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").map { $0 + "\n" }
            return EditorBuffer(lines: lines, selection: .caret(line, 4), contentUTI: "", filePath: url.path)
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: root)
            removeDefaults(suite)
        }
    }

    func makeHarness(_ name: String, files: [String: String]) throws -> Harness {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/ck-debug-\(name)-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let suite = "dev.pyrlyn.CrossKit.e2e-debug.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.testTimeout = 600
        let manager = ServerManager(settings: settings)
        let handler = BridgeHandler(manager: manager, settings: settings, scratchDirectory: root.appendingPathComponent(".scratch"))
        handler.debugService.planner.workDirectory = root.appendingPathComponent(".crosskit-debug")
        let scripts = ScriptCollector()
        handler.debugService.terminalLauncher = { scripts.add($0) }
        let server = BridgeServer(portName: "dev.pyrlyn.CrossKit.e2e-debug.\(UUID().uuidString.prefix(6))") { await handler.handle($0) }
        try server.start()
        let transport = BridgeClient(portName: server.portName, timeout: 660)
        return Harness(root: root, settings: settings, handler: handler, transport: transport, server: server, suite: suite, scripts: scripts)
    }

    // MARK: Zig / Rust with lldb-dap (host-managed session)

    static let zigSource = """
    const std = @import("std");

    fn add(a: i32, b: i32) i32 {
        const sum = a + b;
        return sum;
    }

    pub fn main() void {
        const result = add(40, 2);
        std.debug.print("result {d}\\n", .{result});
    }

    test "add works" {
        const value = add(1, 2);
        try std.testing.expectEqual(@as(i32, 3), value);
    }

    """

    func testZigDebugFileAndTestWithLLDBDAP() async throws {
        guard TestToolchain().zig() != nil else { throw XCTSkip("zig not found") }
        guard DebuggerLocator().find(.lldbDAP) != nil else { throw XCTSkip("lldb-dap not found") }
        let h = try makeHarness("zig", files: ["main.zig": Self.zigSource])
        defer { h.tearDown() }
        h.settings.setDebugger(.lldbDAP, for: .zig)
        // Breakpoint on `return sum;` (line 4), expecting a = 40, b = 2.
        try await runDAPSession(h, command: .debugFileAtCursor, buffer: h.buffer("main.zig", line: 4), expectLine: 5,
                                expectVariables: ["a": "40", "b": "2"], expectExit: 0)
        // Debug Test at Cursor inside the test: stops on `try std.testing...` (line 14).
        try await runDAPSession(h, command: .debugTestAtCursor, buffer: h.buffer("main.zig", line: 14), expectLine: 15,
                                expectVariables: ["value": "3"], expectExit: 0)
    }

    func testRustDebugFileAndTestWithLLDBDAP() async throws {
        guard TestToolchain().cargo() != nil else { throw XCTSkip("cargo not found") }
        guard DebuggerLocator().find(.lldbDAP) != nil else { throw XCTSkip("lldb-dap not found") }
        let main = """
        fn add(a: i32, b: i32) -> i32 {
            let sum = a + b;
            sum
        }

        fn main() {
            let result = add(40, 2);
            println!("result {}", result);
        }

        #[cfg(test)]
        mod tests {
            use super::*;

            #[test]
            fn adds() {
                let value = add(1, 2);
                assert_eq!(value, 3);
            }
        }

        """
        let h = try makeHarness("rust", files: [
            "Cargo.toml": "[package]\nname = \"sample\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n",
            "src/main.rs": main,
        ])
        defer { h.tearDown() }
        h.settings.setDebugger(.lldbDAP, for: .rust)
        try await runDAPSession(h, command: .debugFileAtCursor, buffer: h.buffer("src/main.rs", line: 1), expectLine: 2,
                                expectVariables: ["a": "40", "b": "2"], expectExit: 0)
        try await runDAPSession(h, command: .debugTestAtCursor, buffer: h.buffer("src/main.rs", line: 17), expectLine: 18,
                                expectVariables: ["value": "3"], expectExit: 0)
    }

    private func runDAPSession(_ h: Harness, command: EditorCommand, buffer: EditorBuffer, expectLine: Int,
                               expectVariables: [String: String], expectExit: Int) async throws {
        let outcome = try await EditorCommandEngine().run(command, buffer: buffer, transport: h.transport)
        print("[e2e-debug] \(command.rawValue): \(outcome.message ?? "")")
        XCTAssertTrue(outcome.operations.isEmpty, "debugging must not edit the buffer")
        let session = try XCTUnwrap(h.handler.debugService.allSessions.max { $0.snapshot.startedAt < $1.snapshot.startedAt })
        let stopped = try await waitFor(session, timeout: 60) { $0.state == .stopped && !$0.frames.isEmpty && !$0.variables.isEmpty }
        let top = try XCTUnwrap(stopped.frames.first)
        XCTAssertEqual(top.file.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       buffer.filePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        XCTAssertEqual(top.line, expectLine, "stopped at \(top)")
        XCTAssertTrue(stopped.stopReason?.lowercased().contains("breakpoint") == true, stopped.stopReason ?? "")
        let values = Dictionary(stopped.variables.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        for (name, value) in expectVariables {
            XCTAssertEqual(values[name], value, "variable \(name) in \(stopped.variables)")
        }
        // Run to the end (a line can have several locations, e.g. inside assert_eq!).
        var ended = session.snapshot
        for _ in 0..<10 {
            try await session.resume()
            ended = try await waitFor(session, timeout: 60) { $0.state == .exited || ($0.state == .stopped && !$0.frames.isEmpty) }
            if ended.state == .exited { break }
        }
        XCTAssertEqual(ended.state, .exited)
        XCTAssertEqual(ended.exitCode, expectExit, ended.output)
        await session.stop()
        try await assertNoLeftovers(session)
    }

    // MARK: lldb in Terminal (the generated script is run in batch mode instead of Terminal)

    func testZigDebugWithLLDBTerminalScript() async throws {
        guard TestToolchain().zig() != nil else { throw XCTSkip("zig not found") }
        guard let lldb = DebuggerLocator().find(.lldb) else { throw XCTSkip("lldb not found") }
        let h = try makeHarness("zig-lldb", files: ["main.zig": Self.zigSource])
        defer { h.tearDown() }
        h.settings.setDebugger(.lldb, for: .zig)
        let outcome = try await EditorCommandEngine().run(.debugFileAtCursor, buffer: h.buffer("main.zig", line: 4), transport: h.transport)
        XCTAssertTrue(outcome.message?.contains("lldb in Terminal") == true, outcome.message ?? "")
        let script = try XCTUnwrap(h.scripts.last)
        let commands = script.deletingLastPathComponent().appendingPathComponent("lldb-commands")
        let output = try runToEnd(lldb.path, ["--batch", "-s", commands.path, "-o", "frame variable", "-o", "continue"], cwd: h.root.path)
        XCTAssertTrue(output.contains("stop reason = breakpoint"), output)
        XCTAssertTrue(output.contains("main.zig:5"), output)
        XCTAssertTrue(output.contains("a = 40"), output)
        XCTAssertTrue(output.contains("exited with status = 0"), output)
    }

    // MARK: Kotlin with JDWP + jdb

    func testKotlinDebugFileWithJDWP() async throws {
        guard TestToolchain().gradle() != nil else { throw XCTSkip("gradle not found") }
        guard let jdb = DebuggerLocator().jdb() else { throw XCTSkip("no JDK with jdb found") }
        let offline = FileManager.default.fileExists(atPath: ServerLocator().home
            .appendingPathComponent(".gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib").path)
        let h = try makeHarness("kotlin", files: [
            "settings.gradle.kts": "rootProject.name = \"sample\"\n",
            "build.gradle.kts": "plugins { kotlin(\"jvm\") version \"2.4.21\" }\nrepositories { mavenCentral() }\n",
            "src/main/kotlin/demo/Main.kt": """
            package demo

            fun add(a: Int, b: Int): Int {
                val sum = a + b
                return sum
            }

            fun main() {
                val result = add(40, 2)
                println("result $result")
            }

            """,
        ])
        defer { h.tearDown() }
        h.settings.setDebugger(.jdb, for: .kotlin)
        h.settings.jdwpPort = 0
        if offline { h.settings.setTestArguments(["--offline"], for: .kotlin) }
        let outcome = try await EditorCommandEngine().run(.debugFileAtCursor, buffer: h.buffer("src/main/kotlin/demo/Main.kt", line: 4),
                                                          transport: h.transport)
        print("[e2e-debug] kotlin: \(outcome.message ?? "")")
        let session = try XCTUnwrap(h.handler.debugService.allSessions.first)
        let waiting = session.snapshot
        XCTAssertEqual(waiting.state, .waitingForDebugger)
        let address = try XCTUnwrap(waiting.jdwpAddress)
        XCTAssertTrue(outcome.message?.contains("stop at demo.MainKt:5") == true, outcome.message ?? "")

        // Attach jdb exactly like the generated Terminal script (it reads .jdbrc from the session directory).
        let script = try XCTUnwrap(h.scripts.last)
        let sessionDir = script.deletingLastPathComponent()
        let jdbrc = try String(contentsOf: sessionDir.appendingPathComponent(".jdbrc"), encoding: .utf8)
        XCTAssertEqual(jdbrc, "stop at demo.MainKt:5\nrun\n")
        let collector = OutputCollector()
        let jdbProcess = try ChildProcess(executable: jdb.path, arguments: ["-attach", address], environment: ProcessInfo.processInfo.environment,
                                          currentDirectory: sessionDir.path,
                                          onStdout: { collector.add($0) }, onStderr: { collector.add($0) }, onExit: { _ in })
        defer { jdbProcess.killGroup() }
        try await collector.wait(for: "Breakpoint hit", timeout: 60)
        try await collector.wait(for: "demo.MainKt.add(), line=5", timeout: 10)
        try jdbProcess.write(Data("locals\n".utf8))
        try await collector.wait(for: "sum = 42", timeout: 20)
        try jdbProcess.write(Data("cont\n".utf8))
        let ended = try await waitFor(session, timeout: 60) { $0.state == .exited }
        XCTAssertEqual(ended.exitCode, 0, ended.output)
        XCTAssertTrue(ended.output.contains("result 42"), ended.output)
        XCTAssertTrue(jdbProcess.waitForExit(timeout: 10), "jdb should exit when the VM exits")
        await session.stop()
        try await assertNoLeftovers(session)
    }

    func testKotlinDebugTestWithJDWP() async throws {
        guard TestToolchain().gradle() != nil else { throw XCTSkip("gradle not found") }
        guard let jdb = DebuggerLocator().jdb() else { throw XCTSkip("no JDK with jdb found") }
        let offline = FileManager.default.fileExists(atPath: ServerLocator().home
            .appendingPathComponent(".gradle/caches/modules-2/files-2.1/org.junit/junit-bom/5.13.4").path)
        let h = try makeHarness("kotlin-test", files: [
            "settings.gradle.kts": "rootProject.name = \"sample\"\n",
            "build.gradle.kts": """
            plugins { kotlin("jvm") version "2.4.21" }
            repositories { mavenCentral() }
            dependencies {
                testImplementation(platform("org.junit:junit-bom:5.13.4"))
                testImplementation("org.junit.jupiter:junit-jupiter")
                testRuntimeOnly("org.junit.platform:junit-platform-launcher")
            }
            tasks.test { useJUnitPlatform() }

            """,
            "src/main/kotlin/demo/Calc.kt": "package demo\n\nfun add(a: Int, b: Int) = a + b\n",
            "src/test/kotlin/demo/CalcTest.kt": """
            package demo

            import org.junit.jupiter.api.Assertions.assertEquals
            import org.junit.jupiter.api.Test

            class CalcTest {
                @Test
                fun adds() {
                    val value = add(1, 2)
                    assertEquals(3, value)
                }
            }

            """,
        ])
        defer { h.tearDown() }
        h.settings.setDebugger(.jdb, for: .kotlin)
        h.settings.jdwpPort = 0
        if offline { h.settings.setTestArguments(["--offline"], for: .kotlin) }
        let outcome = try await EditorCommandEngine().run(.debugTestAtCursor, buffer: h.buffer("src/test/kotlin/demo/CalcTest.kt", line: 9),
                                                          transport: h.transport)
        print("[e2e-debug] kotlin test: \(outcome.message ?? "")")
        XCTAssertTrue(outcome.message?.contains("stop at demo.CalcTest:10") == true, outcome.message ?? "")
        let session = try XCTUnwrap(h.handler.debugService.allSessions.first)
        let address = try XCTUnwrap(session.snapshot.jdwpAddress)
        let sessionDir = try XCTUnwrap(h.scripts.last).deletingLastPathComponent()
        let collector = OutputCollector()
        let jdbProcess = try ChildProcess(executable: jdb.path, arguments: ["-attach", address], environment: ProcessInfo.processInfo.environment,
                                          currentDirectory: sessionDir.path,
                                          onStdout: { collector.add($0) }, onStderr: { collector.add($0) }, onExit: { _ in })
        defer { jdbProcess.killGroup() }
        try await collector.wait(for: "demo.CalcTest.adds(), line=10", timeout: 60)
        try jdbProcess.write(Data("locals\n".utf8))
        try await collector.wait(for: "value = 3", timeout: 20)
        try jdbProcess.write(Data("cont\n".utf8))
        let ended = try await waitFor(session, timeout: 120) { $0.state == .exited }
        XCTAssertEqual(ended.exitCode, 0, ended.output)
        XCTAssertTrue(ended.output.contains("BUILD SUCCESSFUL"), ended.output)
        await session.stop()
        try await assertNoLeftovers(session)
    }

    // MARK: Helpers

    private func waitFor(_ session: DebugSession, timeout: TimeInterval,
                         _ condition: (DebugSessionSnapshot) -> Bool) async throws -> DebugSessionSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snap = session.snapshot
            if condition(snap) { return snap }
            if snap.state == .failed { XCTFail("session failed: \(snap.error ?? "")\n\(snap.output)"); return snap }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let snap = session.snapshot
        XCTFail("timed out; state \(snap.state) reason \(snap.stopReason ?? "-") frames \(snap.frames.prefix(3))\n\(snap.output)")
        return snap
    }

    private func assertNoLeftovers(_ session: DebugSession) async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        if let pid = session.snapshot.debuggeePID {
            XCTAssertFalse(kill(pid_t(pid), 0) == 0, "debuggee \(pid) is still running")
        }
        for process in [session.dap?.process, session.jvm].compactMap({ $0 }) {
            XCTAssertFalse(process.isRunning, "\(process.executable) is still running")
            XCTAssertFalse(ProcessRegistry.groupIsAlive(process.pid), "process group of \(process.executable) is still alive")
        }
    }

    private func runToEnd(_ exe: String, _ args: [String], cwd: String) throws -> String {
        let collector = OutputCollector()
        let p = try ChildProcess(executable: exe, arguments: args, environment: ProcessInfo.processInfo.environment, currentDirectory: cwd,
                                 onStdout: { collector.add($0) }, onStderr: { collector.add($0) }, onExit: { _ in })
        p.closeStdin()
        XCTAssertTrue(p.waitForExit(timeout: 120))
        return collector.text
    }
}

final class ScriptCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [URL] = []
    func add(_ url: URL) { lock.lock(); scripts.append(url); lock.unlock() }
    var last: URL? { lock.lock(); defer { lock.unlock() }; return scripts.last }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    func wait(for needle: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !text.contains(needle) {
            if Date() > deadline { XCTFail("did not see \"\(needle)\" in:\n\(text)"); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
