import XCTest
@testable import CrossKitCore

final class DebugUnitTests: XCTestCase {
    var home: URL!
    var settings: SettingsStore!
    var suite: String!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: LaunchPlanner.canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("ck-dbg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        suite = "dev.pyrlyn.CrossKit.tests.\(UUID().uuidString)"
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        removeDefaults(suite)
    }

    func makeExec(_ relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    func write(_ relative: String, _ text: String = "") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    var locator: ServerLocator { ServerLocator(home: home, pathEnvironment: "", miseDataDirectory: home.appendingPathComponent("mise")) }
    var debuggers: DebuggerLocator { DebuggerLocator(locator: locator, developerDirectory: home.appendingPathComponent("Developer").path) }
    var planner: LaunchPlanner {
        LaunchPlanner(settings: settings, resolver: TestRunnerResolver(settings: settings, toolchain: TestToolchain(locator: locator)),
                      debuggers: debuggers, workDirectory: home.appendingPathComponent("work"))
    }

    // MARK: Detection

    func testDebuggerDetection() throws {
        XCTAssertNil(debuggers.find(.lldbDAP))
        XCTAssertEqual(debuggers.autoKind(for: .zig), .lldb)
        XCTAssertEqual(debuggers.autoKind(for: .kotlin), .jdb)
        try makeExec("Developer/usr/bin/lldb")
        try makeExec("Developer/usr/bin/lldb-dap")
        try makeExec(".vscode/extensions/vadimcn.vscode-lldb-1.11.0/adapter/codelldb")
        try makeExec(".vscode/extensions/vadimcn.vscode-lldb-1.12.1/adapter/codelldb")
        try makeExec("mise/installs/java/temurin-21/bin/java")
        try makeExec("mise/installs/java/temurin-21/bin/jdb")
        XCTAssertEqual(debuggers.find(.lldb)?.path, home.appendingPathComponent("Developer/usr/bin/lldb").path)
        XCTAssertEqual(debuggers.find(.lldbDAP)?.path, home.appendingPathComponent("Developer/usr/bin/lldb-dap").path)
        XCTAssertTrue(debuggers.find(.codelldb)!.path.contains("vscode-lldb-1.12.1"), "newest CodeLLDB first")
        XCTAssertEqual(debuggers.autoKind(for: .rust), .lldbDAP)
        if ProcessInfo.processInfo.environment["JAVA_HOME"] == nil {
            XCTAssertTrue(debuggers.find(.jdb)!.path.hasSuffix("temurin-21/bin/java"))
            XCTAssertTrue(debuggers.jdb()!.path.hasSuffix("temurin-21/bin/jdb"))
        }
        XCTAssertEqual(debuggers.describe(.zig).map(\.tool), ["lldb-dap", "lldb", "codelldb"])
    }

    func testMissingDebuggerIsGraceful() throws {
        try makeExec("mise/installs/zig/0.17.1/zig")
        let file = try write("p/main.zig", "pub fn main() void {}\n")
        settings.setDebugger(.codelldb, for: .zig)
        XCTAssertThrowsError(try planner.plan(language: .zig, file: file, text: "pub fn main() void {}\n", cursorLine: 0, target: .file)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("codelldb was not found. Install the CodeLLDB extension"), $0.localizedDescription)
        }
        // A custom path wins over detection.
        try makeExec("tools/my-codelldb")
        settings.setDebuggerPath(home.appendingPathComponent("tools/my-codelldb").path, for: .codelldb)
        XCTAssertEqual(try planner.plan(language: .zig, file: file, text: "pub fn main() void {}\n", cursorLine: 0, target: .file).debuggerPath,
                       home.appendingPathComponent("tools/my-codelldb").path)
    }

    // MARK: Plans

