import Foundation

public protocol BridgeTransport: Sendable {
    func send(_ request: BridgeRequest) async throws -> BridgeResponse
}

extension BridgeClient: BridgeTransport {}

public struct EditorPosition: Codable, Equatable, Sendable {
    public var line: Int
    public var column: Int
    public init(line: Int, column: Int) { self.line = line; self.column = column }
}

public struct EditorRange: Codable, Equatable, Sendable {
    public var start: EditorPosition
    public var end: EditorPosition
    public init(start: EditorPosition, end: EditorPosition) { self.start = start; self.end = end }
    public static func caret(_ line: Int, _ column: Int) -> EditorRange {
        EditorRange(start: EditorPosition(line: line, column: column), end: EditorPosition(line: line, column: column))
    }
}

/// Buffer mutations, applied in order. Lines include their trailing "\n" like XcodeKit's `lines`.
public enum BufferOperation: Equatable, Sendable {
    case replaceLines(start: Int, count: Int, with: [String])
    case select(EditorRange)
}

public struct EditorBuffer: Sendable {
    public var lines: [String]
    public var selection: EditorRange
    public var contentUTI: String
    public var filePath: String?

    public init(lines: [String], selection: EditorRange, contentUTI: String, filePath: String? = nil) {
        self.lines = lines
        self.selection = selection
        self.contentUTI = contentUTI
        self.filePath = filePath
    }

    public var text: String { lines.joined() }
}

public struct EditorOutcome: Sendable {
    public var operations: [BufferOperation]
    /// Shown to the user (XcodeKit can only surface it as an alert).
    public var message: String?

    public init(operations: [BufferOperation] = [], message: String? = nil) {
        self.operations = operations
        self.message = message
    }
}

public enum EditorCommand: String, CaseIterable, Codable, Sendable {
    case complete
    case listCompletions
    case goToDefinition
    case findReferences
    case hover
    case diagnostics
    case clearAnnotations
    case showTests
    case runTestsInFile
    case runTestAtCursor
    case debugFileAtCursor
    case debugTestAtCursor
    case openSettings

    public var displayName: String {
        switch self {
        case .complete: return "Complete at Cursor"
        case .listCompletions: return "List Completions"
        case .goToDefinition: return "Go to Definition"
        case .findReferences: return "Find References"
        case .hover: return "Show Hover Info"
        case .diagnostics: return "Show Diagnostics"
        case .clearAnnotations: return "Clear CrossKit Annotations"
        case .showTests: return "Show Test Markers"
        case .runTestsInFile: return "Run Tests in File"
        case .runTestAtCursor: return "Run Test at Cursor"
        case .debugFileAtCursor: return "Debug File at Cursor"
        case .debugTestAtCursor: return "Debug Test at Cursor"
        case .openSettings: return "Open CrossKit Settings"
        }
    }
}

public enum EditorCommandError: Error, LocalizedError {
    case bridge(String)
    case nothing(String)

    public var errorDescription: String? {
        switch self {
        case .bridge(let message): return message
        case .nothing(let message): return message
        }
    }
}

/// Maps LSP features onto what XcodeKit can do: edit lines and set the selection.
/// Information that has no native UI is inserted as removable `// [CrossKit]` comment lines.
public struct EditorCommandEngine: Sendable {
    public static let marker = "// [CrossKit]"
    public var maxAnnotationLines = 40

    public init() {}

