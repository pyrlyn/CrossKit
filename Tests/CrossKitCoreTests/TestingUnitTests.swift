import XCTest
@testable import CrossKitCore

final class TestDiscoveryTests: XCTestCase {
    func testZigDiscovery() {
        let text = """
        const std = @import("std");
        fn add(a: i32, b: i32) i32 { return a + b; }
        test "add works" { try std.testing.expect(add(1, 2) == 3); }
        // test "commented out" {}
        test add {
        }
        test {
        }
        """
        let tests = TestDiscovery.discover(.zig, text: text, filePath: "/p/src/main.zig", root: URL(fileURLWithPath: "/p"))
        XCTAssertEqual(tests.map(\.filter), ["add works", "add", ""])
        XCTAssertEqual(tests.map(\.line), [2, 4, 6])
    }

    func testZigDiscoveryDecodesEscapedNames() {
        let text = #"test "says \"hi\" \\ done" {"# + "\n}\n"
        let tests = TestDiscovery.discover(.zig, text: text, filePath: "/p/main.zig", root: URL(fileURLWithPath: "/p"))
        XCTAssertEqual(tests.map(\.filter), [#"says "hi" \ done"#])
        XCTAssertEqual(TestDiscovery.unescapeZigString(#"a\tb\x41\u{e9}"#), "a\tbA\u{e9}")
    }

    func testRustDiscoveryWithModulesAndFilePath() {
        let text = """
        pub fn add(a: i32, b: i32) -> i32 { a + b }

        #[cfg(test)]
        mod tests {
            use super::*;

            #[test]
            fn adds() { assert_eq!(add(1, 2), 3); }

            #[tokio::test]
            async fn async_case() {}

            mod nested {
                #[test]
                #[ignore]
                fn deep() {}
            }

            fn helper() {}
        }
        """
        let root = URL(fileURLWithPath: "/crate")
        let tests = TestDiscovery.discover(.rust, text: text, filePath: "/crate/src/math/ops.rs", root: root)
        XCTAssertEqual(tests.map(\.filter), ["math::ops::tests::adds", "math::ops::tests::async_case", "math::ops::tests::nested::deep"])
        XCTAssertEqual(tests.map(\.line), [7, 10, 15])
        XCTAssertEqual(TestDiscovery.rustFileModulePath(filePath: "/crate/src/lib.rs", crateRoot: root), [])
        XCTAssertEqual(TestDiscovery.rustFileModulePath(filePath: "/crate/src/a/mod.rs", crateRoot: root), ["a"])
        XCTAssertEqual(TestDiscovery.rustTargetArguments(filePath: "/crate/tests/api.rs", crateRoot: root), ["--test", "api"])
        XCTAssertEqual(TestDiscovery.rustTargetArguments(filePath: "/crate/src/bin/tool.rs", crateRoot: root), ["--bin", "tool"])
        XCTAssertEqual(TestDiscovery.rustTargetArguments(filePath: "/crate/src/main.rs", crateRoot: root), ["--bins"])
    }

    func testKotlinDiscovery() {
        let text = """
        package demo.math

        import org.junit.jupiter.api.Test

        class CalcTest {
            @Test
            fun adds() {}

            @Test fun `fails on purpose`() {}

            fun helper() {}

            @Nested
            inner class Inner {
                @ParameterizedTest
                @ValueSource(ints = [1])
                fun param(x: Int) {}
            }
        }
        """
        let tests = TestDiscovery.discover(.kotlin, text: text, filePath: "/p/src/test/kotlin/CalcTest.kt", root: URL(fileURLWithPath: "/p"))
        XCTAssertEqual(tests.map(\.filter), ["demo.math.CalcTest.adds", "demo.math.CalcTest.fails on purpose", "demo.math.CalcTest$Inner.param"])
        XCTAssertEqual(tests.map(\.className), ["demo.math.CalcTest", "demo.math.CalcTest", "demo.math.CalcTest$Inner"])
        XCTAssertEqual(tests.map(\.line), [6, 8, 16])
        XCTAssertEqual(TestDiscovery.test(at: 12, in: tests)?.name, "fails on purpose")
        XCTAssertNil(TestDiscovery.test(at: 2, in: tests))
    }

    func testRustAnalyzerRunnablesParsing() {
        let result: JSONValue = [
            ["label": "test tests::adds", "kind": "cargo",
             "location": ["targetUri": "file:///c/src/lib.rs",
                          "targetRange": ["start": ["line": 6, "character": 4], "end": ["line": 7, "character": 5]],
                          "targetSelectionRange": ["start": ["line": 7, "character": 7], "end": ["line": 7, "character": 11]]],
             "args": ["cargoArgs": ["test", "--package", "sample", "--lib"], "executableArgs": ["tests::adds", "--exact", "--show-output"]]],
            ["label": "test-mod tests", "kind": "cargo", "args": [:]],
            ["label": "cargo check -p sample", "kind": "cargo", "args": [:]],
        ]
        let tests = BridgeHandler.parseRunnables(result)
        XCTAssertEqual(tests.count, 1)
        XCTAssertEqual(tests[0].filter, "tests::adds")
        XCTAssertEqual(tests[0].line, 7)
        XCTAssertEqual(tests[0].cargoArgs, ["test", "--package", "sample", "--lib"])
        XCTAssertEqual(tests[0].executableArgs, ["tests::adds", "--exact", "--show-output"])
    }
}

final class TestResultParserTests: XCTestCase {
    func testZigTestOutput() {
        let output = """
        1/3 main.test.add works...OK
        2/3 main.test.add fails...expected 4, found 3
        FAIL (TestExpectedEqual)
        /x/lib/std/testing.zig:93:17: 0x1 in expectEqualInner (test)
        3/3 main.decltest.add...OK
        2 passed; 0 skipped; 1 failed.
        error: the following test command failed with exit code 1:
        """
        let results = TestResultParser.zigTest(output)
        XCTAssertEqual(results.map(\.name), ["add works", "add fails", "add"])
        XCTAssertEqual(results.map(\.status), [.passed, .failed, .passed])
        XCTAssertTrue(results[1].output?.contains("expected 4, found 3") == true)
        XCTAssertEqual(TestResultParser.zigTest("1/1 main.test.a...SKIP\nAll 0 tests passed.").first?.status, .skipped)
    }

    func testZigBuildOutput() {
        let output = """
        test
        +- run test 2 pass, 1 fail (3 total)
        error: 'main.test.add fails' failed:
               expected 4, found 3
               /x/main.zig:4:20: 0x1 in test.add fails (test)
        failed command: ./.zig-cache/o/x/test
        Build Summary: 1/3 steps succeeded (1 failed); 2/3 tests passed (1 failed)
        """
        let results = TestResultParser.zigBuild(output)
        XCTAssertEqual(results.map(\.name), ["add fails"])
        XCTAssertEqual(results.first?.output?.hasPrefix("expected 4, found 3"), true)
        XCTAssertEqual(TestResultParser.zigBuildCounts(output)?.passed, 2)
        XCTAssertEqual(TestResultParser.zigBuildCounts(output)?.total, 3)
    }

    func testLibtestOutput() {
        let output = """
        running 3 tests
        test tests::skipped ... ignored
        test tests::adds ... ok
        test tests::fails ... FAILED

        failures:

        ---- tests::fails stdout ----
        debug out

        thread 'tests::fails' panicked at src/lib.rs:11:41:
        assertion `left == right` failed: math is hard

        failures:
            tests::fails

        test result: FAILED. 1 passed; 1 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.00s
        """
        let results = TestResultParser.libtest(output)
        XCTAssertEqual(results.map(\.name), ["tests::skipped", "tests::adds", "tests::fails"])
        XCTAssertEqual(results.map(\.status), [.skipped, .passed, .failed])
        XCTAssertTrue(results[2].output?.contains("math is hard") == true)
        XCTAssertFalse(results[2].output?.contains("tests::fails\n") == true)
    }

    func testNextestOutput() {
        let output = """
            Starting 2 tests across 1 binary (1 test skipped)
                PASS [   0.010s] (1/2) sample tests::adds
                FAIL [   0.012s] (2/2) sample tests::fails
          stdout ───

            running 1 test
            debug out
          stderr ───

            thread 'tests::fails' panicked at src/lib.rs:11:41:
            assertion `left == right` failed: math is hard

        ────────────
             Summary [   0.011s] 2 tests run: 1 passed, 1 failed, 1 skipped
                FAIL [   0.012s] (2/2) sample tests::fails
                SKIP [         ] (─/─) sample tests::skipped
        """
        let results = TestResultParser.nextest(output)
        XCTAssertEqual(results.map(\.name), ["tests::adds", "tests::fails"])
        XCTAssertEqual(results.map(\.status), [.passed, .failed])
        XCTAssertEqual(results[1].duration ?? 0, 0.012, accuracy: 0.0001)
        XCTAssertTrue(results[1].output?.contains("math is hard") == true)
    }

    func testJUnitXML() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="demo.CalcTest" tests="3" skipped="1" failures="1" errors="0" time="0.017">
          <testcase name="fails on purpose()" classname="demo.CalcTest" time="0.01">
            <failure message="org.opentest4j.AssertionFailedError: math is hard ==&gt; expected: &lt;4&gt; but was: &lt;3&gt;" type="x">stack trace here</failure>
          </testcase>
          <testcase name="adds()" classname="demo.CalcTest" time="0.001"/>
          <testcase name="later()" classname="demo.CalcTest" time="0"><skipped/></testcase>
        </testsuite>
        """
        let results = TestResultParser.junitXML(Data(xml.utf8))
        XCTAssertEqual(results.map(\.name), ["demo.CalcTest.fails on purpose", "demo.CalcTest.adds", "demo.CalcTest.later"])
        XCTAssertEqual(results.map(\.status), [.failed, .passed, .skipped])
        XCTAssertTrue(results[0].output?.hasPrefix("org.opentest4j.AssertionFailedError: math is hard") == true)
        XCTAssertEqual(results[1].duration, 0.001)
    }

    func testGradleUpToDateTestTaskReusesItsReports() throws {
        // A second run of unchanged, passing tests: Gradle skips the task and writes no new XML.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crosskit-junit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("TEST-demo.CalcTest.xml")
        try #"<testsuite name="demo.CalcTest"><testcase name="adds()" classname="demo.CalcTest" time="0.001"/></testsuite>"#
            .write(to: report, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: report.path)
        let upToDate = "> Task :lib:compileTestKotlin UP-TO-DATE\n> Task :lib:test UP-TO-DATE\n\nBUILD SUCCESSFUL in 1s\n"
        let results = TestResultParser.parse(kind: .gradle, output: upToDate, reportsDirectory: dir.path, since: Date())
        XCTAssertEqual(results.map(\.name), ["demo.CalcTest.adds"])
        XCTAssertEqual(results.map(\.status), [.passed])
        XCTAssertTrue(TestResultParser.gradleTestTaskSkipped("> Task :jvmTest FROM-CACHE\n"))
        // A task that ran must not pick up stale reports.
        XCTAssertEqual(TestResultParser.parse(kind: .gradle, output: "> Task :lib:test\n", reportsDirectory: dir.path, since: Date()), [])
    }

    func testGradleConsoleFallback() {
        let results = TestResultParser.gradleConsole("demo.CalcTest > adds() PASSED\ndemo.CalcTest > fails() FAILED\n")
        XCTAssertEqual(results.map(\.name), ["demo.CalcTest.adds", "demo.CalcTest.fails"])
        XCTAssertEqual(results.map(\.status), [.passed, .failed])
    }
}

final class TestRunnerResolverTests: XCTestCase {
    var home: URL!
    var settings: SettingsStore!
    var suite: String!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ck-tr-\(UUID().uuidString)").resolvingSymlinksInPath()
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

    func write(_ relative: String, _ text: String = "") throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    var resolver: TestRunnerResolver {
        let locator = ServerLocator(home: home, pathEnvironment: "", miseDataDirectory: home.appendingPathComponent("mise"))
        return TestRunnerResolver(settings: settings, toolchain: TestToolchain(locator: locator))
    }

    func testToolDetection() throws {
        XCTAssertNil(resolver.toolchain.zig())
        try makeExec("mise/installs/zig/0.17.1/zig")
        try makeExec("mise/installs/zig/0.16.0/zig")
        try makeExec(".cargo/bin/cargo")
        try makeExec("mise/installs/cargo-cargo-nextest/0.9.148/bin/cargo-nextest")
        try makeExec("mise/installs/gradle/9.8.2/gradle-9.8.2/bin/gradle")
        XCTAssertTrue(resolver.toolchain.zig()!.path.hasSuffix("0.17.1/zig"))
        XCTAssertTrue(resolver.toolchain.cargo()!.path.hasSuffix(".cargo/bin/cargo"))
        XCTAssertNotNil(resolver.toolchain.cargoNextest())
        XCTAssertTrue(resolver.toolchain.gradle()!.path.hasSuffix("bin/gradle"))
    }

    func testZigCommands() throws {
        try makeExec("mise/installs/zig/0.17.1/zig")
        try write("proj/build.zig")
        try write("proj/src/main.zig")
        let file = home.appendingPathComponent("proj/src/main.zig")
        let test = DiscoveredTest(name: "add works", filter: "add works", line: 3)
        let build = try resolver.command(language: .zig, file: file, scope: .file, tests: [test], cursorTest: nil)
        XCTAssertEqual(build.kind, .zigBuild)
        XCTAssertEqual(build.arguments, ["build", "test", "--summary", "all"])
        XCTAssertEqual(build.workingDirectory, home.appendingPathComponent("proj").path)
        settings.setTestRunner(.zigTest, for: .zig)
        settings.setTestArguments(["-OReleaseSafe"], for: .zig)
        let single = try resolver.command(language: .zig, file: file, scope: .cursor, tests: [test], cursorTest: test)
        XCTAssertEqual(single.arguments, ["test", file.path, "--test-filter", "add works", "-OReleaseSafe"])
    }

    func testRustCommands() throws {
        try makeExec(".cargo/bin/cargo")
        try write("crate/Cargo.toml")
        try write("crate/src/lib.rs")
        try write("crate/src/math.rs")
        let file = home.appendingPathComponent("crate/src/math.rs")
        let test = DiscoveredTest(name: "adds", filter: "math::tests::adds", line: 5)
        let all = try resolver.command(language: .rust, file: file, scope: .file, tests: [test], cursorTest: nil)
        XCTAssertEqual(all.kind, .cargoTest)
        XCTAssertEqual(all.arguments, ["test", "--lib", "--", "math::"])
        let one = try resolver.command(language: .rust, file: file, scope: .cursor, tests: [test], cursorTest: test)
        XCTAssertEqual(one.arguments, ["test", "--lib", "--", "math::tests::adds", "--exact"])
        var ra = test
        ra.cargoArgs = ["test", "--package", "sample", "--lib"]
        ra.executableArgs = ["math::tests::adds", "--exact", "--show-output"]
        let fromRA = try resolver.command(language: .rust, file: file, scope: .cursor, tests: [ra], cursorTest: ra)
        XCTAssertEqual(fromRA.arguments, ["test", "--package", "sample", "--lib", "--", "math::tests::adds", "--exact", "--show-output"])
        // Extra test arguments are cargo options: they go before `--`, not to the test binary.
        settings.setTestArguments(["--release"], for: .rust)
        XCTAssertEqual(try resolver.command(language: .rust, file: file, scope: .file, tests: [test], cursorTest: nil).arguments,
                       ["test", "--lib", "--release", "--", "math::"])
        XCTAssertEqual(try resolver.command(language: .rust, file: file, scope: .cursor, tests: [ra], cursorTest: ra).arguments,
                       ["test", "--package", "sample", "--lib", "--release", "--", "math::tests::adds", "--exact", "--show-output"])
        settings.setTestArguments([], for: .rust)

        try makeExec("mise/installs/cargo-cargo-nextest/0.9.148/bin/cargo-nextest")
        let nextest = try resolver.command(language: .rust, file: file, scope: .cursor, tests: [ra], cursorTest: ra)
        XCTAssertEqual(nextest.kind, .cargoNextest)
        XCTAssertEqual(Array(nextest.arguments.prefix(3)), ["nextest", "run", "--no-fail-fast"])
        XCTAssertTrue(nextest.arguments.contains("test(=math::tests::adds)"))
        XCTAssertTrue(nextest.environment["PATH"]!.contains("cargo-cargo-nextest/0.9.148/bin"))
    }

    func testKotlinCommandsAndMissingTool() throws {
        try write("app/settings.gradle.kts")
        try write("app/lib/build.gradle.kts")
        try write("app/lib/src/test/kotlin/CalcTest.kt")
        let file = home.appendingPathComponent("app/lib/src/test/kotlin/CalcTest.kt")
        let tests = [DiscoveredTest(name: "adds", filter: "demo.CalcTest.adds", line: 6, className: "demo.CalcTest")]
        XCTAssertThrowsError(try resolver.command(language: .kotlin, file: file, scope: .file, tests: tests, cursorTest: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("gradle was not found"), error.localizedDescription)
        }
        try makeExec("app/gradlew")
        let command = try resolver.command(language: .kotlin, file: file, scope: .file, tests: tests, cursorTest: nil)
        XCTAssertEqual(command.kind, .gradleWrapper)
        XCTAssertEqual(command.executable, home.appendingPathComponent("app/gradlew").path)
        XCTAssertEqual(command.arguments, [":lib:test", "--console=plain", "--tests", "demo.CalcTest"])
        XCTAssertEqual(command.reportsDirectory, home.appendingPathComponent("app/lib/build/test-results/test").path)
        let one = try resolver.command(language: .kotlin, file: file, scope: .cursor, tests: tests, cursorTest: tests[0])
        XCTAssertEqual(Array(one.arguments.suffix(2)), ["--tests", "demo.CalcTest.adds"])
    }

    func testMissingZigIsGraceful() throws {
        try write("solo/main.zig")
        let file = home.appendingPathComponent("solo/main.zig")
        XCTAssertThrowsError(try resolver.command(language: .zig, file: file, scope: .file, tests: [DiscoveredTest(name: "a", filter: "a", line: 0)], cursorTest: nil)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("zig was not found"))
        }
    }
}

final class TestMarkerEngineTests: XCTestCase {
    func testRunInFileReplacesMarkersAndSummarizes() async throws {
        var response = BridgeResponse()
        response.tests = [DiscoveredTest(name: "adds", filter: "tests::adds", line: 2), DiscoveredTest(name: "fails", filter: "tests::fails", line: 4)]
        response.testRun = TestRunResult(language: .rust, runner: .cargoTest, scope: .file, command: "cargo test", workingDirectory: "/c",
                                         duration: 1.5, exitCode: 101, tests: [
                                            TestCaseResult(name: "tests::adds", status: .passed, duration: 0.01, line: 2),
                                            TestCaseResult(name: "tests::fails", status: .failed, output: "assertion failed: math is hard", line: 4),
                                         ])
        let lines = ["mod tests {\n", "    #[test]\n", "    // [CrossKit] ▶ test adds — old\n", "    fn adds() {}\n", "    #[test]\n", "    fn fails() {}\n", "}\n"]
        let buffer = EditorBuffer(lines: lines, selection: .caret(5, 4), contentUTI: "public.rust-source", filePath: "/c/src/lib.rs")
        let outcome = try await EditorCommandEngine().run(.runTestsInFile, buffer: buffer, transport: StubTransport(response: response))
        let (after, selection) = EditorCommandEngine.apply(outcome.operations, to: lines)
        XCTAssertEqual(after, ["mod tests {\n",
                               "    // [CrossKit] ✓ passed 0.010s\n", "    #[test]\n", "    fn adds() {}\n",
                               "    // [CrossKit] ✗ failed — assertion failed: math is hard\n", "    #[test]\n", "    fn fails() {}\n", "}\n"])
        XCTAssertEqual(selection, .caret(6, 4))
        XCTAssertTrue(outcome.message!.contains("1 passed, 1 failed"))
        XCTAssertTrue(outcome.message!.contains("✗ tests::fails:5"))
        // Markers are recognised and removable with Clear CrossKit Annotations.
        let cleared = try await EditorCommandEngine().run(.clearAnnotations, buffer: EditorBuffer(lines: after, selection: .caret(0, 0), contentUTI: ""), transport: StubTransport(response: BridgeResponse()))
        XCTAssertEqual(EditorCommandEngine.apply(cleared.operations, to: after).lines, lines.filter { !$0.contains("[CrossKit]") })
    }

    func testShowTestsInsertsRunMarkers() async throws {
        var response = BridgeResponse()
        response.tests = [DiscoveredTest(name: "add works", filter: "add works", line: 1)]
        let lines = ["const std = @import(\"std\");\n", "test \"add works\" {\n", "}\n"]
        let outcome = try await EditorCommandEngine().run(.showTests, buffer: EditorBuffer(lines: lines, selection: .caret(0, 0), contentUTI: "", filePath: "/p/main.zig"), transport: StubTransport(response: response))
        let after = EditorCommandEngine.apply(outcome.operations, to: lines).lines
        XCTAssertEqual(after[1], "// [CrossKit] ▶ test add works — Editor › CrossKit › Run Test at Cursor\n")
        XCTAssertTrue(EditorCommandEngine.isTestMarker(after[1]))
        XCTAssertFalse(EditorCommandEngine.isTestMarker("// [CrossKit] error: x"))
    }
}