    func testZigPlans() throws {
        try makeExec("Developer/usr/bin/lldb-dap")
        try makeExec("mise/installs/zig/0.17.1/zig")
        let zig = home.appendingPathComponent("mise/installs/zig/0.17.1/zig").path
        let text = "const std = @import(\"std\");\npub fn main() void {\n    std.debug.print(\"hi\", .{});\n}\ntest \"two\" {\n    try std.testing.expect(true);\n}\n"
        let file = try write("loose/main.zig", text)
        let plan = try planner.plan(language: .zig, file: file, text: text, cursorLine: 2, target: .file)
        XCTAssertEqual(plan.debugger, .lldbDAP)
        XCTAssertEqual(plan.breakpoints, [Breakpoint(file: file.path, line: 2)])
        XCTAssertEqual(plan.build.first?.prefix(3), [zig, "build-exe", file.path])
        guard case .path(let binary) = plan.programSource else { return XCTFail("\(plan.programSource)") }
        XCTAssertEqual(plan.build.first?.last, "-femit-bin=\(binary)")
        XCTAssertTrue(binary.hasPrefix(home.appendingPathComponent("work/builds/loose-").path))
        XCTAssertEqual(plan.workingDirectory, home.appendingPathComponent("loose").path)

        let testPlan = try planner.plan(language: .zig, file: file, text: text, cursorLine: 5, target: .test)
        XCTAssertEqual(testPlan.title, "two")
        XCTAssertEqual(Array(testPlan.build[0][1...4]), ["test", file.path, "--test-filter", "two"])
        XCTAssertTrue(testPlan.build[0].contains("--test-no-exec"))
        XCTAssertThrowsError(try planner.plan(language: .zig, file: file, text: text, cursorLine: 0, target: .test)) {
            XCTAssertEqual($0 as? DebugError, .noTestAtCursor)
        }

        try write("proj/build.zig", "")
        let projFile = try write("proj/src/main.zig", text)
        let projPlan = try planner.plan(language: .zig, file: projFile, text: text, cursorLine: 2, target: .file)
        XCTAssertEqual(projPlan.build, [[zig, "build", "install"]])
        XCTAssertEqual(projPlan.programSource, .zigInstall(preferredName: "proj"))

        XCTAssertThrowsError(try planner.plan(language: .zig, file: projFile, text: "fn helper() void {}\n", cursorLine: 0, target: .file)) {
            XCTAssertEqual($0 as? DebugError, .noMain("main.zig"))
        }
    }

    func testRustPlans() throws {
        try makeExec("Developer/usr/bin/lldb")
        try makeExec(".cargo/bin/cargo")
        let cargo = home.appendingPathComponent(".cargo/bin/cargo").path
        settings.setDebugger(.lldb, for: .rust)
        try write("crate/Cargo.toml")
        try write("crate/src/lib.rs", "pub mod util;\n")
        let main = try write("crate/src/main.rs", "fn main() {}\n")
        let lib = try write("crate/src/util.rs", "pub fn f() {}\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn works() {}\n}\n")
        let plan = try planner.plan(language: .rust, file: main, text: "fn main() {}\n", cursorLine: 0, target: .file)
        XCTAssertEqual(plan.build, [[cargo, "build", "--message-format=json-render-diagnostics", "--bins"]])
        XCTAssertEqual(plan.programSource, .cargoArtifact(target: nil, test: false))
        // A library file of a crate with a binary: debug the binary, breakpoint in the library file.
        let libPlan = try planner.plan(language: .rust, file: lib, text: "pub fn f() {}\n", cursorLine: 0, target: .file)
        XCTAssertEqual(libPlan.build.first?.last, "--bins")
        XCTAssertEqual(libPlan.breakpoints.first?.file, lib.path)
        let testPlan = try planner.plan(language: .rust, file: lib, text: try String(contentsOf: lib, encoding: .utf8), cursorLine: 4, target: .test)
        XCTAssertEqual(testPlan.build, [[cargo, "test", "--no-run", "--message-format=json-render-diagnostics", "--lib"]])
        XCTAssertEqual(testPlan.programSource, .cargoArtifact(target: nil, test: true))
        XCTAssertEqual(testPlan.arguments, ["util::tests::works", "--exact", "--nocapture", "--test-threads=1"])
    }

