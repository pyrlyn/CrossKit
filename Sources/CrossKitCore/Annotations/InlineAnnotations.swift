import Foundation

/// User options for CodeLens, inlay hints and ErrorLens (settings › Inline Annotations).
public struct InlineAnnotationOptions: Codable, Equatable, Sendable {
    public enum Placement: String, Codable, CaseIterable, Sendable {
        /// A comment line above the code line, showing the line with its hints filled in.
        case above
        /// A trailing comment at the end of the code line.
        case endOfLine

        public var displayName: String {
            switch self {
            case .above: return "Above the line"
            case .endOfLine: return "End of line"
            }
        }
    }

    /// CodeLens: "N references" above declarations.
    public var lensReferences = true
    /// CodeLens: Run / Debug / Preview actions above `main`, tests and @Preview functions.
    public var lensActions = true
    public var hintTypes = true
    public var hintParameters = true
    /// Hints that are neither types nor parameter names (e.g. chaining or closing-brace hints).
    public var hintOther = false
    public var hintPlacement = Placement.above
    /// Lowest LSP severity shown by ErrorLens: 1 errors, 2 warnings, 3 information, 4 hints.
    public var errorLensMinimumSeverity = 2
    public var errorLensShowSource = true

    public init() {}
}

/// The kinds of inline annotation, each with its own glyph after `// [CrossKit]` so a command can
/// replace its own annotations without touching the others.
public enum InlineKind: String, Codable, CaseIterable, Sendable {
    case codeLens
    case inlayHints
    case errorLens

    public var feature: Feature {
        switch self {
        case .codeLens: return .codeLens
        case .inlayHints: return .inlayHints
        case .errorLens: return .errorLens
        }
    }

    public var glyphs: [String] {
        switch self {
        case .codeLens: return ["◆"]
        case .inlayHints: return ["»"]
        case .errorLens: return ["✖", "⚠", "ℹ", "∙"]
        }
    }

    public static func of(annotationText text: String) -> InlineKind? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return allCases.first { kind in kind.glyphs.contains { trimmed.hasPrefix($0) } }
    }
}

/// A CodeLens computed by the host: reference count and/or actions for one declaration line.
public struct BridgeCodeLens: Codable, Equatable, Sendable {
    /// 0-based line of the declaration.
    public var line: Int
    public var symbol: String
    public var references: Int?
    /// e.g. "▶ Run", "⚙ Debug", "▶ Run Test", "◉ Preview".
    public var actions: [String]

    public init(line: Int, symbol: String, references: Int? = nil, actions: [String] = []) {
        self.line = line
        self.symbol = symbol
        self.references = references
        self.actions = actions
    }
}

/// An LSP inlay hint flattened for the extension.
public struct BridgeInlayHint: Codable, Equatable, Sendable {
    public enum Kind: Int, Codable, Sendable { case type = 1, parameter = 2, other = 0 }
    public var line: Int
    /// UTF-16 column.
    public var character: Int
    public var label: String
    public var kind: Kind
    public var paddingLeft: Bool
    public var paddingRight: Bool

    public init(line: Int, character: Int, label: String, kind: Kind, paddingLeft: Bool = false, paddingRight: Bool = false) {
        self.line = line
        self.character = character
        self.label = label
        self.kind = kind
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
    }
}

/// Editing helpers for full-line (`// [CrossKit] …` lines) and trailing (`code  // [CrossKit] …`) annotations.
public enum InlineAnnotations {
    public static let marker = EditorCommandEngine.marker
    /// Trailing annotations start with two spaces, so `code // [CrossKit]` typed by hand is left alone.
    public static let trailingSeparator = "  " + marker + " "

