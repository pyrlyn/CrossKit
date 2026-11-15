import AppKit
import CrossKitCore

/// XcodeKit does not tell extensions which file a buffer belongs to. The host asks Xcode via
/// Apple Events for its open source documents and picks the one matching the buffer.
enum XcodeDocumentLocator {
    static func resolve(_ request: BridgeRequest, language: Language?) -> URL? {
        let paths = openDocumentPaths()
        let settings = SettingsStore.shared()
        let candidates = paths.filter { path in
            guard let detected = settings.language(forPath: path) else { return false }
            return language == nil || detected == language
        }
        guard !candidates.isEmpty else { return nil }
        let buffer = normalize(request.text)
        if let exact = candidates.first(where: { normalize((try? String(contentsOfFile: $0, encoding: .utf8)) ?? "") == buffer }) {
            return URL(fileURLWithPath: exact)
        }
        // Unsaved edits: pick the file sharing the most lines with the buffer.
        let bufferLines = Set(buffer.split(separator: "\n"))
        let scored = candidates.map { path -> (String, Int) in
            let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n")
            return (path, lines.filter { bufferLines.contains($0) }.count)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return URL(fileURLWithPath: best.0)
    }

    static func openDocumentPaths() -> [String] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty else { return [] }
        let work = {
            let script = NSAppleScript(source: "tell application id \"com.apple.dt.Xcode\" to get path of every source document")
            var error: NSDictionary?
            guard let descriptor = script?.executeAndReturnError(&error) else { return [String]() }
            if descriptor.numberOfItems == 0 { return [descriptor.stringValue].compactMap { $0 } }
            return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0)?.stringValue }
        }
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    static func open(_ location: BridgeLocation) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
        process.arguments = ["--line", String(location.range.startLine + 1), location.path]
        try? process.run()
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
    }
}