    func testKotlinPlans() throws {
        try makeExec("mise/installs/java/temurin-21/bin/java")
        try makeExec("proj/gradlew")
        try write("proj/settings.gradle.kts")
        try write("proj/app/build.gradle.kts")
        let text = """
        @file:JvmName("Launcher")
        package demo

        class Greeter {
            fun greet() = "hi"
        }

        fun main() {
            println(Greeter().greet())
        }
        """
        let file = try write("proj/app/src/main/kotlin/demo/Main.kt", text)
        settings.jdwpPort = 7007
        let plan = try planner.plan(language: .kotlin, file: file, text: text, cursorLine: 8, target: .file)
        XCTAssertEqual(plan.debugger, .jdb)
        XCTAssertEqual(plan.programSource, .jvmMain(mainClass: "demo.Launcher"))
        XCTAssertEqual(plan.jvmBreakpointClass, "demo.Launcher")
        XCTAssertEqual(plan.jdwpPort, 7007)
        let build = try XCTUnwrap(plan.build.first)
        XCTAssertEqual(build[0], home.appendingPathComponent("proj/gradlew").path)
        XCTAssertEqual(build[1], ":app:crossKitClasspath")
        XCTAssertTrue(build.contains("--no-daemon"))
        let initScript = try XCTUnwrap(build.firstIndex(of: "-I").map { build[$0 + 1] })
        XCTAssertEqual(try String(contentsOfFile: initScript, encoding: .utf8), LaunchPlanner.gradleInitScript)
        XCTAssertEqual(try planner.plan(language: .kotlin, file: file, text: text, cursorLine: 4, target: .file).jvmBreakpointClass, "demo.Greeter")

        let testText = "package demo\n\nimport org.junit.jupiter.api.Test\n\nclass CalcTest {\n    @Test\n    fun adds() {\n        check(true)\n    }\n}\n"
        let testFile = try write("proj/app/src/test/kotlin/demo/CalcTest.kt", testText)
        let testPlan = try planner.plan(language: .kotlin, file: testFile, text: testText, cursorLine: 7, target: .test)
        guard case .gradleTest(let command) = testPlan.programSource else { return XCTFail("\(testPlan.programSource)") }
        XCTAssertEqual(Array(command[1...4]), [":app:test", "--tests", "demo.CalcTest.adds", "--rerun"])
        XCTAssertEqual(testPlan.jvmBreakpointClass, "demo.CalcTest")
        XCTAssertTrue(testPlan.build.isEmpty)

        try write("loose/Script.kt", "fun main() {}\n")
        XCTAssertThrowsError(try planner.plan(language: .kotlin, file: home.appendingPathComponent("loose/Script.kt"), text: "fun main() {}\n",
                                              cursorLine: 0, target: .file)) {
            XCTAssertTrue($0.localizedDescription.contains("needs a Gradle project"))
        }
    }

    // MARK: Launch configurations

    func testLaunchConfigurationIsCreatedSavedAndUsed() throws {
        try makeExec("Developer/usr/bin/lldb")
        try makeExec("mise/installs/zig/0.17.1/zig")
        let file = try write("app/main.zig", "pub fn main() void {}\n")
        let root = home.appendingPathComponent("app").path
        XCTAssertNil(settings.launchConfiguration(for: .zig, projectRoot: root))
        _ = try planner.plan(language: .zig, file: file, text: "pub fn main() void {}\n", cursorLine: 0, target: .file)
        var config = try XCTUnwrap(settings.launchConfiguration(for: .zig, projectRoot: root), "default configuration is auto-saved")
        XCTAssertEqual(config.effectiveWorkingDirectory, root)
        XCTAssertTrue(config.arguments.isEmpty)

        config.arguments = ["--port", "8080"]
        config.environment = ["RUST_LOG": "debug"]
        config.workingDirectory = "/tmp"
        settings.saveLaunchConfiguration(config)
        let plan = try planner.plan(language: .zig, file: file, text: "pub fn main() void {}\n", cursorLine: 0, target: .file)
        XCTAssertEqual(plan.arguments, ["--port", "8080"])
        XCTAssertEqual(plan.environment, ["RUST_LOG": "debug"])
        XCTAssertEqual(plan.workingDirectory, "/tmp")

        // A program override skips the build.
        config.program = "/bin/echo"
        settings.saveLaunchConfiguration(config)
        let custom = try planner.plan(language: .zig, file: file, text: "fn helper() void {}\n", cursorLine: 0, target: .file)
        XCTAssertTrue(custom.build.isEmpty)
        XCTAssertEqual(custom.programSource, .path("/bin/echo"))

        XCTAssertEqual(settings.launchConfigurations().count, 1)
        settings.deleteLaunchConfiguration(id: config.id)
        XCTAssertTrue(settings.launchConfigurations().isEmpty)
    }

