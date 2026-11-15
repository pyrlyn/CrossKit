import Foundation
import AppKit
import XcodeKit
import CrossKitCore

final class SourceEditorExtension: NSObject, XCSourceEditorExtension {
    func extensionDidFinishLaunching() {
        // Warm up the host so the first command does not pay app-launch latency.
        HostLauncher.launch(activate: false)
    }
}

enum HostLauncher {
    /// CrossKit.app/Contents/PlugIns/CrossKitExtension.appex → CrossKit.app
    static var hostAppURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func launch(activate: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: hostAppURL, configuration: configuration) { _, _ in }
    }
}

final class SourceEditorCommand: NSObject, XCSourceEditorCommand {
    func perform(with invocation: XCSourceEditorCommandInvocation, completionHandler: @escaping (Error?) -> Void) {
        let identifier = invocation.commandIdentifier
        guard let command = EditorCommand(rawValue: identifier.components(separatedBy: ".").last ?? identifier) else {
            completionHandler(Self.error("Unknown CrossKit command \(identifier)"))
            return
        }
        if command == .openSettings {
            HostLauncher.launch(activate: true)
            completionHandler(nil)
            return
        }
        let textBuffer = invocation.buffer
        let lines = textBuffer.lines.compactMap { $0 as? String }
        var selection = EditorRange.caret(0, 0)
        if let range = textBuffer.selections.firstObject as? XCSourceTextRange {
            selection = EditorRange(start: EditorPosition(line: range.start.line, column: range.start.column),
                                  end: EditorPosition(line: range.end.line, column: range.end.column))
        }
        let buffer = EditorBuffer(lines: lines, selection: selection, contentUTI: textBuffer.contentUTI)

        // Respect toggles even before reaching the host (same App Group store).
        let settings = SettingsStore.shared()
        if let language = Language.guess(fromUTI: textBuffer.contentUTI), command != .clearAnnotations {
            if !settings.isEnabled(language) {
                completionHandler(Self.error(BridgeError.languageDisabled(language).localizedDescription))
                return
            }
        }

        let transport = BridgeClient(timeout: 180) {
            HostLauncher.launch(activate: false)
        }
        let task = Task {
            do {
                let outcome = try await EditorCommandEngine().run(command, buffer: buffer, transport: transport)
                try Task.checkCancellation()
                Self.apply(outcome.operations, to: textBuffer)
                completionHandler(outcome.message.map { Self.error($0) })
            } catch is CancellationError {
                completionHandler(nil)
            } catch {
                completionHandler(Self.error(error.localizedDescription))
            }
        }
        invocation.cancellationHandler = { task.cancel() }
    }

    static func apply(_ operations: [BufferOperation], to buffer: XCSourceTextBuffer) {
        for operation in operations {
            switch operation {
            case .replaceLines(let start, let count, let newLines):
                let s = min(max(start, 0), buffer.lines.count)
                let c = min(count, buffer.lines.count - s)
                if c > 0 { buffer.lines.removeObjects(in: NSRange(location: s, length: c)) }
                if !newLines.isEmpty {
                    buffer.lines.insert(newLines, at: IndexSet(integersIn: s..<(s + newLines.count)))
                }
            case .select(let range):
                let lastLine = max(buffer.lines.count - 1, 0)
                let start = XCSourceTextPosition(line: min(range.start.line, lastLine), column: range.start.column)
                let end = XCSourceTextPosition(line: min(range.end.line, lastLine), column: range.end.column)
                buffer.selections.removeAllObjects()
                buffer.selections.add(XCSourceTextRange(start: start, end: end))
            }
        }
    }

    /// XcodeKit can only surface text to the user through an error alert.
    static func error(_ message: String) -> NSError {
        NSError(domain: "dev.pyrlyn.CrossKit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
