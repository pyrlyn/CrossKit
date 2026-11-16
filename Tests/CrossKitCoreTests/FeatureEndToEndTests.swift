import XCTest
@testable import CrossKitCore

/// End-to-end tests for Build & Run, Kotlin targets, Compose previews and inline annotations, through the
/// extension path: EditorCommandEngine → BridgeClient → BridgeServer → BridgeHandler → services → real toolchains.
/// Fixtures live in the repository's build/e2e directory and are removed afterwards. Every test skips when its
/// toolchain is missing, turns the Gradle daemon off and checks that no process is left behind.
final class FeatureEndToEndTests: XCTestCase {
    struct Harness {
        var root: URL
        var settings: SettingsStore
        var manager: ServerManager
        var handler: BridgeHandler
        var transport: BridgeClient
        var server: BridgeServer
        var suite: String
        var previews: PreviewCollector

        func file(_ path: String) -> URL { root.appendingPathComponent(path) }

        func buffer(_ path: String, line: Int, column: Int = 4) throws -> EditorBuffer {
            let url = file(path)
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").map { $0 + "\n" }
            return EditorBuffer(lines: lines, selection: .caret(line, column), contentUTI: "", filePath: url.path)
        }

        func run(_ command: EditorCommand, _ path: String, line: Int = 0) async throws -> EditorOutcome {
            let outcome = try await EditorCommandEngine().run(command, buffer: buffer(path, line: line), transport: transport)
            print("[e2e-features] \(command.displayName) \(path):\n\(outcome.message ?? "")")
            return outcome
        }

        func tearDown() async {
            handler.runService.stopAll()
            await handler.debugService.stopAll()
            await manager.shutdownAll()
            server.stop()
            try? FileManager.default.removeItem(at: root)
            removeDefaults(suite)
        }
    }

    static let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func makeHarness(_ name: String, files: [String: String]) throws -> Harness {
        let fm = FileManager.default
        let root = Self.repositoryRoot.appendingPathComponent("build/e2e/\(name)-\(UUID().uuidString.prefix(6))")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let suite = "dev.pyrlyn.CrossKit.e2e-features.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.testTimeout = 900
        settings.gradleDaemon = false
        let manager = ServerManager(settings: settings)
        let handler = BridgeHandler(manager: manager, settings: settings, scratchDirectory: root.appendingPathComponent(".scratch"))
        handler.debugService.planner.workDirectory = root.appendingPathComponent(".crosskit-debug")
        handler.debugService.terminalLauncher = { _ in }
        handler.previewService.directory = root.appendingPathComponent(".crosskit-preview")
        let previews = PreviewCollector()
        handler.onPreview = { previews.add($0) }
        let server = BridgeServer(portName: "dev.pyrlyn.CrossKit.e2e-features.\(UUID().uuidString.prefix(6))") { await handler.handle($0) }
        try server.start()
        let transport = BridgeClient(portName: server.portName, timeout: 960)
        return Harness(root: root, settings: settings, manager: manager, handler: handler, transport: transport, server: server,
                       suite: suite, previews: previews)
    }

