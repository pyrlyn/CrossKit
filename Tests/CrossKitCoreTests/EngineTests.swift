import XCTest
@testable import CrossKitCore

struct StubTransport: BridgeTransport {
    let response: BridgeResponse
    func send(_ request: BridgeRequest) async throws -> BridgeResponse { response }
}

final class EngineTests: XCTestCase {
    let engine = EditorCommandEngine()

    func buffer(_ lines: [String], _ line: Int, _ column: Int) -> EditorBuffer {
        EditorBuffer(lines: lines.map { $0 + "\n" }, selection: .caret(line, column), contentUTI: "public.rust-source", filePath: "/p/src/main.rs")
    }

    func testCompleteReplacesPrefixAndMovesCaret() async throws {
        var response = BridgeResponse()
        response.completions = [BridgeCompletion(label: "zzz", insertText: "zzz"),
                                BridgeCompletion(label: "compute_answer", insertText: "compute_answer", sortText: "a")]
        let b = buffer(["fn main() {", "    let x = compute_an", "}"], 1, 22)
        let outcome = try await engine.run(.complete, buffer: b, transport: StubTransport(response: response))
        let (lines, selection) = EditorCommandEngine.apply(outcome.operations, to: b.lines)
        XCTAssertEqual(lines[1], "    let x = compute_answer\n")
        XCTAssertEqual(selection, .caret(1, 26))
    }

    func testDiagnosticsInsertAnnotationsAndClearRemovesThem() async throws {
        var response = BridgeResponse()
        response.diagnostics = [BridgeDiagnostic(range: BridgeRange(startLine: 1, startCharacter: 4, endLine: 1, endCharacter: 8), severity: 1, message: "expected expression")]
        let b = buffer(["fn main() {", "    let = ;", "}"], 2, 0)
        let outcome = try await engine.run(.diagnostics, buffer: b, transport: StubTransport(response: response))
        let (lines, selection) = EditorCommandEngine.apply(outcome.operations, to: b.lines)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[1], "    // [CrossKit] error: expected expression [2:5]\n")
        XCTAssertEqual(selection, .caret(3, 0))

        let cleared = try await engine.run(.clearAnnotations, buffer: EditorBuffer(lines: lines, selection: .caret(3, 0), contentUTI: ""), transport: StubTransport(response: BridgeResponse()))
        XCTAssertEqual(EditorCommandEngine.apply(cleared.operations, to: lines).lines, b.lines)
    }

    func testDefinitionInSameFileSelectsRange() async throws {
        var response = BridgeResponse()
        response.filePath = "/p/src/main.rs"
        response.locations = [BridgeLocation(path: "/p/src/main.rs", range: BridgeRange(startLine: 0, startCharacter: 3, endLine: 0, endCharacter: 17))]
        let outcome = try await engine.run(.goToDefinition, buffer: buffer(["fn compute_answer() {}"], 0, 0), transport: StubTransport(response: response))
        XCTAssertEqual(outcome.operations, [.select(EditorRange(start: EditorPosition(line: 0, column: 3), end: EditorPosition(line: 0, column: 17)))])
    }

    func testDefinitionInOtherFileAnnotates() async throws {
        var response = BridgeResponse()
        response.filePath = "/p/src/main.rs"
        response.rootPath = "/p"
        response.locations = [BridgeLocation(path: "/p/src/lib.rs", range: BridgeRange(startLine: 9, startCharacter: 0, endLine: 9, endCharacter: 3), preview: "pub fn f()")]
        let b = buffer(["f();"], 0, 0)
        let outcome = try await engine.run(.goToDefinition, buffer: b, transport: StubTransport(response: response))
        let lines = EditorCommandEngine.apply(outcome.operations, to: b.lines).lines
        XCTAssertEqual(lines[1], "// [CrossKit]   src/lib.rs:10:1  pub fn f()\n")
        XCTAssertNotNil(outcome.message)
    }

    func testHoverStripsFences() async throws {
        var response = BridgeResponse()
        response.hover = "```kotlin\nfun computeAnswer(value: Int): Int\n```"
        let b = buffer(["    computeAnswer(1)"], 0, 6)
        let outcome = try await engine.run(.hover, buffer: b, transport: StubTransport(response: response))
        let lines = EditorCommandEngine.apply(outcome.operations, to: b.lines).lines
        XCTAssertEqual(lines.first, "    // [CrossKit] fun computeAnswer(value: Int): Int\n")
    }

    func testBridgeErrorSurfaces() async {
        do {
            _ = try await engine.run(.hover, buffer: buffer(["x"], 0, 0), transport: StubTransport(response: .failure("boom")))
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "boom")
        }
    }

    func testRanking() {
        let items = [BridgeCompletion(label: "Beta", insertText: "Beta"), BridgeCompletion(label: "alpha", insertText: "alpha"),
                     BridgeCompletion(label: "alphabet", insertText: "alphabet", sortText: "0")]
        XCTAssertEqual(EditorCommandEngine.bestCompletion(items, prefix: "alp")?.label, "alphabet")
        XCTAssertEqual(EditorCommandEngine.bestCompletion(items, prefix: "bet")?.label, "Beta")
    }
}

