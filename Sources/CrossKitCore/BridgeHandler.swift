import Foundation

/// Host-side request handling: resolves the document and language, enforces settings,
/// talks to the language server and returns bridge models.
public final class BridgeHandler: @unchecked Sendable {
    public typealias DocumentResolver = @Sendable (BridgeRequest, Language?) -> URL?
    public typealias LocationOpener = @Sendable (BridgeLocation) -> Void

    private let manager: ServerManager
    private let settings: SettingsStore
    private let scratchDirectory: URL
    public var documentResolver: DocumentResolver?
    public var openLocation: LocationOpener?
    public var testService: TestService
    public var debugService: DebugService
    /// Called with every finished test run (the host shows them in its Test Results window).
    public var onTestRun: (@Sendable (TestRunResult) -> Void)?

    public init(manager: ServerManager, settings: SettingsStore, scratchDirectory: URL = SharedPaths.scratchDirectory) {
        self.manager = manager
        self.settings = settings
        self.scratchDirectory = scratchDirectory
        let resolver = TestRunnerResolver(settings: settings)
        self.testService = TestService(resolver: resolver)
        self.debugService = DebugService(planner: LaunchPlanner(settings: settings, resolver: resolver))
    }

    public func handle(_ request: BridgeRequest) async -> BridgeResponse {
        do {
            return try await process(request)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func process(_ request: BridgeRequest) async throws -> BridgeResponse {
        if request.operation == .ping { return BridgeResponse() }

        var file = request.filePath.map { URL(fileURLWithPath: $0) }
        var language = file.flatMap { settings.language(forPath: $0.path) }
        if file == nil {
            let hint = Language.guess(fromUTI: request.contentUTI)
            file = documentResolver?(request, hint)
            language = file.flatMap { settings.language(forPath: $0.path) } ?? hint
        }
        guard let language else { throw BridgeError.unknownLanguage(request.contentUTI) }
        guard settings.isEnabled(language) else { throw BridgeError.languageDisabled(language) }
        if let feature = request.operation.feature, !settings.isFeatureEnabled(feature, for: language) {
            throw BridgeError.featureDisabled(feature, language)
        }
        if request.operation == .discoverTests || request.operation == .runTests {
            guard let file else { throw TestRunnerError.needsSavedFile }
            return try await processTests(request, language: language, file: file.resolvingSymlinksInPath())
        }
        if request.operation == .debugFile || request.operation == .debugTest {
            guard let file else { throw DebugError.needsSavedFile }
            var response = BridgeResponse()
            response.language = language
            response.filePath = file.resolvingSymlinksInPath().path
            response.debugLaunch = try await debugService.start(
                language: language, file: file.resolvingSymlinksInPath(), text: request.text, cursorLine: request.line,
                target: request.operation == .debugTest ? .test : .file)
            return response
        }
        let documentURL = try (file ?? WorkspaceResolver.scratchFile(for: language, text: request.text, in: scratchDirectory))
            .resolvingSymlinksInPath()
        let root = WorkspaceResolver.root(for: documentURL, language: language).resolvingSymlinksInPath()
        let client = try await manager.client(for: language, root: root)
        let uri = LSPClient.normalizeURI(documentURL.absoluteString)
        let before = client.diagnosticsState(uri: uri).sequence
        try client.syncDocument(uri: uri, text: request.text)

        var response = BridgeResponse()
        response.language = language
        response.filePath = documentURL.path
        response.rootPath = root.path
        let textDocument: JSONValue = ["uri": .string(uri)]
        let position: JSONValue = ["line": .int(request.line), "character": .int(request.character)]
        let timeout = language.requestTimeout

        switch request.operation {
        case .ping, .discoverTests, .runTests, .debugFile, .debugTest:
            break
        case .completion:
            let result = try await warmRequest(client, "textDocument/completion", [
                "textDocument": textDocument, "position": position, "context": ["triggerKind": 1],
            ], timeout: timeout)
            response.completions = Array(LSPConvert.completions(result).prefix(500))
        case .definition:
            let result = try await warmRequest(client, "textDocument/definition", [
                "textDocument": textDocument, "position": position,
            ], timeout: timeout)
            let locations = withPreviews(LSPConvert.locations(result), currentPath: documentURL.path, currentText: request.text)
            response.locations = locations
            if let first = locations.first, first.path != documentURL.path { openLocation?(first) }
        case .references:
            let result = try await warmRequest(client, "textDocument/references", [
                "textDocument": textDocument, "position": position, "context": ["includeDeclaration": true],
            ], timeout: timeout)
            response.locations = withPreviews(LSPConvert.locations(result), currentPath: documentURL.path, currentText: request.text)
        case .hover:
            let result = try await warmRequest(client, "textDocument/hover", [
                "textDocument": textDocument, "position": position,
            ], timeout: timeout)
            response.hover = LSPConvert.hoverText(result)
        case .diagnostics:
            if client.capabilities["diagnosticProvider"] != nil,
               let result = try? await client.request("textDocument/diagnostic", ["textDocument": textDocument], timeout: timeout),
               let items = result["items"]?.arrayValue {
                response.diagnostics = LSPConvert.diagnostics(items)
                response.diagnosticsReceived = true
            } else if let items = await client.waitForDiagnostics(uri: uri, afterSequence: before, timeout: language.diagnosticsTimeout) {
                response.diagnostics = LSPConvert.diagnostics(items)
                response.diagnosticsReceived = true
            } else {
                response.diagnostics = LSPConvert.diagnostics(client.diagnosticsState(uri: uri).items)
                response.diagnosticsReceived = false
            }
        }
        await manager.touch(language, root: root)
        return response
    }

    // MARK: Tests

    private func processTests(_ request: BridgeRequest, language: Language, file: URL) async throws -> BridgeResponse {
        var tests = testService.discover(language, file: file, text: request.text)
        if language == .rust, let runnables = await rustRunnables(file: file, text: request.text, expectTests: !tests.isEmpty),
           !runnables.isEmpty {
            tests = runnables
        }
        var response = BridgeResponse()
        response.language = language
        response.filePath = file.path
        response.rootPath = testService.resolver.projectRoot(for: file, language: language).path
        response.tests = tests
        if request.operation == .runTests {
            let run = try await testService.run(language, file: file, text: request.text, scope: request.testScope ?? .file,
                                                cursorLine: request.line, tests: tests)
            onTestRun?(run)
            response.testRun = run
        }
        return response
    }

    /// rust-analyzer's `experimental/runnables`: exact test paths plus the cargo arguments it would use.
    private func rustRunnables(file: URL, text: String, expectTests: Bool) async -> [DiscoveredTest]? {
        guard settings.isEnabled(.rust), await manager.resolveBinary(for: .rust) != nil else { return nil }
        let root = WorkspaceResolver.root(for: file, language: .rust).resolvingSymlinksInPath()
        guard let client = try? await manager.client(for: .rust, root: root) else { return nil }
        let uri = LSPClient.normalizeURI(file.absoluteString)
        guard (try? client.syncDocument(uri: uri, text: text)) != nil else { return nil }
        var tests: [DiscoveredTest] = []
        for _ in 0..<30 {
            guard let result = try? await client.request("experimental/runnables", ["textDocument": ["uri": .string(uri)]],
                                                         timeout: 30) else { return nil }
            tests = Self.parseRunnables(result)
            if !tests.isEmpty || !expectTests || Date().timeIntervalSince(client.startedAt) > 60 { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return tests
    }

    static func parseRunnables(_ result: JSONValue) -> [DiscoveredTest] {
        (result.arrayValue ?? []).compactMap { runnable in
            guard let label = runnable["label"]?.stringValue, label.hasPrefix("test ") else { return nil }
            let path = String(label.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            let location = runnable["location"]
            let line = (LSPConvert.range(location?["targetSelectionRange"]) ?? LSPConvert.range(location?["targetRange"]))?.startLine ?? 0
            let args = runnable["args"]
            let cargo = (args?["cargoArgs"]?.arrayValue ?? []).compactMap(\.stringValue)
                + (args?["cargoExtraArgs"]?.arrayValue ?? []).compactMap(\.stringValue)
            let exe = (args?["executableArgs"]?.arrayValue ?? []).compactMap(\.stringValue)
            return DiscoveredTest(name: path.components(separatedBy: "::").last ?? path, filter: path, line: line,
                                  cargoArgs: cargo.isEmpty ? nil : cargo, executableArgs: exe.isEmpty ? nil : exe)
        }
    }

    /// Right after start, servers often answer `null`/`[]` while still indexing; retry briefly.
    private func warmRequest(_ client: LSPClient, _ method: String, _ params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        var result = try await client.request(method, params, timeout: timeout)
        var attempts = 0
        while Self.isEmpty(result), Date().timeIntervalSince(client.startedAt) < 60, attempts < 15 {
            attempts += 1
            try await Task.sleep(nanoseconds: 1_000_000_000)
            result = try await client.request(method, params, timeout: timeout)
        }
        return result
    }

    static func isEmpty(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return true
        case .array(let items): return items.isEmpty
        case .object(let object):
            if let items = object["items"]?.arrayValue { return items.isEmpty }
            return false
        default: return false
        }
    }

    private func withPreviews(_ locations: [BridgeLocation], currentPath: String, currentText: String) -> [BridgeLocation] {
        var cache: [String: [Substring]] = [currentPath: currentText.split(separator: "\n", omittingEmptySubsequences: false)]
        return locations.map { location in
            var location = location
            if cache[location.path] == nil {
                let text = (try? String(contentsOfFile: location.path, encoding: .utf8)) ?? ""
                cache[location.path] = text.split(separator: "\n", omittingEmptySubsequences: false)
            }
            if let lines = cache[location.path], lines.indices.contains(location.range.startLine) {
                location.preview = lines[location.range.startLine].trimmingCharacters(in: .whitespaces)
            }
            return location
        }
    }
}
