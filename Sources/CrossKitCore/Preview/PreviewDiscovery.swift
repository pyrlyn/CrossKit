import Foundation

/// A `@Preview` composable found in a Kotlin file.
public struct ComposePreview: Codable, Equatable, Identifiable, Sendable {
    /// `<class>.<function>#<index>`: one function can carry several @Preview annotations.
    public var id: String { "\(className).\(function)#\(index)" }
    /// `name = "…"` of the annotation, else the function name.
    public var name: String
    public var function: String
    /// JVM class holding the function: the file facade (`demo.MainKt`) or an enclosing object/class.
    public var className: String
    /// 0-based line of the `fun` declaration.
    public var line: Int
    /// 0-based line of the first annotation (where a CodeLens goes).
    public var annotationLine: Int
    /// Position among the function's @Preview annotations.
    public var index: Int
    public var widthDp: Int?
    public var heightDp: Int?
    public var showBackground: Bool
    /// ARGB, e.g. 0xFFFFFFFF.
    public var backgroundColor: UInt32?

    public init(name: String, function: String, className: String, line: Int, annotationLine: Int, index: Int = 0,
                widthDp: Int? = nil, heightDp: Int? = nil, showBackground: Bool = false, backgroundColor: UInt32? = nil) {
        self.name = name
        self.function = function
        self.className = className
        self.line = line
        self.annotationLine = annotationLine
        self.index = index
        self.widthDp = widthDp
        self.heightDp = heightDp
        self.showBackground = showBackground
        self.backgroundColor = backgroundColor
    }
}

/// Finds Compose `@Preview` functions (androidx.compose.ui.tooling.preview.Preview, the desktop
/// androidx.compose.desktop.ui.tooling.preview.Preview, or any annotation named Preview).
public enum PreviewDiscovery {
    private static let annotationStart = try! NSRegularExpression(pattern: #"@(?:[\w.]+\.)?Preview\b(?!Parameter)"#)
    private static let funDecl = try! NSRegularExpression(pattern: #"\bfun\s+(?:<[^>]*>\s*)?([A-Za-z_]\w*)\s*\("#)

    public static func discover(text: String, fileName: String) -> [ComposePreview] {
        let lines = text.components(separatedBy: "\n")
        var result: [ComposePreview] = []
        var pending: [(text: String, line: Int)] = []
        var index = 0
        while index < lines.count {
            let code = strip(lines[index])
            let range = NSRange(code.startIndex..., in: code)
            if let match = annotationStart.firstMatch(in: code, range: range), let start = Range(match.range, in: code) {
                // Collect the annotation's argument list, which may span lines.
                var annotation = String(code[start.lowerBound...])
                var end = index
                while balance(annotation) > 0, end + 1 < lines.count {
                    end += 1
                    annotation += " " + strip(lines[end])
                }
                // Several annotations may share a line (`@Preview(name = "A") @Preview(name = "B")`).
                var after = Substring(annotation)
                while true {
                    let current = String(after)
                    let length = argumentsEnd(current)
                    pending.append((String(current.prefix(length)), index))
                    after = current.dropFirst(length)
                    let rest = String(after)
                    guard let next = annotationStart.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                          let nextStart = Range(next.range, in: rest) else { break }
                    after = Substring(rest[nextStart.lowerBound...])
                }
                index = end
                // The declaration may share the annotation's line (`@Preview @Composable fun A() {`).
                if let fun = functionName(String(after)) {
                    result += make(pending, function: fun, line: index, text: text, fileName: fileName)
                    pending = []
                }
                index += 1
                continue
            }
            if !pending.isEmpty {
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                if let fun = functionName(code) {
                    result += make(pending, function: fun, line: index, text: text, fileName: fileName)
                    pending = []
                } else if trimmed.contains("annotation class") || trimmed.hasPrefix("class ") || trimmed.hasPrefix("val ")
                            || trimmed.hasPrefix("var ") || trimmed.hasPrefix("object ") {
                    // A multipreview annotation or a property: not a renderable function.
                    pending = []
                }
            }
            index += 1
        }
        return result
    }

    /// The preview whose declaration is at or above the line (closest first).
    public static func preview(at line: Int, in previews: [ComposePreview]) -> ComposePreview? {
        previews.filter { $0.annotationLine <= line }.max { ($0.annotationLine, -$0.index) < ($1.annotationLine, -$1.index) }
    }

    private static func make(_ annotations: [(text: String, line: Int)], function: String, line: Int, text: String,
                             fileName: String) -> [ComposePreview] {
        let className = TestDiscovery.kotlinClass(atLine: line, text: text, fileName: fileName)
        return annotations.enumerated().map { i, annotation in
            let args = arguments(annotation.text)
            let name = args["name"].map(unquote) ?? (annotations.count > 1 ? "\(function) (\(i + 1))" : function)
            return ComposePreview(
                name: name, function: function, className: className, line: line, annotationLine: annotations[0].line, index: i,
                widthDp: args["widthDp"].flatMap { Int($0) }, heightDp: args["heightDp"].flatMap { Int($0) },
                showBackground: args["showBackground"] == "true", backgroundColor: args["backgroundColor"].flatMap(parseColor))
        }
    }

    private static func functionName(_ code: String) -> String? {
        let range = NSRange(code.startIndex..., in: code)
        guard let m = funDecl.firstMatch(in: code, range: range), let r = Range(m.range(at: 1), in: code) else { return nil }
        return String(code[r])
    }

    /// `name = "x", widthDp = 200` → ["name": "\"x\"", "widthDp": "200"]
    static func arguments(_ annotation: String) -> [String: String] {
        let chars = Array(annotation)
        guard let open = chars.firstIndex(of: "(") else { return [:] }
        let end = argumentsEnd(annotation)
        guard end - 1 > open else { return [:] }
        let body = String(chars[(open + 1)..<(end - 1)])
        var result: [String: String] = [:]
        var current = ""
        var inString = false
        var parts: [String] = []
        for ch in body {
            if ch == "\"" { inString.toggle() }
            if ch == "," && !inString { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        for part in parts {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces)
            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    static func parseColor(_ literal: String) -> UInt32? {
        var s = literal.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        if s.hasSuffix("L") || s.hasSuffix("u") || s.hasSuffix("U") { s.removeLast() }
        if s.hasSuffix("u") || s.hasSuffix("U") { s.removeLast() }
        if s.lowercased().hasPrefix("0x") { return UInt32(s.dropFirst(2), radix: 16) }
        return UInt64(s).map { UInt32(truncatingIfNeeded: $0) }
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()) }
        return t
    }

    /// Open parentheses minus closed ones (outside strings).
    private static func balance(_ s: String) -> Int {
        var depth = 0
        var inString = false
        for ch in s {
            if ch == "\"" { inString.toggle() }
            if inString { continue }
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
        }
        return depth
    }

    /// Character offset just past the annotation's argument list (or its name when it has none).
    private static func argumentsEnd(_ s: String) -> Int {
        var depth = 0
        var inString = false
        var seenOpen = false
        for (i, ch) in s.enumerated() {
            if ch == "\"" { inString.toggle() }
            if inString { continue }
            if ch == "(" { depth += 1; seenOpen = true }
            if ch == ")" { depth -= 1; if depth == 0 && seenOpen { return i + 1 } }
            if !seenOpen && ch.isWhitespace && i > 0 { return i }
        }
        return s.count
    }

    private static func strip(_ line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        let before = line[..<range.lowerBound]
        if before.filter({ $0 == "\"" }).count % 2 == 1 { return line }
        return String(before)
    }
}