    static func gradleCacheExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: ServerLocator().home.appendingPathComponent(".gradle/caches/modules-2/files-2.1/\(path)").path)
    }

    // MARK: Zig and Rust: Build Project and Run File

    func testZigAndRustBuildAndRun() async throws {
        let zig = TestToolchain().zig() != nil
        let cargo = TestToolchain().cargo() != nil
        guard zig || cargo else { throw XCTSkip("neither zig nor cargo found") }
        let h = try makeHarness("run", files: [
            "zig/main.zig": "const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.print(\"zig says {d}\\n\", .{6 * 7});\n}\n",
            "rust/Cargo.toml": "[package]\nname = \"sample\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n",
            "rust/src/main.rs": "fn main() {\n    println!(\"rust says {}\", 6 * 7);\n    std::process::exit(3);\n}\n",
        ])
        addTeardownBlock { await h.tearDown() }
        if zig {
            let built = try await h.run(.buildProject, "zig/main.zig")
            XCTAssertTrue(built.message?.hasPrefix("✓ Build succeeded") == true, built.message ?? "")
            let ran = try await h.run(.runFile, "zig/main.zig")
            XCTAssertTrue(ran.message?.hasPrefix("✓ Run succeeded") == true, ran.message ?? "")
            XCTAssertTrue(ran.message?.contains("zig says 42") == true, ran.message ?? "")
        }
        if cargo {
            let built = try await h.run(.buildProject, "rust/src/main.rs")
            XCTAssertTrue(built.message?.hasPrefix("✓ Build succeeded") == true, built.message ?? "")
            let ran = try await h.run(.runFile, "rust/src/main.rs")
            XCTAssertTrue(ran.message?.contains("exited with code 3") == true, ran.message ?? "")
            XCTAssertTrue(ran.message?.contains("rust says 42") == true, ran.message ?? "")
            let run = try XCTUnwrap(h.handler.runService.allRuns.first { $0.mode == .run && $0.language == .rust })
            XCTAssertEqual(run.state, .failed)
            XCTAssertEqual(run.exitCode, 3)
        }
        XCTAssertTrue(h.handler.runService.allRuns.allSatisfy { !$0.state.isActive })
        XCTAssertTrue(ProcessRegistry.activeGroups().isEmpty, "build and run processes must not outlive the command")
    }

    // MARK: Kotlin Multiplatform: JVM and Native targets

    static let multiplatformFiles: [String: String] = [
        "settings.gradle.kts": """
        pluginManagement { repositories { gradlePluginPortal(); mavenCentral(); google() } }
        dependencyResolutionManagement { repositories { mavenCentral(); google() } }
        rootProject.name = "kmpdemo"

        """,
        "build.gradle.kts": """
        plugins { kotlin("multiplatform") version "2.4.21" }
        kotlin {
            jvm()
            macosArm64 { binaries { executable { entryPoint = "demo.main" } } }
            sourceSets { commonTest.dependencies { implementation(kotlin("test")) } }
        }

        """,
        "src/commonMain/kotlin/demo/Main.kt": """
        package demo

        fun compute(x: Int): Int {
            val doubled = x * 2
            return doubled + 1
        }

        fun main() {
            val answer = compute(20)
            println("answer=$answer on ${platformName()}")
        }

        expect fun platformName(): String

        """,
        "src/jvmMain/kotlin/demo/Platform.kt": "package demo\n\nactual fun platformName(): String = \"jvm\"\n",
        "src/macosArm64Main/kotlin/demo/Platform.kt": "package demo\n\nactual fun platformName(): String = \"native\"\n",
        "src/commonTest/kotlin/demo/CalcTest.kt": """
        package demo

        import kotlin.test.Test
        import kotlin.test.assertEquals

        class CalcTest {
            @Test
            fun adds() {
                val value = compute(20)
                assertEquals(41, value)
            }
        }

        """,
    ]

    func testKotlinMultiplatformNativeAndJVMTargets() async throws {
        guard KotlinProject.hostNativePreset == "macosArm64" else { throw XCTSkip("the fixture targets macosArm64") }
        guard TestToolchain().gradle() != nil else { throw XCTSkip("gradle not found") }
        guard ServerLocator().javaHome() != nil else { throw XCTSkip("no JDK found") }
        let konan = ServerLocator().home.appendingPathComponent(".konan")
        let prebuilt = ((try? FileManager.default.contentsOfDirectory(atPath: konan.path)) ?? []).contains { $0.hasPrefix("kotlin-native-prebuilt-") }
        let offline = Self.gradleCacheExists("org.jetbrains.kotlin/kotlin-stdlib/2.4.21") && prebuilt
        if !offline && ProcessInfo.processInfo.environment["CROSSKIT_E2E_NETWORK"] == nil {
            throw XCTSkip("Kotlin 2.4.21 / Kotlin/Native caches not found; set CROSSKIT_E2E_NETWORK=1 to let Gradle download them")
        }
        let h = try makeHarness("kmp", files: Self.multiplatformFiles)
        addTeardownBlock { await h.tearDown() }
        if offline { h.settings.setTestArguments(["--offline"], for: .kotlin) }
        let main = "src/commonMain/kotlin/demo/Main.kt"
        let test = "src/commonTest/kotlin/demo/CalcTest.kt"

        // Native target.
        h.settings.kotlinTarget = .native
        let built = try await h.run(.buildProject, main)
        XCTAssertTrue(built.message?.hasPrefix("✓ Build succeeded") == true, built.message ?? "")
        XCTAssertTrue(built.message?.contains("Native macosArm64") == true, built.message ?? "")
        XCTAssertNotNil(KotlinProject.nativeExecutable(in: h.file("build/bin/macosArm64/debugExecutable")))
        let ran = try await h.run(.runFile, main)
        XCTAssertTrue(ran.message?.contains("answer=41 on native") == true, ran.message ?? "")

        let tests = try await h.run(.runTestAtCursor, test, line: 8)
        XCTAssertTrue(tests.message?.contains("1 passed") == true, tests.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.file("build/test-results/macosArm64Test").path), "native test task ran")

        if DebuggerLocator().find(.lldbDAP) != nil {
            h.settings.kotlinNativeDebugger = .lldbDAP
            try await debugSession(h, .debugFileAtCursor, main, line: 4, expectLine: 5, expectVariables: ["x": "20", "doubled": "40"],
                                   expectOutput: "answer=41 on native")
            try await debugSession(h, .debugTestAtCursor, test, line: 9, expectLine: 10, expectVariables: ["value": "41"], expectOutput: nil)
        } else {
            print("[e2e-features] lldb-dap not found; skipping Kotlin/Native debugging")
        }

        // JVM target, chosen per launch configuration.
        var config = try XCTUnwrap(h.settings.launchConfiguration(for: .kotlin, projectRoot: h.root.path))
        config.kotlinTarget = "jvm"
        h.settings.saveLaunchConfiguration(config)
        let jvmRun = try await h.run(.runFile, main)
        XCTAssertTrue(jvmRun.message?.contains("answer=41 on jvm") == true, jvmRun.message ?? "")
        XCTAssertTrue(jvmRun.message?.contains("· JVM") == true, jvmRun.message ?? "")
        let jvmTests = try await h.run(.runTestAtCursor, test, line: 8)
        XCTAssertTrue(jvmTests.message?.contains("1 passed") == true, jvmTests.message ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.file("build/test-results/jvmTest").path), "JVM test task ran")

        XCTAssertTrue(ProcessRegistry.activeGroups().isEmpty, "Gradle and program processes must not outlive the commands")
    }

    private func debugSession(_ h: Harness, _ command: EditorCommand, _ path: String, line: Int, expectLine: Int,
                              expectVariables: [String: String], expectOutput: String?) async throws {
        let outcome = try await EditorCommandEngine().run(command, buffer: h.buffer(path, line: line), transport: h.transport)
        print("[e2e-features] \(command.displayName): \(outcome.message ?? "")")
        let session = try XCTUnwrap(h.handler.debugService.allSessions.max { $0.snapshot.startedAt < $1.snapshot.startedAt })
        XCTAssertEqual(session.snapshot.debugger, .lldbDAP)
        let stopped = try await waitFor(session, timeout: 120) { $0.state == .stopped && !$0.frames.isEmpty && !$0.variables.isEmpty }
        let top = try XCTUnwrap(stopped.frames.first)
        XCTAssertEqual(top.file.map { URL(fileURLWithPath: $0).lastPathComponent }, URL(fileURLWithPath: path).lastPathComponent)
        XCTAssertEqual(top.line, expectLine, "stopped at \(top)")
        let values = Dictionary(stopped.variables.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        for (name, value) in expectVariables {
            XCTAssertEqual(values[name], value, "variable \(name) in \(stopped.variables)")
        }
        var ended = session.snapshot
        for _ in 0..<10 {
            try await session.resume()
            ended = try await waitFor(session, timeout: 60) { $0.state == .exited || ($0.state == .stopped && !$0.frames.isEmpty) }
            if ended.state == .exited { break }
        }
        XCTAssertEqual(ended.state, .exited)
        XCTAssertEqual(ended.exitCode, 0, ended.output)
        if let expectOutput { XCTAssertTrue(ended.output.contains(expectOutput), ended.output) }
        await session.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        if let process = session.dap?.process {
            XCTAssertFalse(ProcessRegistry.groupIsAlive(process.pid), "lldb-dap is still alive")
        }
    }

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
        XCTFail("timed out; state \(snap.state) frames \(snap.frames.prefix(3))\n\(snap.output)")
        return snap
    }

    // MARK: Compose Multiplatform preview

    func testComposeMultiplatformPreview() async throws {
        guard TestToolchain().gradle() != nil else { throw XCTSkip("gradle not found") }
        guard ServerLocator().javaHome() != nil else { throw XCTSkip("no JDK found") }
        let offline = Self.gradleCacheExists("org.jetbrains.compose.desktop/desktop-jvm/1.12.2")
            && Self.gradleCacheExists("org.jetbrains.kotlin/kotlin-stdlib/2.4.21")
        if !offline && ProcessInfo.processInfo.environment["CROSSKIT_E2E_NETWORK"] == nil {
            throw XCTSkip("Compose 1.12.2 caches not found; set CROSSKIT_E2E_NETWORK=1 to let Gradle download them")
        }
        let h = try makeHarness("compose", files: [
            "settings.gradle.kts": Self.multiplatformFiles["settings.gradle.kts"]!.replacingOccurrences(of: "kmpdemo", with: "kmpcompose"),
            "build.gradle.kts": """
            plugins {
                kotlin("multiplatform") version "2.4.21"
                id("org.jetbrains.kotlin.plugin.compose") version "2.4.21"
                id("org.jetbrains.compose") version "1.12.2"
            }
            kotlin {
                jvm("desktop")
                sourceSets {
                    commonMain.dependencies {
                        implementation("org.jetbrains.compose.runtime:runtime:1.12.2")
                        implementation("org.jetbrains.compose.foundation:foundation:1.12.2")
                        implementation("org.jetbrains.compose.ui:ui-tooling-preview:1.12.2")
                    }
                    val desktopMain by getting { dependencies { implementation(compose.desktop.currentOs) } }
                }
            }

            """,
            "src/commonMain/kotlin/demo/Greeting.kt": """
            package demo

            import androidx.compose.foundation.background
            import androidx.compose.foundation.layout.Box
            import androidx.compose.foundation.layout.padding
            import androidx.compose.foundation.layout.size
            import androidx.compose.foundation.text.BasicText
            import androidx.compose.runtime.Composable
            import androidx.compose.ui.Modifier
            import androidx.compose.ui.graphics.Color
            import androidx.compose.ui.tooling.preview.Preview
            import androidx.compose.ui.unit.dp

            @Composable
            fun Greeting(name: String) {
                BasicText("Hello, $name!", modifier = Modifier.padding(8.dp))
            }

            @Preview
            @Composable
            private fun GreetingPreview() {
                Greeting("CrossKit")
            }

            @Preview(widthDp = 120, heightDp = 60, showBackground = true)
            @Composable
            fun RedBoxPreview() {
                Box(Modifier.size(40.dp).background(Color.Red))
            }

            object Previews {
                @Preview
                @Composable
                fun Blue() {
                    Box(Modifier.size(30.dp).background(Color.Blue))
                }
            }

            """,
        ])
        addTeardownBlock { await h.tearDown() }
        if offline { h.settings.setTestArguments(["--offline"], for: .kotlin) }
        h.settings.previewDensity = 2
        let path = "src/commonMain/kotlin/demo/Greeting.kt"
        let outcome = try await h.run(.showPreview, path, line: 27)
        XCTAssertTrue(outcome.operations.isEmpty, "previews never edit the buffer")
        XCTAssertTrue(outcome.message?.contains("Rendered 3 of 3 previews") == true, outcome.message ?? "")
        let result = try XCTUnwrap(h.previews.last)
        XCTAssertEqual(result.previews.count, 3, result.log)
        for preview in result.previews {
            XCTAssertNil(preview.error, "\(preview.preview.name): \(preview.error ?? "")\n\(result.log)")
            let image = try XCTUnwrap(preview.imagePath)
            let data = try Data(contentsOf: URL(fileURLWithPath: image))
            XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "\(image) is a PNG")
        }
        let red = try XCTUnwrap(result.previews.first { $0.preview.function == "RedBoxPreview" })
        XCTAssertEqual(red.pixelWidth, 240)
        XCTAssertEqual(red.pixelHeight, 120)
        XCTAssertEqual(result.focusedID, red.preview.id, "the preview at the cursor is focused")
        XCTAssertTrue(result.previews.contains { $0.preview.className == "demo.Previews" })
        XCTAssertTrue(result.target.contains("desktop"), result.target)

        // Refresh renders again into a new directory and removes the old one.
        let second = try await h.run(.showPreview, path, line: 20)
        XCTAssertTrue(second.message?.contains("Rendered 3 of 3") == true, second.message ?? "")
        let refreshed = try XCTUnwrap(h.previews.last)
        XCTAssertEqual(refreshed.focusedID, refreshed.previews.first { $0.preview.function == "GreetingPreview" }?.preview.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(red.imagePath)), "older renders are removed")
        XCTAssertTrue(ProcessRegistry.activeGroups().isEmpty, "Gradle and the renderer must not outlive the command")
    }

    // MARK: Inline annotations with rust-analyzer

    func testRustInlineAnnotations() async throws {
        guard ServerLocator().detect(.rust) != nil else { throw XCTSkip("rust-analyzer not found") }
        guard TestToolchain().cargo() != nil else { throw XCTSkip("cargo not found") }
        let source = """
        fn add(a: i32, b: i32) -> i32 {
            a + b
        }

        fn main() {
            let total = add(1, 2);
            let label: i32 = "no";
            println!("{total} {label}");
        }

        #[cfg(test)]
        mod tests {
            #[test]
            fn adds() {
                assert_eq!(super::add(1, 2), 3);
            }
        }

        """
        let h = try makeHarness("inline", files: [
            "Cargo.toml": "[package]\nname = \"sample\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\n",
            "src/main.rs": source,
        ])
        addTeardownBlock { await h.tearDown() }
        var options = InlineAnnotationOptions()
        options.hintPlacement = .endOfLine
        h.settings.inlineOptions = options
        let original = try h.buffer("src/main.rs", line: 5).lines
        let engine = EditorCommandEngine()

        // rust-analyzer needs a moment to index and run cargo check; retry until everything showed up.
        var annotated = original
        for attempt in 0..<20 {
            let outcome = try await engine.run(.refreshInlineAnnotations, buffer: EditorBuffer(lines: annotated, selection: .caret(0, 0),
                                                                                               contentUTI: "", filePath: h.file("src/main.rs").path),
                                               transport: h.transport)
            annotated = EditorCommandEngine.apply(outcome.operations, to: annotated).lines
            let text = annotated.joined()
            if text.contains("reference") && text.contains("» total: i32") && text.contains("✖ error") { break }
            print("[e2e-features] inline attempt \(attempt):\n\(text)\n\(outcome.message ?? "")")
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        print("[e2e-features] inline annotations:\n\(annotated.joined())")
        func line(after code: String) -> String? {
            annotated.firstIndex { $0.hasPrefix(code) }.map { annotated[$0] }
        }
        func lens(above code: String) -> String? {
            guard let i = annotated.firstIndex(where: { $0.contains(code) && !$0.contains("[CrossKit]") }), i > 0 else { return nil }
            return annotated[i - 1].contains("// [CrossKit] ◆") ? annotated[i - 1] : nil
        }
        XCTAssertTrue(lens(above: "fn add(")?.contains(" reference") == true, lens(above: "fn add(") ?? "no lens above add")
        XCTAssertTrue(lens(above: "fn main(")?.contains("▶ Run · ⚙ Debug") == true, lens(above: "fn main(") ?? "no lens above main")
        XCTAssertTrue(lens(above: "#[test]")?.contains("▶ Run Test · ⚙ Debug Test") == true, lens(above: "#[test]") ?? "no lens above adds")
        XCTAssertEqual(annotated.filter { $0.contains("[CrossKit] ◆") }.count, 3, "one lens line per declaration")
        XCTAssertTrue(line(after: "    let total = add(1, 2);")?.contains("  // [CrossKit] » total: i32, a: 1, b: 2") == true,
                      line(after: "    let total") ?? "")
        XCTAssertTrue(line(after: "    let label: i32 = \"no\";")?.contains("  // [CrossKit] ✖ error: ") == true,
                      line(after: "    let label") ?? "")

        // Refreshing again is stable, and Clear Inline Annotations restores the original text.
        let again = try await engine.run(.refreshInlineAnnotations, buffer: EditorBuffer(lines: annotated, selection: .caret(0, 0), contentUTI: "",
                                                                                         filePath: h.file("src/main.rs").path), transport: h.transport)
        XCTAssertEqual(EditorCommandEngine.apply(again.operations, to: annotated).lines.filter { $0.contains("[CrossKit]") }.count,
                       annotated.filter { $0.contains("[CrossKit]") }.count, "refresh replaces instead of duplicating")
        let cleared = try await engine.run(.clearInlineAnnotations, buffer: EditorBuffer(lines: annotated, selection: .caret(0, 0), contentUTI: ""),
                                           transport: h.transport)
        XCTAssertEqual(EditorCommandEngine.apply(cleared.operations, to: annotated).lines, original)

        // Toggling a kind off disables its command.
        h.settings.setFeature(.inlayHints, enabled: false, for: .rust)
        do {
            _ = try await engine.run(.showInlayHints, buffer: EditorBuffer(lines: original, selection: .caret(0, 0), contentUTI: "",
                                                                           filePath: h.file("src/main.rs").path), transport: h.transport)
            XCTFail("disabled inlay hints should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Inlay Hints"), error.localizedDescription)
        }
        await h.manager.shutdownAll()
        XCTAssertTrue(ProcessRegistry.activeGroups().isEmpty, "rust-analyzer must stop with the manager")
    }

    // MARK: Inline annotations with zls

    func testZigInlineAnnotations() async throws {
        guard ServerLocator().detect(.zig) != nil else { throw XCTSkip("zls not found") }
        let source = """
        const std = @import("std");

        fn add(a: i32, b: i32) i32 {
            return a + b;
        }

        pub fn main() void {
            const total = add(1, 2);
            std.debug.print("{d}\\n", .{total});
        }

        test "add works" {
            try std.testing.expectEqual(@as(i32, 3), add(1, 2));
        }

        """
        let h = try makeHarness("inline-zig", files: ["main.zig": source])
        addTeardownBlock { await h.tearDown() }
        let original = try h.buffer("main.zig", line: 0).lines
        let engine = EditorCommandEngine()
        var annotated = original
        for _ in 0..<10 {
            let outcome = try await engine.run(.showCodeLenses, buffer: EditorBuffer(lines: original, selection: .caret(0, 0), contentUTI: "",
                                                                                     filePath: h.file("main.zig").path), transport: h.transport)
            annotated = EditorCommandEngine.apply(outcome.operations, to: original).lines
            if annotated.joined().contains("▶ Run Test") { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("[e2e-features] zig lenses:\n\(annotated.joined())")
        let text = annotated.joined()
        XCTAssertTrue(text.contains("// [CrossKit] ◆ 2 references\nfn add(") || text.contains("// [CrossKit] ◆ 1 reference\nfn add("), text)
        XCTAssertTrue(text.contains("· ▶ Run · ⚙ Debug\npub fn main()"), text)
        XCTAssertTrue(text.contains("▶ Run Test · ⚙ Debug Test\ntest \"add works\""), text)
        let cleared = engine.clearInline(EditorBuffer(lines: annotated, selection: .caret(0, 0), contentUTI: ""))
        XCTAssertEqual(EditorCommandEngine.apply(cleared.operations, to: annotated).lines, original)
        await h.manager.shutdownAll()
        XCTAssertTrue(ProcessRegistry.activeGroups().isEmpty, "zls must stop with the manager")
    }
}

final class PreviewCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [PreviewResult] = []
    func add(_ result: PreviewResult) { lock.lock(); results.append(result); lock.unlock() }
    var last: PreviewResult? { lock.lock(); defer { lock.unlock() }; return results.last }
}