    func testDebuggerSettingsPersistence() {
        XCTAssertNil(settings.debugger(for: .rust))
        settings.setDebugger(.codelldb, for: .rust)
        XCTAssertEqual(settings.debugger(for: .rust), .codelldb)
        settings.setDebugger(.jdb, for: .rust)
        XCTAssertNil(settings.debugger(for: .rust), "a JVM debugger is not valid for Rust")
        XCTAssertEqual(settings.jdwpPort, 5005)
        XCTAssertTrue(settings.isFeatureEnabled(.debug, for: .zig))
    }

    // MARK: Generated commands and parsing

    func testLLDBCommands() {
        let plan = LaunchPlan(language: .rust, target: .file, debugger: .lldb, debuggerPath: "/usr/bin/lldb", projectRoot: "/p",
                              build: [], programSource: .path("/p/target/debug/app"), arguments: ["--name", "a \"b\""],
                              environment: ["B": "2", "A": "1"], workingDirectory: "/p/run dir",
                              breakpoints: [Breakpoint(file: "/p/src/main.rs", line: 9)], title: "main.rs", jdwpPort: 0)
        XCTAssertEqual(DebugService.lldbCommands(plan: plan, program: "/p/target/debug/app"), """
        target create "/p/target/debug/app"
        settings set target.env-vars "A=1" "B=2"
        breakpoint set --file "/p/src/main.rs" --line 10
        process launch -w "/p/run dir" -- "--name" "a \\"b\\""

        """)
        XCTAssertEqual(DebugService.shellQuote("/usr/bin/lldb"), "/usr/bin/lldb")
        XCTAssertEqual(DebugService.shellQuote("it's here"), "'it'\\''s here'")
    }

    func testCargoArtifactParsing() {
        let output = """
        {"reason":"compiler-artifact","target":{"name":"sample","kind":["lib"],"src_path":"/c/src/lib.rs"},"profile":{"test":false},"executable":null}
        {"reason":"compiler-artifact","target":{"name":"sample","kind":["bin"],"src_path":"/c/src/main.rs"},"profile":{"test":false},"executable":"/c/target/debug/sample"}
        {"reason":"compiler-artifact","target":{"name":"tool","kind":["bin"],"src_path":"/c/src/bin/tool.rs"},"profile":{"test":false},"executable":"/c/target/debug/tool"}
        {"reason":"compiler-artifact","target":{"name":"sample","kind":["lib"],"src_path":"/c/src/lib.rs"},"profile":{"test":true},"executable":"/c/target/debug/deps/sample-1234"}
           Compiling sample v0.1.0 (/c)
        {"reason":"build-finished","success":true}
        """
        XCTAssertEqual(LaunchPlanner.cargoExecutable(fromJSONLines: output, target: nil, test: true, sourceFile: nil), "/c/target/debug/deps/sample-1234")
        XCTAssertEqual(LaunchPlanner.cargoExecutable(fromJSONLines: output, target: "sample", test: false, sourceFile: nil), "/c/target/debug/sample")
        XCTAssertEqual(LaunchPlanner.cargoExecutable(fromJSONLines: output, target: nil, test: false, sourceFile: "/c/src/bin/tool.rs"), "/c/target/debug/tool")
        XCTAssertNil(LaunchPlanner.cargoExecutable(fromJSONLines: "error[E0425]: cannot find value", target: nil, test: false, sourceFile: nil))
    }

    func testKotlinClassAtLine() {
        let text = """
        package a.b

        fun top() = 1

        class Outer {
            fun f() {
                val x = 1
            }

            inner class Inner {
                fun g() = 2
            }
        }

        object Single {
            fun h() = 3
        }
        """
        XCTAssertEqual(TestDiscovery.kotlinClass(atLine: 2, text: text, fileName: "util.kt"), "a.b.UtilKt")
        XCTAssertEqual(TestDiscovery.kotlinClass(atLine: 6, text: text, fileName: "util.kt"), "a.b.Outer")
        XCTAssertEqual(TestDiscovery.kotlinClass(atLine: 10, text: text, fileName: "util.kt"), "a.b.Outer$Inner")
        XCTAssertEqual(TestDiscovery.kotlinClass(atLine: 15, text: text, fileName: "util.kt"), "a.b.Single")
        XCTAssertTrue(TestDiscovery.hasMain(.kotlin, text: "fun main(args: Array<String>) {}"))
        XCTAssertFalse(TestDiscovery.hasMain(.kotlin, text: "// fun main() {}"))
        XCTAssertTrue(TestDiscovery.hasMain(.zig, text: "pub fn main() !void {}"))
        XCTAssertTrue(TestDiscovery.hasMain(.rust, text: "async fn main() {}"))
    }

