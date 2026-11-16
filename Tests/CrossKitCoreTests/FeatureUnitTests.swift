import XCTest
@testable import CrossKitCore

// MARK: Kotlin targets

final class KotlinTargetTests: XCTestCase {
    var home: URL!
    var settings: SettingsStore!
    var suite: String!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: LaunchPlanner.canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("ck-kt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        suite = "dev.pyrlyn.CrossKit.tests.\(UUID().uuidString)"
        settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        removeDefaults(suite)
    }

    @discardableResult
    func write(_ relative: String, _ text: String = "") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func makeExec(_ relative: String) throws {
        let url = try write(relative, "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var locator: ServerLocator { ServerLocator(home: home, pathEnvironment: "", miseDataDirectory: home.appendingPathComponent("mise")) }
    var planner: LaunchPlanner {
        LaunchPlanner(settings: settings, resolver: TestRunnerResolver(settings: settings, toolchain: TestToolchain(locator: locator)),
                      debuggers: DebuggerLocator(locator: locator, developerDirectory: home.appendingPathComponent("Developer").path),
                      workDirectory: home.appendingPathComponent("work"))
    }

    static let multiplatformScript = """
    plugins {
        kotlin("multiplatform") version "2.4.21"
    }

    kotlin {
        jvmToolchain(21)
        jvm()
        jvm("desktop") { }
        macosArm64 {
            binaries { executable { entryPoint = "demo.main" } }
        }
        linuxX64()
        // iosArm64()   (commented out)
        js(IR) { browser() }
    }
    """

    func testParsesMultiplatformTargets() {
        let project = KotlinProject.parse(buildScript: Self.multiplatformScript, moduleDirectory: URL(fileURLWithPath: "/p/app"))
        XCTAssertTrue(project.isMultiplatform)
        XCTAssertTrue(project.declaresNativeExecutable)
        XCTAssertEqual(project.targets.map(\.name), ["jvm", "desktop", "macosArm64", "linuxX64", "js"])
        XCTAssertEqual(project.targets.map(\.platform), [.jvm, .jvm, .native, .native, .other])
        XCTAssertEqual(project.targets[1].preset, "jvm")
        XCTAssertEqual(project.jvmTargets.count, 2)
        XCTAssertEqual(project.targets[1].displayName, "JVM (desktop)")
        XCTAssertEqual(project.targets[2].taskSuffix, "MacosArm64")
        XCTAssertFalse(project.targets[3].runsOnHost)

        let jvmOnly = KotlinProject.parse(buildScript: "plugins { kotlin(\"jvm\") version \"2.4.21\" }\n", moduleDirectory: URL(fileURLWithPath: "/p"))
        XCTAssertFalse(jvmOnly.isMultiplatform)
        XCTAssertEqual(jvmOnly.targets, [KotlinTargetInfo(name: "jvm", preset: "jvm", platform: .jvm)])
        let catalog = KotlinProject.parse(buildScript: "plugins { alias(libs.plugins.kotlinMultiplatform) }\nkotlin {\n    macosX64(\"native\")\n}\n",
                                          moduleDirectory: URL(fileURLWithPath: "/p"))
        XCTAssertTrue(catalog.isMultiplatform)
        XCTAssertEqual(catalog.targets, [KotlinTargetInfo(name: "native", preset: "macosX64", platform: .native)])
    }

    func testTargetChoiceAndSourceSets() throws {
        let module = URL(fileURLWithPath: "/p/app")
        let project = KotlinProject.parse(buildScript: Self.multiplatformScript, moduleDirectory: module)
        let common = module.appendingPathComponent("src/commonMain/kotlin/demo/Main.kt")
        let host = KotlinProject.hostNativePreset
        XCTAssertEqual(try project.target(for: common, choice: .auto).name, "jvm", "auto prefers the JVM for shared code")
        XCTAssertEqual(try project.target(for: common, choice: .jvm).name, "jvm")
        XCTAssertEqual(try project.target(for: common, choice: .named("desktop")).name, "desktop")
        XCTAssertEqual(try project.target(for: common, choice: .named("linuxX64")).name, "linuxX64")
        if host == "macosArm64" {
            XCTAssertEqual(try project.target(for: common, choice: .native).name, "macosArm64")
            XCTAssertEqual(try project.target(for: module.appendingPathComponent("src/nativeMain/kotlin/A.kt"), choice: .jvm).name, "macosArm64",
                           "nativeMain belongs to the host's native target whatever the choice")
        }
        XCTAssertEqual(try project.target(for: module.appendingPathComponent("src/desktopTest/kotlin/A.kt"), choice: .native).name, "desktop")
        XCTAssertEqual(try project.target(for: module.appendingPathComponent("src/linuxX64Main/kotlin/A.kt"), choice: .jvm).name, "linuxX64")
        XCTAssertThrowsError(try project.target(for: common, choice: .named("wasmJs"))) {
            XCTAssertTrue($0.localizedDescription.contains("Available: jvm, desktop"), $0.localizedDescription)
        }
        let nativeOnly = KotlinProject.parse(buildScript: "plugins { kotlin(\"multiplatform\") }\nkotlin {\n    linuxX64()\n}\n", moduleDirectory: module)
        XCTAssertThrowsError(try nativeOnly.target(for: common, choice: .jvm)) { XCTAssertTrue($0.localizedDescription.contains("no JVM target")) }
        XCTAssertEqual(KotlinTargetChoice("desktop"), .named("desktop"))
        XCTAssertEqual(KotlinTargetChoice(nil), .auto)
        XCTAssertEqual(KotlinTargetChoice("native").rawValue, "native")
    }

    func testTaskNamesAndOutputs() {
        let module = URL(fileURLWithPath: "/p/app")
        let project = KotlinProject.parse(buildScript: Self.multiplatformScript, moduleDirectory: module)
        let native = project.targets[2]
        XCTAssertEqual(project.testTask(for: native), "macosArm64Test")
        XCTAssertEqual(project.testTask(for: project.targets[1]), "desktopTest")
        XCTAssertEqual(project.linkExecutableTask(for: native), "linkDebugExecutableMacosArm64")
        XCTAssertEqual(project.linkTestTask(for: native), "linkDebugTestMacosArm64")
        XCTAssertEqual(project.nativeExecutableDirectory(for: native).path, "/p/app/build/bin/macosArm64/debugExecutable")
        XCTAssertEqual(project.nativeTestBinary(for: native).path, "/p/app/build/bin/macosArm64/debugTest/test.kexe")
        XCTAssertEqual(project.testReportsDirectory(for: native).path, "/p/app/build/test-results/macosArm64Test")
        let jvmOnly = KotlinProject.parse(buildScript: "plugins { kotlin(\"jvm\") }", moduleDirectory: module)
        XCTAssertEqual(jvmOnly.testTask(for: jvmOnly.targets[0]), "test")
    }

    func testPlansNativeAndJVMTargets() throws {
        guard KotlinProject.hostNativePreset == "macosArm64" else { throw XCTSkip("fixture uses macosArm64") }
        try makeExec("Developer/usr/bin/lldb")
        try makeExec("Developer/usr/bin/lldb-dap")
        try makeExec("proj/gradlew")
        try write("proj/settings.gradle.kts")
        try write("proj/app/build.gradle.kts", Self.multiplatformScript)
        let text = "package demo\n\nfun main() {\n    println(\"hi\")\n}\n"
        let file = try write("proj/app/src/commonMain/kotlin/demo/Main.kt", text)

        settings.kotlinTarget = .native
        let plan = try planner.plan(language: .kotlin, file: file, text: text, cursorLine: 3, target: .file)
        XCTAssertEqual(plan.kotlinTarget?.name, "macosArm64")
        XCTAssertEqual(plan.debugger, .lldbDAP, "Kotlin/Native uses the native debugger")
        XCTAssertEqual(plan.build.first.map { Array($0[1...2]) }, [":app:linkDebugExecutableMacosArm64", "--console=plain"])
        XCTAssertTrue(plan.build[0].contains("--no-daemon"), "debug builds never use the daemon")
        XCTAssertEqual(plan.programSource, .nativeExecutable(directory: home.appendingPathComponent("proj/app/build/bin/macosArm64/debugExecutable").path))
        XCTAssertTrue(plan.title.hasSuffix("· Native macosArm64"), plan.title)

        settings.kotlinNativeDebugger = .lldb
        XCTAssertEqual(try planner.plan(language: .kotlin, file: file, text: text, cursorLine: 3, target: .file).debugger, .lldb)

        let testText = "package demo\n\nimport kotlin.test.Test\n\nclass CalcTest {\n    @Test\n    fun adds() {\n        check(true)\n    }\n}\n"
        let testFile = try write("proj/app/src/commonTest/kotlin/demo/CalcTest.kt", testText)
        let testPlan = try planner.plan(language: .kotlin, file: testFile, text: testText, cursorLine: 7, target: .test)
        XCTAssertEqual(testPlan.build.first?[1], ":app:linkDebugTestMacosArm64")
        XCTAssertEqual(testPlan.programSource, .path(home.appendingPathComponent("proj/app/build/bin/macosArm64/debugTest/test.kexe").path))
        XCTAssertEqual(testPlan.arguments, ["--ktest_filter=demo.CalcTest.adds"])

        // A launch configuration overrides the settings: JVM desktop target, run without a debugger.
        let root = home.appendingPathComponent("proj").path
        var config = try XCTUnwrap(settings.launchConfiguration(for: .kotlin, projectRoot: root))
        config.kotlinTarget = "desktop"
        settings.saveLaunchConfiguration(config)
        try FileManager.default.removeItem(at: home.appendingPathComponent("Developer"))
        let run = try planner.plan(language: .kotlin, file: file, text: text, cursorLine: 3, target: .file, purpose: .run)
        XCTAssertEqual(run.kotlinTarget?.name, "desktop")
        XCTAssertEqual(run.debuggerPath, "", "running needs no debugger")
        XCTAssertTrue(run.build[0].contains("-Pcrosskit.target=desktop"))
        XCTAssertEqual(run.build[0][1], ":app:crossKitClasspath")
        XCTAssertEqual(run.programSource, .jvmMain(mainClass: "demo.MainKt"))
        XCTAssertFalse(run.build[0].contains("--no-daemon"), "runs use the Gradle daemon by default")
        settings.gradleDaemon = false
        XCTAssertTrue(try planner.plan(language: .kotlin, file: file, text: text, cursorLine: 3, target: .file, purpose: .build).build[0].contains("--no-daemon"))

        config.kotlinTarget = "linuxX64"
        settings.saveLaunchConfiguration(config)
        XCTAssertThrowsError(try planner.plan(language: .kotlin, file: file, text: text, cursorLine: 3, target: .file, purpose: .run)) {
            XCTAssertTrue($0.localizedDescription.contains("do not run on this Mac"), $0.localizedDescription)
        }
        let build = try planner.plan(language: .kotlin, file: file, text: text, cursorLine: 3, target: .file, purpose: .build)
        XCTAssertEqual(build.build[0][1], ":app:linkDebugExecutableLinuxX64", "other targets can still be built")
    }

    func testMultiplatformTestTask() throws {
        try makeExec("proj/gradlew")
        try write("proj/settings.gradle.kts")
        try write("proj/app/build.gradle.kts", Self.multiplatformScript)
        let text = "package demo\n\nimport kotlin.test.Test\n\nclass CalcTest {\n    @Test\n    fun adds() {}\n}\n"
        let file = try write("proj/app/src/commonTest/kotlin/demo/CalcTest.kt", text)
        let resolver = TestRunnerResolver(settings: settings, toolchain: TestToolchain(locator: locator))
        let tests = TestDiscovery.discover(.kotlin, text: text, filePath: file.path, root: home.appendingPathComponent("proj"))
        var command = try resolver.command(language: .kotlin, file: file, scope: .cursor, tests: tests, cursorTest: tests.first)
        XCTAssertEqual(command.arguments.first, ":app:jvmTest")
        XCTAssertEqual(command.reportsDirectory, home.appendingPathComponent("proj/app/build/test-results/jvmTest").path)
        settings.kotlinTarget = .named("macosArm64")
        command = try resolver.command(language: .kotlin, file: file, scope: .file, tests: tests, cursorTest: nil)
        XCTAssertEqual(command.arguments.first, ":app:macosArm64Test")
        XCTAssertTrue(command.arguments.contains("demo.CalcTest"))
    }

    func testLaunchConfigurationDecodesWithoutKotlinTarget() throws {
        let old = #"[{"language":"kotlin","projectRoot":"/p","program":"","arguments":[],"environment":{},"workingDirectory":"","buildBeforeLaunch":true,"testArguments":[],"updatedAt":0}]"#
        settings.defaults.set(Data(old.utf8), forKey: "launchConfigurations")
        let config = try XCTUnwrap(settings.launchConfigurations().first)
        XCTAssertNil(config.kotlinTarget)
    }
}

// MARK: Compose previews

final class PreviewDiscoveryTests: XCTestCase {
    static let source = """
    package demo

    import androidx.compose.runtime.Composable
    import androidx.compose.ui.tooling.preview.Preview
    import androidx.compose.ui.tooling.preview.PreviewParameter

    @Composable
    fun Greeting(name: String) {}

    @Preview
    @Composable
    private fun GreetingPreview() {
        Greeting("CrossKit")
    }

    @Preview(
        name = "Red box, wide",
        widthDp = 320,
        heightDp = 100,
        showBackground = true,
        backgroundColor = 0xFF00FF00,
    )
    @Composable
    fun RedBoxPreview() {}

    @Preview(name = "Small") @Preview(name = "Large", widthDp = 800)
    @Composable
    fun Sizes() {}

    @Preview @Composable fun OneLiner() {}

    @Preview
    annotation class MyMultiPreview

    object Catalog {
        @androidx.compose.desktop.ui.tooling.preview.Preview
        @Composable
        fun Item() {}
    }

    @Composable
    fun WithParameter(@PreviewParameter(Names::class) name: String) {}
    """

    func testDiscoversPreviews() {
        let previews = PreviewDiscovery.discover(text: Self.source, fileName: "Greeting.kt")
        XCTAssertEqual(previews.map(\.name), ["GreetingPreview", "Red box, wide", "Small", "Large", "OneLiner", "Item"])
        XCTAssertEqual(previews.map(\.function), ["GreetingPreview", "RedBoxPreview", "Sizes", "Sizes", "OneLiner", "Item"])
        XCTAssertEqual(previews[0].className, "demo.GreetingKt")
        XCTAssertEqual(previews[0].line, 11)
        XCTAssertEqual(previews[0].annotationLine, 9)
        XCTAssertEqual(previews[1].widthDp, 320)
        XCTAssertEqual(previews[1].heightDp, 100)
        XCTAssertTrue(previews[1].showBackground)
        XCTAssertEqual(previews[1].backgroundColor, 0xFF00FF00)
        XCTAssertEqual(previews[3].index, 1)
        XCTAssertEqual(previews[3].widthDp, 800)
        XCTAssertNotEqual(previews[2].id, previews[3].id)
        XCTAssertEqual(previews[5].className, "demo.Catalog")
        XCTAssertEqual(PreviewDiscovery.preview(at: 22, in: previews)?.function, "RedBoxPreview")
        XCTAssertEqual(PreviewDiscovery.preview(at: 27, in: previews)?.name, "Small", "the first of several annotations")
        XCTAssertNil(PreviewDiscovery.preview(at: 3, in: previews))
        XCTAssertEqual(PreviewDiscovery.parseColor("0xFFFF_0000"), 0xFFFF0000)
        XCTAssertEqual(PreviewDiscovery.parseColor("4294967295L"), 0xFFFFFFFF)
    }

    func testPreviewSummaryAndRendererSource() {
        let preview = ComposePreview(name: "A", function: "A", className: "demo.AKt", line: 1, annotationLine: 0)
        let result = PreviewResult(id: UUID(), filePath: "/p/A.kt", projectRoot: "/p", target: "JVM", renderedAt: Date(), duration: 2.25,
                                   density: 2, previews: [RenderedPreview(preview: preview, imagePath: "/x/0.png", pixelWidth: 10, pixelHeight: 10),
                                                          RenderedPreview(preview: preview, error: "boom")],
                                   focusedID: preview.id, log: "")
        XCTAssertEqual(result.summary, "Rendered 1 of 2 previews in A.kt (2.2s); 1 failed")
        XCTAssertTrue(PreviewRendererSource.java.contains("public final class CrossKitPreviewRenderer"))
        XCTAssertTrue(PreviewRendererSource.java.contains("ImageComposeScene"))
    }

    func testPreviewCommandShowsSummary() async throws {
        let preview = ComposePreview(name: "Card", function: "CardPreview", className: "demo.AKt", line: 4, annotationLine: 2)
        var response = BridgeResponse()
        response.preview = PreviewResult(id: UUID(), filePath: "/p/A.kt", projectRoot: "/p", target: "JVM", renderedAt: Date(), duration: 1,
                                         density: 2, previews: [RenderedPreview(preview: preview, imagePath: "/x/0.png", pixelWidth: 4, pixelHeight: 4)],
                                         focusedID: preview.id, log: "", warning: "unsaved")
        let transport = RecordingTransport(response: response)
        let buffer = EditorBuffer(lines: ["a\n"], selection: .caret(0, 0), contentUTI: "", filePath: "/p/A.kt")
        let outcome = try await EditorCommandEngine().run(.showPreview, buffer: buffer, transport: transport)
        XCTAssertTrue(outcome.operations.isEmpty)
        XCTAssertEqual(outcome.message, "◉ Rendered 1 of 1 preview in A.kt (1.0s)\nShowing Card in CrossKit › Preview.\n⚠︎ unsaved")
        XCTAssertEqual(transport.lastRequest?.operation, .preview)
        XCTAssertTrue(EditorCommandEngine.isLongRunning(.showPreview))
    }
}

// MARK: Inline annotations

final class InlineAnnotationTests: XCTestCase {
    func testTrailingSegments() {
        let line = "let x = 1;  // [CrossKit] » x: i32  // [CrossKit] ✖ error: bad\n"
        let split = InlineAnnotations.splitTrailing(line)
        XCTAssertEqual(split.code, "let x = 1;")
        XCTAssertEqual(split.segments, ["» x: i32", "✖ error: bad"])
        XCTAssertEqual(InlineAnnotations.stripTrailing(line, kinds: [.inlayHints]), "let x = 1;  // [CrossKit] ✖ error: bad\n")
        XCTAssertEqual(InlineAnnotations.stripTrailing(line), "let x = 1;\n")
        XCTAssertEqual(InlineAnnotations.appendTrailing("a\n", "◆ b"), "a  // [CrossKit] ◆ b\n")
        XCTAssertEqual(InlineAnnotations.stripTrailing("call() // [CrossKit] typed by hand\n"), "call() // [CrossKit] typed by hand\n",
                       "a single space is not a CrossKit segment")
        XCTAssertEqual(InlineAnnotations.kind(ofLine: "    // [CrossKit] ◆ 2 references\n"), .codeLens)
        XCTAssertEqual(InlineAnnotations.kind(ofLine: "// [CrossKit] ⚠ warning: x\n"), .errorLens)
        XCTAssertNil(InlineAnnotations.kind(ofLine: "// [CrossKit] ✓ passed\n"))
        XCTAssertEqual(InlineAnnotations.cleanText("a  // [CrossKit] » h\n// [CrossKit] ◆ 1 reference\nb\n"), "a\nb\n")
    }

    func testUnsafeLineEnds() {
        let kotlin = ["val a = 1\n", "val s = \"\"\"\n", "  inside\n", "\"\"\".trim()\n", "/* start\n", " end */ val b = 2\n", "val c = \"//\" + 1\n"]
        XCTAssertEqual(InlineAnnotations.unsafeLineEnds(kotlin, language: .kotlin), [1, 2, 4])
        let rust = ["let s = \"multi\n", "line\";\n", "let r = r#\"raw\n", "\"#;\n", "fn f<'a>(x: &'a str) -> char { 'x' }\n", "/* a /* nested */\n", "*/\n"]
        XCTAssertEqual(InlineAnnotations.unsafeLineEnds(rust, language: .rust), [0, 2, 5])
        let zig = ["const s =\n", "    \\\\multi line string\n", ";\n", "const t = \"a\"; // ok\n"]
        XCTAssertEqual(InlineAnnotations.unsafeLineEnds(zig, language: .zig), [1])
    }

    func testRenderingHintsLensesAndErrorLens() {
        let code = "    let total = add(1, compute(2, 3));"
        let hints = [BridgeInlayHint(line: 0, character: 13, label: ": i32", kind: .type),
                     BridgeInlayHint(line: 0, character: 20, label: "a:", kind: .parameter, paddingRight: true),
                     BridgeInlayHint(line: 0, character: 23, label: "b:", kind: .parameter, paddingRight: true)]
        XCTAssertEqual(InlineAnnotations.renderHints(code, hints: hints), "    let total‹: i32› = add(‹a:› 1, ‹b:› compute(2, 3));")
        XCTAssertEqual(InlineAnnotations.summarizeHints(code, hints: hints), "total: i32, a: 1, b: compute(2, 3)")
        XCTAssertEqual(InlineAnnotations.lensText(BridgeCodeLens(line: 0, symbol: "f", references: 1, actions: ["▶ Run"])), "◆ 1 reference · ▶ Run")
        XCTAssertEqual(InlineAnnotations.lensText(BridgeCodeLens(line: 0, symbol: "f", references: 3)), "◆ 3 references")
        XCTAssertNil(InlineAnnotations.lensText(BridgeCodeLens(line: 0, symbol: "f")))
        let range = BridgeRange(startLine: 0, startCharacter: 4, endLine: 0, endCharacter: 5)
        let text = InlineAnnotations.errorLensText([BridgeDiagnostic(range: range, severity: 2, message: "unused", source: "rustc"),
                                                     BridgeDiagnostic(range: range, severity: 1, message: "mismatched types\nexpected i32", source: "rustc")],
                                                    showSource: true)
        XCTAssertEqual(text, "✖ error: mismatched types (rustc) (+1 more)")
    }

    static let lines = [
        "fn add(a: i32, b: i32) -> i32 {\n",
        "    a + b\n",
        "}\n",
        "fn main() {\n",
        "    let total = add(1, 2);\n",
        "    let s: i32 = \"no\";\n",
        "}\n",
    ]

    func response() -> BridgeResponse {
        var response = BridgeResponse()
        response.language = .rust
        response.inlineKinds = InlineKind.allCases
        var options = InlineAnnotationOptions()
        options.hintPlacement = .endOfLine
        response.inlineOptions = options
        response.codeLenses = [BridgeCodeLens(line: 0, symbol: "add", references: 1),
                               BridgeCodeLens(line: 3, symbol: "main", references: 0, actions: ["▶ Run", "⚙ Debug"])]
        response.inlayHints = [BridgeInlayHint(line: 4, character: 13, label: ": i32", kind: .type),
                               BridgeInlayHint(line: 4, character: 20, label: "a:", kind: .parameter, paddingRight: true)]
        response.diagnostics = [BridgeDiagnostic(range: BridgeRange(startLine: 5, startCharacter: 17, endLine: 5, endCharacter: 21),
                                                 severity: 1, message: "mismatched types", source: "rustc")]
        response.diagnosticsReceived = true
        return response
    }

    func testRefreshInsertsReplacesAndClears() async throws {
        let transport = RecordingTransport(response: response())
        let engine = EditorCommandEngine()
        let buffer = EditorBuffer(lines: Self.lines, selection: .caret(4, 8), contentUTI: "", filePath: "/p/src/main.rs")
        let first = try await engine.run(.refreshInlineAnnotations, buffer: buffer, transport: transport)
        XCTAssertNil(first.message)
        XCTAssertNil(transport.lastRequest?.inlineKinds, "refresh asks for every enabled kind")
        let (annotated, selection) = EditorCommandEngine.apply(first.operations, to: Self.lines)
        XCTAssertEqual(annotated, [
            "// [CrossKit] ◆ 1 reference\n",
            "fn add(a: i32, b: i32) -> i32 {\n",
            "    a + b\n",
            "}\n",
            "// [CrossKit] ◆ 0 references · ▶ Run · ⚙ Debug\n",
            "fn main() {\n",
            "    let total = add(1, 2);  // [CrossKit] » total: i32, a: 1\n",
            "    let s: i32 = \"no\";  // [CrossKit] ✖ error: mismatched types (rustc)\n",
            "}\n",
        ])
        XCTAssertEqual(selection, .caret(6, 8), "the caret stays on its code line")

        // Running again replaces instead of duplicating; the request sees the code without annotations.
        let again = try await engine.run(.refreshInlineAnnotations, buffer: EditorBuffer(lines: annotated, selection: .caret(6, 8), contentUTI: "",
                                                                                         filePath: "/p/src/main.rs"), transport: transport)
        XCTAssertEqual(transport.lastRequest?.text, Self.lines.joined())
        XCTAssertEqual(transport.lastRequest?.line, 4)
        XCTAssertEqual(EditorCommandEngine.apply(again.operations, to: annotated).lines, annotated)

        // Show Code Lenses only touches lenses.
        let lensOnly = try await engine.run(.showCodeLenses, buffer: EditorBuffer(lines: annotated, selection: .caret(0, 0), contentUTI: "",
                                                                                   filePath: "/p/src/main.rs"), transport: transport)
        XCTAssertEqual(transport.lastRequest?.inlineKinds, [.codeLens])
        XCTAssertTrue(transport.lastRequest?.text.contains("» total") == true, "other kinds stay in the request text")
        XCTAssertEqual(EditorCommandEngine.apply(lensOnly.operations, to: annotated).lines.filter { $0.contains("◆") }.count, 2)

        // Clear Inline Annotations restores the original text; so does Clear CrossKit Annotations.
        let cleared = engine.clearInline(EditorBuffer(lines: annotated, selection: .caret(6, 3), contentUTI: ""))
        let (restored, caret) = EditorCommandEngine.apply(cleared.operations, to: annotated)
        XCTAssertEqual(restored, Self.lines)
        XCTAssertEqual(caret, .caret(4, 3))
        let all = try await engine.run(.clearAnnotations, buffer: EditorBuffer(lines: annotated, selection: .caret(0, 0), contentUTI: ""),
                                       transport: transport)
        XCTAssertEqual(EditorCommandEngine.apply(all.operations, to: annotated).lines, Self.lines)
        XCTAssertEqual(engine.clearInline(EditorBuffer(lines: Self.lines, selection: .caret(0, 0), contentUTI: "")).message,
                       "No inline annotations to remove.")
    }

    func testHintsAboveAndUnsafeLinesAndEmptyResults() async throws {
        var r = response()
        r.inlineKinds = [.inlayHints, .errorLens]
        r.inlineOptions = InlineAnnotationOptions()   // hints above the line
        r.diagnostics = [BridgeDiagnostic(range: BridgeRange(startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 1), severity: 2, message: "inside")]
        r.inlayHints = [BridgeInlayHint(line: 0, character: 8, label: ": String", kind: .type)]
        let lines = ["let text = r#\"raw\n", "still raw\"#;\n"]
        let transport = RecordingTransport(response: r)
        let outcome = try await EditorCommandEngine().run(.refreshInlineAnnotations, buffer: EditorBuffer(lines: lines, selection: .caret(0, 0), contentUTI: ""),
                                                          transport: transport)
        XCTAssertEqual(EditorCommandEngine.apply(outcome.operations, to: lines).lines, [
            "// [CrossKit] » let text‹: String› = r#\"raw\n",
            "// [CrossKit] ⚠ warning: inside\n",
            "let text = r#\"raw\n",
            "still raw\"#;\n",
        ], "a line ending inside a raw string gets its ErrorLens above")

        var empty = BridgeResponse()
        empty.language = .zig
        empty.inlineKinds = [.codeLens, .errorLens]
        empty.diagnosticsReceived = false
        let none = try await EditorCommandEngine().run(.refreshInlineAnnotations, buffer: EditorBuffer(lines: ["x\n"], selection: .caret(0, 0), contentUTI: ""),
                                                       transport: RecordingTransport(response: empty))
        XCTAssertEqual(none.message, "CrossKit: no code lenses, no diagnostics reported yet (try again in a moment).")
    }

    func testLensesOnTheSameLineAreMerged() async throws {
        var r = BridgeResponse()
        r.language = .rust
        r.inlineKinds = [.codeLens]
        r.inlineOptions = InlineAnnotationOptions()
        r.codeLenses = [BridgeCodeLens(line: 1, symbol: "adds", references: 0),
                        BridgeCodeLens(line: 2, symbol: "adds", actions: ["▶ Run Test", "⚙ Debug Test"])]
        let lines = ["mod tests {\n", "    #[test]\n", "    fn adds() {}\n", "}\n"]
        let outcome = try await EditorCommandEngine().run(.showCodeLenses, buffer: EditorBuffer(lines: lines, selection: .caret(0, 0), contentUTI: ""),
                                                          transport: RecordingTransport(response: r))
        XCTAssertEqual(EditorCommandEngine.apply(outcome.operations, to: lines).lines, [
            "mod tests {\n", "    // [CrossKit] ◆ 0 references · ▶ Run Test · ⚙ Debug Test\n", "    #[test]\n", "    fn adds() {}\n", "}\n",
        ])
    }

    func testLSPConversions() {
        let hints: JSONValue = .array([
            ["position": ["line": 2, "character": 5], "label": ": i32", "kind": 1, "paddingLeft": false],
            ["position": ["line": 3, "character": 1], "label": .array([["value": "count"], ["value": ":"]]), "kind": 2, "paddingRight": true],
            ["position": ["line": 4, "character": 0], "label": "  "],
        ])
        XCTAssertEqual(LSPConvert.inlayHints(hints), [
            BridgeInlayHint(line: 2, character: 5, label: ": i32", kind: .type),
            BridgeInlayHint(line: 3, character: 1, label: "count:", kind: .parameter, paddingRight: true),
        ])
        let range: JSONValue = ["start": ["line": 1, "character": 0], "end": ["line": 5, "character": 1]]
        let name: JSONValue = ["start": ["line": 1, "character": 3], "end": ["line": 1, "character": 6]]
        let symbols: JSONValue = .array([["name": "Calc", "kind": 5, "range": range, "selectionRange": name,
                                          "children": .array([["name": "add", "kind": 6, "range": range, "selectionRange": name]])]])
        XCTAssertEqual(LSPConvert.symbols(symbols).map(\.name), ["Calc", "add"])
        let flat: JSONValue = .array([["name": "f", "kind": 12, "location": ["uri": "file:///a.zig", "range": range]]])
        XCTAssertEqual(LSPConvert.symbols(flat).first?.selection.startLine, 1)
    }

    func testOptionsPersist() {
        let suite = "dev.pyrlyn.CrossKit.tests.\(UUID().uuidString)"
        defer { removeDefaults(suite) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(settings.inlineOptions, InlineAnnotationOptions())
        var options = settings.inlineOptions
        options.hintPlacement = .endOfLine
        options.errorLensMinimumSeverity = 1
        options.lensReferences = false
        settings.inlineOptions = options
        XCTAssertEqual(SettingsStore(defaults: UserDefaults(suiteName: suite)!).inlineOptions, options)
        XCTAssertTrue(settings.isFeatureEnabled(.codeLens, for: .zig))
        XCTAssertFalse(Feature.preview.applies(to: .rust))
        XCTAssertTrue(Feature.preview.applies(to: .kotlin))
        XCTAssertEqual(settings.kotlinTarget, .auto)
        settings.kotlinTarget = .named("desktop")
        XCTAssertEqual(settings.kotlinTarget, .named("desktop"))
        XCTAssertTrue(settings.gradleDaemon)
        XCTAssertEqual(settings.gradleDaemonArguments, [])
    }
}

// MARK: Build & Run

final class RunCommandTests: XCTestCase {
    func testRunSummaries() async throws {
        var run = ProgramRun(id: "1", mode: .run, title: "main.zig", language: .zig, target: nil, projectRoot: "/p", commands: [],
                             program: "/p/main", startedAt: Date(timeIntervalSinceNow: -1.5), finishedAt: Date(), state: .succeeded,
                             exitCode: 0, output: "$ zig build-exe main.zig\n\nresult 42\n", error: nil)
        XCTAssertTrue(run.summary.hasPrefix("✓ Run succeeded: main.zig ("), run.summary)
        XCTAssertTrue(run.summary.hasSuffix("result 42"), run.summary)
        run.state = .failed
        run.exitCode = 3
        XCTAssertTrue(run.summary.hasPrefix("✗ main.zig exited with code 3"), run.summary)
        run.state = .running
        XCTAssertTrue(run.summary.hasPrefix("▶ main.zig is still running"), run.summary)

        var response = BridgeResponse()
        run.state = .succeeded
        run.mode = .build
        response.programRun = run
        let transport = RecordingTransport(response: response)
        let buffer = EditorBuffer(lines: ["a\n"], selection: .caret(0, 0), contentUTI: "", filePath: "/p/main.zig")
        let outcome = try await EditorCommandEngine().run(.buildProject, buffer: buffer, transport: transport)
        XCTAssertTrue(outcome.operations.isEmpty)
        XCTAssertTrue(outcome.message?.hasPrefix("✓ Build succeeded: main.zig") == true)
        XCTAssertEqual(transport.lastRequest?.operation, .build)
        _ = try await EditorCommandEngine().run(.runFile, buffer: buffer, transport: transport)
        XCTAssertEqual(transport.lastRequest?.operation, .run)
        XCTAssertEqual(BridgeOperation.run.feature, .run)
        XCTAssertNil(BridgeOperation.inlineAnnotations.feature)
    }
}