    public func run(_ command: EditorCommand, buffer: EditorBuffer, transport: BridgeTransport) async throws -> EditorOutcome {
        switch command {
        case .clearAnnotations: return clearAnnotations(buffer)
        case .openSettings: return EditorOutcome()
        case .complete: return completeAtCursor(buffer, try await call(.completion, buffer, transport))
        case .listCompletions: return listCompletions(buffer, try await call(.completion, buffer, transport))
        case .goToDefinition: return goToDefinition(buffer, try await call(.definition, buffer, transport))
        case .findReferences: return findReferences(buffer, try await call(.references, buffer, transport))
        case .hover: return hover(buffer, try await call(.hover, buffer, transport))
        case .diagnostics: return diagnostics(buffer, try await call(.diagnostics, buffer, transport))
        case .showTests: return try await tests(buffer, operation: .discoverTests, scope: nil, transport: transport)
        case .runTestsInFile: return try await tests(buffer, operation: .runTests, scope: .file, transport: transport)
        case .runTestAtCursor: return try await tests(buffer, operation: .runTests, scope: .cursor, transport: transport)
        case .debugFileAtCursor: return try await debug(buffer, operation: .debugFile, transport: transport)
        case .debugTestAtCursor: return try await debug(buffer, operation: .debugTest, transport: transport)
        }
    }

    /// Whether a command may run for minutes (the extension uses a longer bridge timeout).
    public static func isLongRunning(_ command: EditorCommand) -> Bool {
        [.runTestsInFile, .runTestAtCursor, .debugFileAtCursor, .debugTestAtCursor].contains(command)
    }

    // MARK: Debugging

    /// Starts a session with a breakpoint on the caret line. The buffer is not modified.
    func debug(_ buffer: EditorBuffer, operation: BridgeOperation, transport: BridgeTransport) async throws -> EditorOutcome {
        let caret = buffer.selection.start
        let request = BridgeRequest(operation: operation, text: buffer.text, line: caret.line, character: caret.column,
                                    contentUTI: buffer.contentUTI, filePath: buffer.filePath)
        let response = try await transport.send(request)
        guard response.ok else { throw EditorCommandError.bridge(response.error ?? "CrossKit request failed") }
        guard let info = response.debugLaunch else { throw EditorCommandError.nothing("The debugger did not start.") }
        var message = "▶ " + info.message
        if let warning = info.warning { message += "\n\n⚠︎ " + warning }
        return EditorOutcome(message: message)
    }

    // MARK: Tests (CodeLens substitute: `// [CrossKit] ▶ …` markers above test functions)

    static let testMarkerSymbols = ["▶", "✓", "✗", "○"]

