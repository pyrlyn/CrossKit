import XCTest
@testable import CrossKitCore

/// Runs real test toolchains through the extension path:
/// EditorCommandEngine → BridgeClient → BridgeServer → BridgeHandler → TestService → zig / cargo / gradle.
/// Each project has one passing and one failing test. Tests skip when the toolchain is missing.
final class TestRunEndToEndTests: XCTestCase {
    struct Project {
        var files: [String: String]
        var testFile: String
        var passing: String          // result name fragment of the passing test
        var failing: String          // result name fragment of the failing test
        var failureText: String      // must appear in the failing test's output
        var cursorLine: Int          // a line inside the passing test
        var arguments: [String] = []
    }

    func testZigRunsTests() async throws {
        guard TestToolchain().zig() != nil else { throw XCTSkip("zig not found; install with `mise use -g zig@latest`") }
        let source = """
        const std = @import("std");

        fn add(a: i32, b: i32) i32 {
            return a + b;
        }

        test "add works" {
            try std.testing.expectEqual(@as(i32, 3), add(1, 2));
        }

        test "add fails on purpose" {
            try std.testing.expectEqual(@as(i32, 4), add(1, 2));
        }
        """
        // Single-file project: no build.zig, so the runner uses `zig test <file>`.
        try await run(.zig, Project(files: ["main.zig": source], testFile: "main.zig",
                                    passing: "add works", failing: "add fails on purpose",
                                    failureText: "expected 4, found 3", cursorLine: 7))
    }

    func testRustRunsTests() async throws {
        guard TestToolchain().cargo() != nil else { throw XCTSkip("cargo not found; install Rust with rustup") }
        let source = """
        pub fn add(a: i32, b: i32) -> i32 {
            a + b
        }

        #[cfg(test)]
        mod tests {
            use super::*;

            #[test]
            fn adds() {
                assert_eq!(add(1, 2), 3);
            }

            #[test]
            fn fails_on_purpose() {
                assert_eq!(add(1, 2), 4, "math is hard");
            }
        }
        """
        try await run(.rust, Project(
            files: ["Cargo.toml": "[package]\nname = \"sample\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n",
                    "src/lib.rs": source],
            testFile: "src/lib.rs", passing: "tests::adds", failing: "tests::fails_on_purpose",
            failureText: "math is hard", cursorLine: 10))
    }

    func testKotlinRunsJUnit5Tests() async throws {
        guard TestToolchain().gradle() != nil else { throw XCTSkip("gradle not found; install with `mise use -g gradle@latest`") }
        guard ServerLocator().javaHome() != nil else { throw XCTSkip("no JDK found") }
        let test = """
        package demo

        import org.junit.jupiter.api.Assertions.assertEquals
        import org.junit.jupiter.api.Test

        class CalcTest {
            @Test
            fun adds() {
                assertEquals(3, add(1, 2))
            }

            @Test
            fun `fails on purpose`() {
                assertEquals(4, add(1, 2), "math is hard")
            }
        }
        """
        // Uses --offline when the dependencies are already in ~/.gradle (CI without network); otherwise Gradle downloads them.
        let offline = FileManager.default.fileExists(atPath: ServerLocator().home.appendingPathComponent(".gradle/caches/modules-2/files-2.1/org.junit/junit-bom/5.13.4").path)
        try await run(.kotlin, Project(
            files: ["settings.gradle.kts": "rootProject.name = \"sample\"\n",
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
                    "src/test/kotlin/demo/CalcTest.kt": test],
            testFile: "src/test/kotlin/demo/CalcTest.kt", passing: "demo.CalcTest.adds", failing: "demo.CalcTest.fails on purpose",
            failureText: "math is hard", cursorLine: 8, arguments: offline ? ["--offline"] : []))
    }

    // MARK: Driver

    private func run(_ language: Language, _ project: Project) async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/ck-tests-\(language.rawValue)-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for (path, contents) in project.files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let file = root.appendingPathComponent(project.testFile)
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").map { $0 + "\n" }

        let suite = "dev.pyrlyn.CrossKit.e2e-tests.\(UUID().uuidString)"
        defer { removeDefaults(suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.setTestArguments(project.arguments, for: language)
        settings.testTimeout = 600
        let manager = ServerManager(settings: settings)
        let handler = BridgeHandler(manager: manager, settings: settings, scratchDirectory: root.appendingPathComponent(".scratch"))
        let runs = RunCollector()
        handler.onTestRun = { runs.add($0) }
        let server = BridgeServer(portName: "dev.pyrlyn.CrossKit.e2e-tests.\(UUID().uuidString.prefix(6))") { await handler.handle($0) }
        try server.start()
        defer { server.stop() }
        let transport = BridgeClient(portName: server.portName, timeout: 660)
        let engine = EditorCommandEngine()
        func buffer(_ lines: [String], line: Int) -> EditorBuffer {
            EditorBuffer(lines: lines, selection: .caret(line, 4), contentUTI: "public.\(language.rawValue)-source", filePath: file.path)
        }

        // 1. Run every test in the file.
        let all = try await engine.run(.runTestsInFile, buffer: buffer(lines, line: 0), transport: transport)
        let message = all.message ?? ""
        print("[e2e-tests] \(language.displayName) file run:\n\(message)")
        XCTAssertTrue(message.contains("1 passed, 1 failed"), message)
        let run = try XCTUnwrap(runs.last)
        let pass = try XCTUnwrap(run.tests.first { $0.name.contains(project.passing) }, "\(run.tests.map(\.name))")
        let fail = try XCTUnwrap(run.tests.first { $0.name.contains(project.failing) }, "\(run.tests.map(\.name))")
        XCTAssertEqual(pass.status, .passed)
        XCTAssertEqual(fail.status, .failed)
        XCTAssertTrue(fail.output?.contains(project.failureText) == true, fail.output ?? "no output")
        XCTAssertEqual(fail.file, file.path)
        XCTAssertNotNil(fail.line, "failing test should link to its line")
        let annotated = EditorCommandEngine.apply(all.operations, to: lines).lines
        XCTAssertEqual(annotated.filter(EditorCommandEngine.isTestMarker).count, 2, "one marker per test")
        XCTAssertTrue(annotated.contains { $0.contains("✗ failed") })

        // 2. Run only the test under the cursor (markers from step 1 must not confuse discovery).
        let cursorLine = project.cursorLine + annotated.prefix(project.cursorLine + 1).filter(EditorCommandEngine.isTestMarker).count
        let one = try await engine.run(.runTestAtCursor, buffer: buffer(annotated, line: cursorLine), transport: transport)
        print("[e2e-tests] \(language.displayName) cursor run:\n\(one.message ?? "")")
        let single = try XCTUnwrap(runs.last)
        XCTAssertEqual(single.scope, .cursor)
        XCTAssertEqual(single.tests.count, 1, "\(single.tests.map(\.name))")
        XCTAssertEqual(single.tests.first?.status, .passed)
        XCTAssertTrue(one.message?.contains("1 passed") == true, one.message ?? "")
        await manager.shutdownAll()
        XCTAssertTrue(ProcessRegistry.activeGroups().isEmpty, "test runner processes must not outlive the run")
    }
}

private final class RunCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [TestRunResult] = []
    func add(_ run: TestRunResult) { lock.lock(); runs.append(run); lock.unlock() }
    var last: TestRunResult? { lock.lock(); defer { lock.unlock() }; return runs.last }
}
