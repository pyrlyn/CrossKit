import Foundation

/// Lightweight, syntax-aware-enough test discovery used when no language server offers it.
public enum TestDiscovery {
    public static func discover(_ language: Language, text: String, filePath: String, root: URL) -> [DiscoveredTest] {
        let lines = text.components(separatedBy: "\n")
        switch language {
        case .zig: return zig(lines)
        case .rust: return rust(lines, modulePrefix: rustFileModulePath(filePath: filePath, crateRoot: root))
        case .kotlin: return kotlin(lines)
        }
    }

    // MARK: Zig: `test "name" {`, `test identifier {`, `test {`

    private static let zigTest = try! NSRegularExpression(
        pattern: #"^\s*test\s*(?:"((?:[^"\\]|\\.)*)"|([A-Za-z_][\w.]*))?\s*\{"#)

    static func zig(_ lines: [String]) -> [DiscoveredTest] {
        lines.enumerated().compactMap { index, line in
            guard let match = zigTest.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
            // Zig reports (and `--test-filter` matches) the decoded name, so decode escapes like `\"`.
            let quoted = Range(match.range(at: 1), in: line).map { unescapeZigString(String(line[$0])) }
            let ident = Range(match.range(at: 2), in: line).map { String(line[$0]) }
            let name = quoted ?? ident ?? ""
            return DiscoveredTest(name: name.isEmpty ? "(anonymous test)" : name, filter: name, line: index)
        }
    }

    /// Decodes the escape sequences of a Zig string literal body (`\n`, `\t`, `\r`, `\\`, `\'`, `\"`, `\xNN`, `\u{N}`).
    static func unescapeZigString(_ body: String) -> String {
        guard body.contains("\\") else { return body }
        var result = ""
        var chars = body.makeIterator()
        while let c = chars.next() {
            guard c == "\\", let e = chars.next() else { result.append(c); continue }
            switch e {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "x":
                let hex = String([chars.next(), chars.next()].compactMap { $0 })
                if let v = UInt8(hex, radix: 16) { result.unicodeScalars.append(Unicode.Scalar(v)) } else { result += "\\x" + hex }
            case "u":
                var digits = ""
                if chars.next() == "{" { while let d = chars.next(), d != "}" { digits.append(d) } }
                if let v = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(v) { result.unicodeScalars.append(scalar) }
                else { result += "\\u{" + digits + "}" }
            default: result.append(e)
            }
        }
        return result
    }

    // MARK: Rust: #[test]-like attributes followed by `fn name`, with inline `mod` nesting

    private static let rustTestAttribute = try! NSRegularExpression(
        pattern: #"^\s*#\[\s*(?:[\w:]+::)?(?:test|rstest|test_case|wasm_bindgen_test|quickcheck)\b"#)
    private static let rustFn = try! NSRegularExpression(
        pattern: #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:const\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+([A-Za-z_]\w*)"#)
    private static let rustMod = try! NSRegularExpression(
        pattern: #"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+([A-Za-z_]\w*)\s*\{"#)

    static func rust(_ lines: [String], modulePrefix: [String]) -> [DiscoveredTest] {
        var result: [DiscoveredTest] = []
        var mods: [(name: String, depth: Int)] = []
        var depth = 0
        var pendingTest = false
        for (index, line) in lines.enumerated() {
            let code = stripLineComment(line)
            let range = NSRange(code.startIndex..., in: code)
            if let m = rustMod.firstMatch(in: code, range: range), let r = Range(m.range(at: 1), in: code) {
                mods.append((String(code[r]), depth + 1))
            }
            if rustTestAttribute.firstMatch(in: code, range: range) != nil {
                pendingTest = true
            } else if pendingTest, let m = rustFn.firstMatch(in: code, range: range), let r = Range(m.range(at: 1), in: code) {
                let name = String(code[r])
                let path = (modulePrefix + mods.map(\.name) + [name]).joined(separator: "::")
                result.append(DiscoveredTest(name: name, filter: path, line: index))
                pendingTest = false
            }
            depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
            while let last = mods.last, depth < last.depth { mods.removeLast() }
        }
        return result
    }

    /// Module path of a source file inside a crate: src/lib.rs → [], src/a/b.rs → [a, b], src/a/mod.rs → [a].
    public static func rustFileModulePath(filePath: String, crateRoot: URL) -> [String] {
        let rootPath = crateRoot.standardizedFileURL.path
        let path = URL(fileURLWithPath: filePath).standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return [] }
        var components = String(path.dropFirst(rootPath.count + 1)).split(separator: "/").map(String.init)
        guard components.first == "src", components.count >= 2 else { return [] }
        components.removeFirst()
        if components.first == "bin" { return [] }
        var last = components.removeLast()
        last = (last as NSString).deletingPathExtension
        if components.isEmpty && (last == "lib" || last == "main") { return [] }
        if last != "mod" { components.append(last) }
        return components
    }

    /// Cargo target selection for a file: `--lib`, `--bin x`, `--test x`, or `--bins`.
    public static func rustTargetArguments(filePath: String, crateRoot: URL) -> [String] {
        let rootPath = crateRoot.standardizedFileURL.path
        let path = URL(fileURLWithPath: filePath).standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return [] }
        let relative = String(path.dropFirst(rootPath.count + 1)).split(separator: "/").map(String.init)
        let fm = FileManager.default
        if relative.first == "tests", relative.count == 2 {
            return ["--test", (relative[1] as NSString).deletingPathExtension]
        }
        if relative.first == "tests", relative.count > 2 {
            return ["--test", relative[1]]
        }
        if relative.count >= 3, relative[0] == "src", relative[1] == "bin" {
            let name = relative.count == 3 ? (relative[2] as NSString).deletingPathExtension : relative[2]
            return ["--bin", name]
        }
        let hasLib = fm.fileExists(atPath: crateRoot.appendingPathComponent("src/lib.rs").path)
        if relative == ["src", "main.rs"] || !hasLib { return ["--bins"] }
        return ["--lib"]
    }

    // MARK: Kotlin: @Test-like annotations followed by `fun name(` inside classes

    private static let kotlinPackage = try! NSRegularExpression(pattern: #"^\s*package\s+([\w.]+)"#)
    private static let kotlinClass = try! NSRegularExpression(
        pattern: #"\b(?:class|object)\s+([A-Za-z_]\w*)"#)
    private static let kotlinAnnotation = try! NSRegularExpression(
        pattern: #"@(?:org\.junit\.jupiter\.api\.|org\.junit\.|kotlin\.test\.)?(?:Test|ParameterizedTest|RepeatedTest|TestFactory|TestTemplate)\b"#)
    private static let kotlinFun = try! NSRegularExpression(pattern: #"\bfun\s+(`[^`]+`|[A-Za-z_]\w*)\s*\("#)

    static func kotlin(_ lines: [String]) -> [DiscoveredTest] {
        var result: [DiscoveredTest] = []
        var package = ""
        var classes: [(name: String, depth: Int)] = []
        var depth = 0
        var pendingTest = false
        for (index, line) in lines.enumerated() {
            let code = stripLineComment(line)
            let range = NSRange(code.startIndex..., in: code)
            if let m = kotlinPackage.firstMatch(in: code, range: range), let r = Range(m.range(at: 1), in: code) {
                package = String(code[r])
            }
            if let m = kotlinClass.firstMatch(in: code, range: range), let r = Range(m.range(at: 1), in: code) {
                classes.append((String(code[r]), depth + 1))
            }
            if kotlinAnnotation.firstMatch(in: code, range: range) != nil { pendingTest = true }
            if pendingTest, let m = kotlinFun.firstMatch(in: code, range: range), let r = Range(m.range(at: 1), in: code) {
                let name = String(code[r]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if let className = classes.last.map({ _ in classes.map(\.name).joined(separator: "$") }) {
                    let fqcn = package.isEmpty ? className : "\(package).\(className)"
                    result.append(DiscoveredTest(name: name, filter: "\(fqcn).\(name)", line: index, className: fqcn))
                } else {
                    let fqcn = package.isEmpty ? "" : package + "."
                    result.append(DiscoveredTest(name: name, filter: "\(fqcn)\(name)", line: index))
                }
                pendingTest = false
            }
            depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
            while let last = classes.last, depth < last.depth { classes.removeLast() }
        }
        return result
    }

    private static func stripLineComment(_ line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        // Keep `//` inside string literals (rough: odd number of quotes before it).
        let before = line[..<range.lowerBound]
        if before.filter({ $0 == "\"" }).count % 2 == 1 { return line }
        return String(before)
    }

    /// The test whose declaration is closest at or above `line`.
    public static func test(at line: Int, in tests: [DiscoveredTest]) -> DiscoveredTest? {
        tests.filter { $0.line <= line }.max { $0.line < $1.line }
    }
}