final class SettingsAndLocatorTests: XCTestCase {
    func testSettingsDefaultsAndPersistence() {
        let suite = "dev.pyrlyn.CrossKit.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeDefaults(suite) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.isEnabled(.zig))
        XCTAssertTrue(settings.isFeatureEnabled(.hover, for: .rust))
        XCTAssertEqual(settings.language(forPath: "/x/Main.kts"), .kotlin)
        XCTAssertEqual(settings.language(forPath: "/x/main.rs"), .rust)
        settings.setEnabled(false, for: .zig)
        settings.setFeature(.hover, enabled: false, for: .rust)
        settings.setCustomServerPath("/opt/zls", for: .zig)
        let reread = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertFalse(reread.isEnabled(.zig))
        XCTAssertFalse(reread.isFeatureEnabled(.hover, for: .rust))
        XCTAssertEqual(reread.customServerPath(for: .zig), "/opt/zls")
        reread.setCustomServerPath(nil, for: .zig)
        XCTAssertNil(settings.customServerPath(for: .zig))
        var status = ServerStatus(state: .error, lastError: "x")
        status.pid = 42
        settings.writeStatus(status, for: .kotlin)
        XCTAssertEqual(reread.status(for: .kotlin).pid, 42)
    }

    func testLocatorFindsFakeInstalls() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ck-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        func makeExec(_ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try makeExec(".rustup/toolchains/1.80.0-aarch64-apple-darwin/bin/rust-analyzer")
        try makeExec(".rustup/toolchains/1.99.1-aarch64-apple-darwin/bin/rust-analyzer")
        try makeExec(".local/share/mise/installs/zls/0.9.0/zls")
        try makeExec(".local/share/mise/installs/zls/0.17.0/zls")
        try makeExec(".local/share/mise/installs/github-fwcd-kotlin-language-server/1.3.13/bin/kotlin-language-server")
        try makeExec(".local/share/mise/installs/github-fwcd-kotlin-language-server/1.3.13/bin/kotlin-language-server.bat")
        let locator = ServerLocator(home: home, pathEnvironment: "", miseDataDirectory: home.appendingPathComponent(".local/share/mise"))
        XCTAssertTrue(locator.detect(.rust)!.path.contains("1.99.1"))
        XCTAssertTrue(locator.detect(.zig)!.path.hasSuffix("zls/0.17.0/zls"))
        XCTAssertTrue(locator.detect(.kotlin)!.path.hasSuffix("bin/kotlin-language-server"))
        XCTAssertEqual(locator.candidates(for: .zig).count, 2)
    }

    func testWorkspaceRoot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ck-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try "".write(to: dir.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        let root = WorkspaceResolver.root(for: dir.appendingPathComponent("src/deep/x.rs"), language: .rust)
        XCTAssertEqual(root.standardizedFileURL.path, dir.standardizedFileURL.path)
    }
}

final class BridgeTransportTests: XCTestCase {
    func testRoundTripOverMessagePort() async throws {
        let name = "dev.pyrlyn.CrossKit.tests.\(UUID().uuidString.prefix(8))"
        let server = BridgeServer(portName: name) { request in
            var response = BridgeResponse()
            response.hover = "\(request.operation.rawValue):\(request.line):\(request.text.count)"
            return response
        }
        try server.start()
        defer { server.stop() }
        let client = BridgeClient(portName: name, timeout: 5)
        let response = try await client.send(BridgeRequest(operation: .hover, text: "héllo", line: 3, character: 1))
        XCTAssertEqual(response.hover, "hover:3:5")
        async let a = client.send(BridgeRequest(operation: .ping))
        async let b = client.send(BridgeRequest(operation: .definition, line: 9))
        let (ra, rb) = try await (a, b)
        XCTAssertEqual(ra.hover, "ping:0:0")
        XCTAssertEqual(rb.hover, "definition:9:0")
    }