    /// Kind of a full annotation line, if it is one of the inline kinds.
    public static func kind(ofLine line: String) -> InlineKind? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(marker) else { return nil }
        return InlineKind.of(annotationText: String(trimmed.dropFirst(marker.count)))
    }

    /// Splits `code  // [CrossKit] a  // [CrossKit] b\n` into ("code", ["a", "b"], "\n").
    public static func splitTrailing(_ line: String) -> (code: String, segments: [String], terminator: String) {
        let (content, terminator) = EditorCommandEngine.split(line)
        let trimmedStart = content.trimmingCharacters(in: .whitespaces)
        guard !trimmedStart.hasPrefix(marker), let first = content.range(of: trailingSeparator) else { return (content, [], terminator) }
        let code = String(content[..<first.lowerBound])
        let rest = String(content[first.upperBound...])
        return (code, rest.components(separatedBy: trailingSeparator), terminator)
    }

    /// Removes trailing segments of the given kinds (all CrossKit segments when `kinds` is nil).
    public static func stripTrailing(_ line: String, kinds: Set<InlineKind>? = nil) -> String {
        let (code, segments, terminator) = splitTrailing(line)
        guard !segments.isEmpty else { return line }
        let kept = segments.filter { segment in
            guard let kinds else { return false }
            guard let kind = InlineKind.of(annotationText: segment) else { return true }
            return !kinds.contains(kind)
        }
        return code + kept.map { trailingSeparator + $0 }.joined() + terminator
    }

    /// Appends one trailing segment before the line terminator.
    public static func appendTrailing(_ line: String, _ text: String) -> String {
        let (content, terminator) = EditorCommandEngine.split(line)
        return content + trailingSeparator + text + terminator
    }

    /// The buffer with all CrossKit annotations removed (full lines and trailing segments).
    public static func cleanText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !EditorCommandEngine.isAnnotation($0) }
            .map { stripTrailing($0) }
            .joined(separator: "\n")
    }

    // MARK: Safe places for trailing comments

    /// 0-based lines whose end is inside a string literal or block comment (or a Zig `\\` string line):
    /// appending `// …` there would change the program, so annotations go above those lines instead.
    public static func unsafeLineEnds(_ lines: [String], language: Language) -> Set<Int> {
        enum State: Equatable { case code, string, rawString(String), blockComment(Int) }
        var state = State.code
        var unsafe = Set<Int>()
        for (index, line) in lines.enumerated() {
            let chars = Array(EditorCommandEngine.split(line).0)
            if language == .zig, String(chars).trimmingCharacters(in: .whitespaces).hasPrefix("\\\\") {
                unsafe.insert(index)
                continue
            }
            var i = 0
            func at(_ k: Int) -> Character? { k < chars.count ? chars[k] : nil }
            func starts(_ s: String, _ k: Int) -> Bool {
                let a = Array(s)
                guard k + a.count <= chars.count else { return false }
                return Array(chars[k..<(k + a.count)]) == a
            }
            lineLoop: while i < chars.count {
                switch state {
                case .code:
                    let c = chars[i]
                    if c == "/" && at(i + 1) == "/" { break lineLoop }
                    if c == "/" && at(i + 1) == "*" && language != .zig { state = .blockComment(1); i += 2; continue }
                    if language == .kotlin && starts("\"\"\"", i) { state = .rawString("\"\"\""); i += 3; continue }
                    if language == .rust, c == "r" || c == "b", !(i > 0 && (chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_")) {
                        var k = i + (c == "b" && at(i + 1) == "r" ? 2 : (c == "r" ? 1 : 0))
                        if k > i {
                            var hashes = 0
                            while at(k) == "#" { hashes += 1; k += 1 }
                            if at(k) == "\"" { state = .rawString("\"" + String(repeating: "#", count: hashes)); i = k + 1; continue }
                        }
                    }
                    if c == "\"" { state = .string; i += 1; continue }
                    if c == "'" {
                        // Character literal ('a', '\n', '\u{1F600}'); Rust lifetimes ('a) have no closing quote.
                        if at(i + 1) == "\\" {
                            var k = i + 2
                            while k < chars.count && chars[k] != "'" { k += 1 }
                            i = k + 1; continue
                        }
                        if at(i + 2) == "'" { i += 3; continue }
                        i += 1; continue
                    }
                    i += 1
                case .string:
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "\"" { state = .code }
                    i += 1
                case .rawString(let end):
                    if starts(end, i) { state = .code; i += end.count; continue }
                    i += 1
                case .blockComment(let depth):
                    if starts("*/", i) { state = depth > 1 ? .blockComment(depth - 1) : .code; i += 2; continue }
                    if starts("/*", i) && language != .zig { state = .blockComment(depth + 1); i += 2; continue }
                    i += 1
                }
            }
            switch state {
            case .code: break
            case .string:
                // Rust strings may span lines; Kotlin and Zig strings end at the line (a syntax error otherwise).
                if language == .rust { unsafe.insert(index) } else { state = .code }
            case .rawString, .blockComment:
                unsafe.insert(index)
            }
        }
        return unsafe
    }

    // MARK: Edit planning

    /// The buffer with one kind's annotations removed, plus how clean lines map back to the original.
    public struct Prepared: Sendable {
        public var original: [String]
        public var clean: [String]
        /// clean index → original index
        public var keptOriginalIndex: [Int]
        /// Original indices of removed full annotation lines.
        public var removed: [Int]
        public var caretLine: Int
        public var caretColumn: Int

        public var cleanText: String { clean.joined() }
    }

    public static func prepare(_ buffer: EditorBuffer, removing kinds: Set<InlineKind>) -> Prepared {
        var clean: [String] = []
        var kept: [Int] = []
        var removed: [Int] = []
        for (index, line) in buffer.lines.enumerated() {
            if let kind = kind(ofLine: line), kinds.contains(kind) {
                removed.append(index)
                continue
            }
            clean.append(stripTrailing(line, kinds: kinds))
            kept.append(index)
        }
        let caret = buffer.selection.start
        let caretLine = kept.firstIndex { $0 >= caret.line } ?? max(0, kept.count - 1)
        return Prepared(original: buffer.lines, clean: clean, keptOriginalIndex: kept, removed: removed,
                        caretLine: caretLine, caretColumn: caret.column)
    }

    /// Operations that turn the original buffer into `clean` plus new annotations.
    /// `above` maps a clean line to full lines inserted before it; `trailing` to text appended at its end.
    public static func operations(_ prepared: Prepared, above: [Int: [String]], trailing: [Int: [String]]) -> [BufferOperation] {
        var operations: [BufferOperation] = []
        // 1. Lines that keep their place but change (old trailing annotations removed or new ones added).
        for (cleanIndex, originalIndex) in prepared.keptOriginalIndex.enumerated() {
            var line = prepared.clean[cleanIndex]
            for text in trailing[cleanIndex] ?? [] { line = appendTrailing(line, text) }
            if line != prepared.original[originalIndex] {
                operations.append(.replaceLines(start: originalIndex, count: 1, with: [line]))
            }
        }
        // 2. Old full annotation lines, bottom up.
        for index in prepared.removed.sorted(by: >) {
            operations.append(.replaceLines(start: index, count: 1, with: []))
        }
        // 3. New full lines, bottom up (indices are clean indices now).
        var insertedAboveCaret = 0
        for line in above.keys.sorted(by: >) {
            guard let lines = above[line], !lines.isEmpty else { continue }
            operations.append(.replaceLines(start: line, count: 0, with: lines))
            if line <= prepared.caretLine { insertedAboveCaret += lines.count }
        }
        operations.append(.select(.caret(prepared.caretLine + insertedAboveCaret, prepared.caretColumn)))
        return operations
    }

    // MARK: Rendering

    public static func lensText(_ lens: BridgeCodeLens) -> String? {
        var parts: [String] = []
        if let count = lens.references { parts.append(count == 1 ? "1 reference" : "\(count) references") }
        parts += lens.actions
        return parts.isEmpty ? nil : "◆ " + parts.joined(separator: " · ")
    }

    /// The line's code with each hint inserted as ‹label› (padding kept), e.g. `let x‹: i32› = add(‹a:› 1);`.
    public static func renderHints(_ code: String, hints: [BridgeInlayHint]) -> String {
        let ns = code as NSString
        var result = ""
        var cursor = 0
        for hint in hints.sorted(by: { $0.character < $1.character }) {
            let at = min(max(hint.character, cursor), ns.length)
            result += ns.substring(with: NSRange(location: cursor, length: at - cursor))
            result += (hint.paddingLeft ? " " : "") + "‹" + hint.label + "›" + (hint.paddingRight ? " " : "")
            cursor = at
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// End-of-line form: `x: i32, a: 1` — type hints with the name before them, parameter hints with the argument after.
    public static func summarizeHints(_ code: String, hints: [BridgeInlayHint]) -> String {
        let ns = code as NSString
        let identifier = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func word(endingAt end: Int) -> String {
            var start = min(end, ns.length)
            while start > 0, let scalar = UnicodeScalar(ns.character(at: start - 1)), identifier.contains(scalar) { start -= 1 }
            return ns.substring(with: NSRange(location: start, length: min(end, ns.length) - start))
        }
        func argument(startingAt begin: Int) -> String {
            var i = min(begin, ns.length)
            while i < ns.length, ns.character(at: i) == 32 { i += 1 }
            let start = i
            var depth = 0
            while i < ns.length {
                let c = ns.character(at: i)
                if c == 40 || c == 91 || c == 123 { depth += 1 }       // ( [ {
                if c == 41 || c == 93 || c == 125 {                     // ) ] }
                    if depth == 0 { break }
                    depth -= 1
                }
                if c == 44 && depth == 0 { break }                      // ,
                i += 1
            }
            let text = ns.substring(with: NSRange(location: start, length: i - start)).trimmingCharacters(in: .whitespaces)
            return text.count > 24 ? String(text.prefix(23)) + "…" : text
        }
        return hints.sorted { $0.character < $1.character }.map { hint in
            let label = hint.label.trimmingCharacters(in: .whitespaces)
            switch hint.kind {
            case .type:
                let name = word(endingAt: hint.character)
                return name.isEmpty ? label : name + (label.hasPrefix(":") ? label : ": " + label)
            case .parameter:
                let arg = argument(startingAt: hint.character)
                return arg.isEmpty ? label : "\(label.hasSuffix(":") ? label : label + ":") \(arg)"
            case .other:
                return label
            }
        }.joined(separator: ", ")
    }

    public static func severityGlyph(_ severity: Int) -> String {
        switch severity {
        case 1: return "✖"
        case 2: return "⚠"
        case 3: return "ℹ"
        default: return "∙"
        }
    }

    /// ErrorLens text for one line: the most severe diagnostic, plus how many others share the line.
    public static func errorLensText(_ diagnostics: [BridgeDiagnostic], showSource: Bool) -> String? {
        let sorted = diagnostics.sorted { ($0.severity, $0.range.startCharacter) < ($1.severity, $1.range.startCharacter) }
        guard let first = sorted.first else { return nil }
        var message = first.message.components(separatedBy: "\n").first ?? first.message
        message = message.trimmingCharacters(in: .whitespaces)
        if message.count > 160 { message = String(message.prefix(159)) + "…" }
        var text = "\(severityGlyph(first.severity)) \(first.severityName): \(message)"
        if showSource, let source = first.source, !source.isEmpty { text += " (\(source))" }
        if sorted.count > 1 { text += " (+\(sorted.count - 1) more)" }
        return text
    }
}