    public static func isTestMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(marker) else { return false }
        let rest = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return testMarkerSymbols.contains { rest.hasPrefix($0) }
    }

    func tests(_ buffer: EditorBuffer, operation: BridgeOperation, scope: TestScope?, transport: BridgeTransport) async throws -> EditorOutcome {
        // Old test markers are removed first; the request uses the buffer without them.
        let markerLines = buffer.lines.indices.filter { Self.isTestMarker(buffer.lines[$0]) }
        let markerSet = Set(markerLines)
        let clean = buffer.lines.enumerated().filter { !markerSet.contains($0.offset) }.map(\.element)
        let caret = buffer.selection.start
        let caretLine = max(0, caret.line - markerLines.filter { $0 < caret.line }.count)
        let request = BridgeRequest(operation: operation, text: clean.joined(), line: caretLine, character: caret.column,
                                    contentUTI: buffer.contentUTI, filePath: buffer.filePath, testScope: scope)
        let response = try await transport.send(request)
        guard response.ok else { throw EditorCommandError.bridge(response.error ?? "CrossKit request failed") }

        var operations: [BufferOperation] = markerLines.reversed().map { .replaceLines(start: $0, count: 1, with: []) }
        var markers: [Int: String] = [:]   // clean line → marker text
        let tests = response.tests ?? []
        var message: String?
        if let run = response.testRun {
            for result in run.tests {
                guard let line = result.line, clean.indices.contains(line) else { continue }
                markers[line] = Self.describe(result)
            }
            message = Self.summary(run)
        } else {
            if tests.isEmpty { message = "No tests found in this file." }
            for test in tests where clean.indices.contains(test.line) {
                markers[test.line] = "▶ test \(test.name.isEmpty ? test.filter : test.name) — Editor › CrossKit › Run Test at Cursor"
            }
        }
        var inserted = 0
        for line in markers.keys.sorted(by: >) {
            let anchor = Self.attributeStart(clean, line)
            let indent = Self.indentation(of: clean[line])
            operations.append(.replaceLines(start: anchor, count: 0, with: ["\(indent)\(Self.marker) \(markers[line]!)\n"]))
            if anchor <= caretLine { inserted += 1 }
        }
        operations.append(.select(.caret(caretLine + inserted, caret.column)))
        return EditorOutcome(operations: operations, message: message)
    }

    /// Markers go above attributes/annotations such as `#[test]` or `@Test`.
    static func attributeStart(_ lines: [String], _ line: Int) -> Int {
        var start = line
        while start > 0 {
            let previous = lines[start - 1].trimmingCharacters(in: .whitespaces)
            guard previous.hasPrefix("#[") || previous.hasPrefix("@") else { break }
            start -= 1
        }
        return start
    }

    static func describe(_ result: TestCaseResult) -> String {
        let time = result.duration.map { String(format: " %.3fs", $0) } ?? ""
        switch result.status {
        case .passed: return "✓ passed\(time)"
        case .skipped: return "○ skipped"
        case .failed:
            let first = result.output?.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }.map { " — " + String($0.prefix(140)) } ?? ""
            return "✗ failed\(time)\(first)"
        }
    }

    public static func summary(_ run: TestRunResult) -> String {
        var lines = ["\(run.succeeded ? "✓" : "✗") \(run.language.displayName) · \(run.runner.displayName): \(run.summary)"]
        let failures = run.tests.filter { $0.status == .failed }
        for failure in failures.prefix(8) {
            let location = failure.line.map { ":\($0 + 1)" } ?? ""
            lines.append("✗ \(failure.name)\(location)")
        }
        if failures.count > 8 { lines.append("… and \(failures.count - 8) more") }
        if run.tests.isEmpty, !run.succeeded {
            let tail = run.output.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(6)
            lines.append(contentsOf: tail)
        }
        if let warning = run.warning { lines.append("⚠︎ " + warning) }
        lines.append("Details: CrossKit › Test Results")
        return lines.joined(separator: "\n")
    }

    private func call(_ operation: BridgeOperation, _ buffer: EditorBuffer, _ transport: BridgeTransport) async throws -> BridgeResponse {
        let caret = buffer.selection.start
        let request = BridgeRequest(operation: operation, text: buffer.text, line: caret.line, character: caret.column,
                                    contentUTI: buffer.contentUTI, filePath: buffer.filePath)
        let response = try await transport.send(request)
        guard response.ok else { throw EditorCommandError.bridge(response.error ?? "CrossKit request failed") }
        return response
    }

    // MARK: Commands

    func completeAtCursor(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        let caret = buffer.selection.start
        guard buffer.lines.indices.contains(caret.line) else { return EditorOutcome(message: "Cursor is outside the buffer.") }
        let (content, terminator) = Self.split(buffer.lines[caret.line])
        let ns = content as NSString
        let column = min(caret.column, ns.length)
        let prefix = Self.identifierPrefix(in: ns, before: column)
        guard let best = Self.bestCompletion(response.completions ?? [], prefix: prefix) else {
            return EditorOutcome(message: "No completions for \"\(prefix)\".")
        }
        var start = column - (prefix as NSString).length
        var end = column
        if let range = best.editRange, range.startLine == caret.line, range.endLine == caret.line {
            start = min(range.startCharacter, ns.length)
            end = max(start, min(max(range.endCharacter, column), ns.length))
        }
        let updated = ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: best.insertText)
        let newLines = (updated + terminator).components(separatedBy: "\n")
        var lines = newLines.dropLast().map { $0 + "\n" }
        if let last = newLines.last, !last.isEmpty || terminator.isEmpty { lines.append(last) }
        let caretColumn = start + (best.insertText as NSString).length
        var operations: [BufferOperation] = [.replaceLines(start: caret.line, count: 1, with: lines)]
        if !best.insertText.contains("\n") { operations.append(.select(.caret(caret.line, caretColumn))) }
        return EditorOutcome(operations: operations)
    }

    func listCompletions(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        let caret = buffer.selection.start
        let content = buffer.lines.indices.contains(caret.line) ? Self.split(buffer.lines[caret.line]).0 : ""
        let ns = content as NSString
        let prefix = Self.identifierPrefix(in: ns, before: min(caret.column, ns.length))
        let ranked = Self.rankedCompletions(response.completions ?? [], prefix: prefix)
        guard !ranked.isEmpty else { return EditorOutcome(message: "No completions for \"\(prefix)\".") }
        var body = ["completions for \"\(prefix)\" (\(ranked.count)):"]
        body += ranked.prefix(maxAnnotationLines - 1).map { item in
            "  \(item.label)" + (item.detail.map { " — \($0)" } ?? "")
        }
        return annotate(buffer, aboveLine: caret.line, body)
    }

    func goToDefinition(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        let locations = response.locations ?? []
        guard let first = locations.first else { return EditorOutcome(message: "No definition found.") }
        if let current = response.filePath, first.path == current {
            let r = first.range
            return EditorOutcome(operations: [.select(EditorRange(start: EditorPosition(line: r.startLine, column: r.startCharacter),
                                                                end: EditorPosition(line: r.endLine, column: r.endCharacter)))])
        }
        let body = ["definition:"] + locations.prefix(maxAnnotationLines - 1).map { "  " + describe($0, root: response.rootPath) }
        var outcome = annotate(buffer, aboveLine: buffer.selection.start.line, body)
        outcome.message = "Definition is in \((first.path as NSString).lastPathComponent):\(first.range.startLine + 1) — CrossKit asked Xcode to open it."
        return outcome
    }

    func findReferences(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        let locations = response.locations ?? []
        guard !locations.isEmpty else { return EditorOutcome(message: "No references found.") }
        let body = ["\(locations.count) reference(s):"] + locations.prefix(maxAnnotationLines - 1).map {
            "  " + describe($0, root: response.rootPath)
        }
        return annotate(buffer, aboveLine: buffer.selection.start.line, body)
    }

    func hover(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        guard let text = response.hover else { return EditorOutcome(message: "No hover information here.") }
        let lines = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .map { String($0.prefix(200)) }
        let trimmed = Array(lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard !trimmed.isEmpty else { return EditorOutcome(message: "No hover information here.") }
        return annotate(buffer, aboveLine: buffer.selection.start.line, Array(trimmed.prefix(maxAnnotationLines)))
    }

    func diagnostics(_ buffer: EditorBuffer, _ response: BridgeResponse) -> EditorOutcome {
        let items = (response.diagnostics ?? []).filter { buffer.lines.indices.contains($0.range.startLine) }
        guard !items.isEmpty else {
            let received = response.diagnosticsReceived ?? true
            return EditorOutcome(message: received ? "No problems found." : "The language server has not reported diagnostics yet; try again in a moment.")
        }
        let grouped = Dictionary(grouping: items, by: { $0.range.startLine })
        var operations: [BufferOperation] = []
        var inserted = 0
        for line in grouped.keys.sorted(by: >) {
            let indent = Self.indentation(of: buffer.lines[line])
            let annotations = grouped[line]!.map { d -> String in
                let message = d.message.replacingOccurrences(of: "\n", with: " ")
                return "\(indent)\(Self.marker) \(d.severityName): \(message) [\(line + 1):\(d.range.startCharacter + 1)]"
                    + (d.source.map { " (\($0))" } ?? "") + "\n"
            }
            operations.append(.replaceLines(start: line, count: 0, with: annotations))
            if line <= buffer.selection.start.line { inserted += annotations.count }
        }
        let caret = buffer.selection.start
        operations.append(.select(.caret(caret.line + inserted, caret.column)))
        return EditorOutcome(operations: operations)
    }

    func clearAnnotations(_ buffer: EditorBuffer) -> EditorOutcome {
        let indices = buffer.lines.indices.filter { Self.isAnnotation(buffer.lines[$0]) }
        guard !indices.isEmpty else { return EditorOutcome(message: "No CrossKit annotations to remove.") }
        var operations: [BufferOperation] = indices.reversed().map { .replaceLines(start: $0, count: 1, with: []) }
        let caret = buffer.selection.start
        let removedAbove = indices.filter { $0 < caret.line }.count
        operations.append(.select(.caret(max(0, caret.line - removedAbove), caret.column)))
        return EditorOutcome(operations: operations)
    }

    // MARK: Helpers

    func annotate(_ buffer: EditorBuffer, aboveLine line: Int, _ body: [String]) -> EditorOutcome {
        let target = min(max(line, 0), buffer.lines.count)
        let indent = buffer.lines.indices.contains(target) ? Self.indentation(of: buffer.lines[target]) : ""
        let lines = body.map { "\(indent)\(Self.marker) \($0)\n" }
        let caret = buffer.selection.start
        return EditorOutcome(operations: [
            .replaceLines(start: target, count: 0, with: lines),
            .select(.caret(caret.line + (target <= caret.line ? lines.count : 0), caret.column)),
        ])
    }

    func describe(_ location: BridgeLocation, root: String?) -> String {
        var path = location.path
        if let root, path.hasPrefix(root + "/") { path = String(path.dropFirst(root.count + 1)) }
        let position = "\(path):\(location.range.startLine + 1):\(location.range.startCharacter + 1)"
        guard let preview = location.preview, !preview.isEmpty else { return position }
        return "\(position)  \(preview.prefix(120))"
    }

    public static func isAnnotation(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
    }

    static func split(_ line: String) -> (String, String) {
        if line.hasSuffix("\r\n") { return (String(line.dropLast(2)), "\r\n") }
        if line.hasSuffix("\n") { return (String(line.dropLast()), "\n") }
        return (line, "")
    }

    static func indentation(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    static func identifierPrefix(in line: NSString, before column: Int) -> String {
        var start = column
        while start > 0 {
            let c = line.character(at: start - 1)
            guard let scalar = UnicodeScalar(c),
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "@" else { break }
            start -= 1
        }
        return line.substring(with: NSRange(location: start, length: column - start))
    }

    public static func rankedCompletions(_ items: [BridgeCompletion], prefix: String) -> [BridgeCompletion] {
        let key = { (item: BridgeCompletion) in item.filterText ?? item.label }
        let order = { (a: BridgeCompletion, b: BridgeCompletion) in (a.sortText ?? a.label) < (b.sortText ?? b.label) }
        if prefix.isEmpty { return items.sorted(by: order) }
        let exact = items.filter { key($0).hasPrefix(prefix) }.sorted(by: order)
        if !exact.isEmpty { return exact }
        let lower = prefix.lowercased()
        let insensitive = items.filter { key($0).lowercased().hasPrefix(lower) }.sorted(by: order)
        if !insensitive.isEmpty { return insensitive }
        return items.filter { key($0).lowercased().contains(lower) }.sorted(by: order)
    }

    public static func bestCompletion(_ items: [BridgeCompletion], prefix: String) -> BridgeCompletion? {
        rankedCompletions(items, prefix: prefix).first
    }

    /// Applies operations to plain lines (mirrors what the extension does to XCSourceTextBuffer).
    public static func apply(_ operations: [BufferOperation], to lines: [String]) -> (lines: [String], selection: EditorRange?) {
        var lines = lines
        var selection: EditorRange?
        for operation in operations {
            switch operation {
            case .replaceLines(let start, let count, let newLines):
                let s = min(max(start, 0), lines.count)
                let e = min(s + count, lines.count)
                lines.replaceSubrange(s..<e, with: newLines)
            case .select(let range):
                selection = range
            }
        }
        return (lines, selection)
    }
}