    func testDebugCommandsDoNotEditTheBuffer() async throws {
        var response = BridgeResponse()
        response.debugLaunch = DebugLaunchInfo(sessionID: "1", language: .zig, debugger: .lldbDAP, program: "/p/main", title: "main.zig",
                                               breakpoint: Breakpoint(file: "/p/main.zig", line: 3), message: "Debugging main.zig",
                                               warning: "unsaved")
        let transport = RecordingTransport(response: response)
        let buffer = EditorBuffer(lines: ["a\n", "b\n"], selection: .caret(1, 0), contentUTI: "", filePath: "/p/main.zig")
        let outcome = try await EditorCommandEngine().run(.debugFileAtCursor, buffer: buffer, transport: transport)
        XCTAssertTrue(outcome.operations.isEmpty)
        XCTAssertEqual(outcome.message, "▶ Debugging main.zig\n\n⚠︎ unsaved")
        XCTAssertEqual(transport.lastRequest?.operation, .debugFile)
        XCTAssertEqual(transport.lastRequest?.line, 1)
        _ = try await EditorCommandEngine().run(.debugTestAtCursor, buffer: buffer, transport: transport)
        XCTAssertEqual(transport.lastRequest?.operation, .debugTest)
        XCTAssertTrue(EditorCommandEngine.isLongRunning(.debugTestAtCursor))
    }
}

final class RecordingTransport: BridgeTransport, @unchecked Sendable {
    let response: BridgeResponse
    private let lock = NSLock()
    private var requests: [BridgeRequest] = []
    init(response: BridgeResponse) { self.response = response }
    func send(_ request: BridgeRequest) async throws -> BridgeResponse {
        lock.withLock { requests.append(request) }
        return response
    }
    var lastRequest: BridgeRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
}

final class LaunchConfigurationTextTests: XCTestCase {
    func testArgumentsRoundTrip() {
        XCTAssertEqual(LaunchConfiguration.splitArguments(#"--port 8080 "two words" 'single quoted' a\ b"#),
                       ["--port", "8080", "two words", "single quoted", "a b"])
        XCTAssertEqual(LaunchConfiguration.splitArguments("  "), [])
        XCTAssertEqual(LaunchConfiguration.splitArguments(#"empty "" end"#), ["empty", "", "end"])
        let args = ["plain", "with space", #"quote"inside"#, #"back\slash"#, ""]
        XCTAssertEqual(LaunchConfiguration.splitArguments(LaunchConfiguration.joinArguments(args)), args)
    }

    func testEnvironmentParsing() {
        let env = LaunchConfiguration.parseEnvironment("RUST_LOG=debug\n# comment\nEMPTY=\nURL=http://x?a=b\n=bad\nnoequals\n")
        XCTAssertEqual(env, ["RUST_LOG": "debug", "EMPTY": "", "URL": "http://x?a=b"])
        XCTAssertEqual(LaunchConfiguration.formatEnvironment(["B": "2", "A": "1"]), "A=1\nB=2")
    }
}

final class DebugBufferMappingTests: XCTestCase {
    func testUnsavedAnnotationsAreIgnoredForBreakpoints() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ck-map-\(UUID().uuidString).zig")
        defer { try? FileManager.default.removeItem(at: file) }
        try "fn a() void {}\n\ntest \"x\" {\n    a();\n}\n".write(to: file, atomically: true, encoding: .utf8)
        let buffer = "fn a() void {}\n\n// [CrossKit] ✓ passed 0.001s\ntest \"x\" {\n    a();\n}\n"
        let (text, line) = DebugService.matchSavedFile(file: file, text: buffer, line: 4)
        XCTAssertEqual(line, 3)
        XCTAssertFalse(text.contains("[CrossKit]"))
        // Real edits are left alone (the debugger then warns about unsaved changes).
        let edited = buffer.replacingOccurrences(of: "a();", with: "a(); a();")
        XCTAssertEqual(DebugService.matchSavedFile(file: file, text: edited, line: 4).1, 4)
    }
}