    func testClientReportsMissingHost() async {
        let client = BridgeClient(portName: "dev.pyrlyn.CrossKit.missing.\(UUID().uuidString.prefix(6))", timeout: 1)
        do {
            _ = try await client.send(BridgeRequest(operation: .ping))
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not reachable"), error.localizedDescription)
        }
    }

    func testFakeServerLifecycleAndCrashRestart() async throws {
        // A tiny shell "language server": answers initialize, then exits on the first other request.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ck-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake-ls")
        try """
        #!/usr/bin/python3
        import sys, json
        def read():
            length = 0
            while True:
                line = sys.stdin.buffer.readline()
                if not line: sys.exit(0)
                line = line.decode().strip()
                if not line: break
                k, v = line.split(":", 1)
                if k.lower() == "content-length": length = int(v)
            return json.loads(sys.stdin.buffer.read(length))
        def send(obj):
            body = json.dumps(obj).encode()
            sys.stdout.buffer.write(b"Content-Length: %d\\r\\n\\r\\n" % len(body) + body); sys.stdout.buffer.flush()
        while True:
            msg = read()
            m = msg.get("method")
            if m == "initialize": send({"jsonrpc": "2.0", "id": msg["id"], "result": {"capabilities": {"hoverProvider": True}}})
            elif m == "textDocument/hover": send({"jsonrpc": "2.0", "id": msg["id"], "result": {"contents": "fake hover"}})
            elif m == "textDocument/definition": sys.exit(3)
            elif m == "shutdown": send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
            elif m == "exit": sys.exit(0)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let suite = "dev.pyrlyn.CrossKit.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeDefaults(suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setCustomServerPath(script.path, for: .rust)
        let manager = ServerManager(settings: settings)
        let handler = BridgeHandler(manager: manager, settings: settings, scratchDirectory: dir.appendingPathComponent("scratch"))
        let file = dir.appendingPathComponent("main.rs")
        try "fn main() {}\n".write(to: file, atomically: true, encoding: .utf8)

        let hover = await handler.handle(BridgeRequest(operation: .hover, text: "fn main() {}\n", filePath: file.path))
        XCTAssertTrue(hover.ok, hover.error ?? "")
        XCTAssertEqual(hover.hover, "fake hover")
        let firstPID = await manager.status(for: .rust).pid
        XCTAssertNotNil(firstPID)

        let crashed = await handler.handle(BridgeRequest(operation: .definition, text: "fn main() {}\n", filePath: file.path))
        XCTAssertFalse(crashed.ok)
        // Restarted automatically with backoff (1s).
        var restarted: ServerStatus?
        for _ in 0..<100 {
            let s = await manager.status(for: .rust)
            if s.state == .running, s.pid != firstPID { restarted = s; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(restarted?.restartCount, 1)
        let again = await handler.handle(BridgeRequest(operation: .hover, text: "fn main() {}\n", filePath: file.path))
        XCTAssertEqual(again.hover, "fake hover")

        settings.setFeature(.hover, enabled: false, for: .rust)
        let disabled = await handler.handle(BridgeRequest(operation: .hover, text: "", filePath: file.path))
        XCTAssertFalse(disabled.ok)
        XCTAssertTrue(disabled.error?.contains("turned off") == true)

        let groups = await manager.processGroups()
        await manager.shutdownAll()
        for group in groups { XCTAssertFalse(ProcessRegistry.groupIsAlive(group), "process group \(group) still alive") }
        let final = await manager.status(for: .rust)
        XCTAssertEqual(final.state, .stopped)
    }
}

/// Removes a throwaway defaults suite including its plist file.
func removeDefaults(_ suite: String) {
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    let file = SharedPaths.realHomeDirectory.appendingPathComponent("Library/Preferences/\(suite).plist")
    try? FileManager.default.removeItem(at: file)
}
