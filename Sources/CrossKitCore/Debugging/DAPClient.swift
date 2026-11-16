import Foundation

/// Minimal Debug Adapter Protocol client over stdio (same Content-Length framing as LSP).
public final class DAPClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (_ event: String, _ body: JSONValue) -> Void

    public let process: ChildProcess
    private let lock = NSLock()
    private var nextSeq = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private let decoder = FrameDecoder()
    private var eventHandler: EventHandler?
    private var stderrTail = Data()
    private var closed = false

    public init(executable: String, arguments: [String] = [], environment: [String: String], currentDirectory: String?) throws {
        let box = WeakBox()
        process = try ChildProcess(
            executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory,
            onStdout: { data in box.client?.receive(data) },
            onStderr: { data in box.client?.receiveStderr(data) },
            onExit: { code in box.client?.adapterExited(code) })
        box.client = self
    }

    private final class WeakBox: @unchecked Sendable { weak var client: DAPClient? }

    public func onEvent(_ handler: @escaping EventHandler) {
        lock.lock(); eventHandler = handler; lock.unlock()
    }

    public var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrTail, as: UTF8.self)
    }

    /// Sends a request and waits for its response body. Throws when the adapter reports failure.
    @discardableResult
    public func request(_ command: String, _ arguments: JSONValue = [:], timeout: TimeInterval = 30) async throws -> JSONValue {
        let seq: Int = lock.withLock { defer { nextSeq += 1 }; return nextSeq }
        let message: JSONValue = ["seq": .int(seq), "type": "request", "command": .string(command), "arguments": arguments]
        let data = try message.encoded()
        return try await withCheckedThrowingContinuation { continuation in
            let isClosed: Bool = lock.withLock {
                if closed { return true }
                pending[seq] = continuation
                return false
            }
            if isClosed {
                continuation.resume(throwing: DebugError.launchFailed("the debug adapter exited. \(stderrText)"))
                return
            }
            do {
                try process.write(MessageFramer.frame(data))
            } catch {
                if let c = lock.withLock({ pending.removeValue(forKey: seq) }) { c.resume(throwing: error) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let c = self.lock.withLock({ self.pending.removeValue(forKey: seq) }) else { return }
                c.resume(throwing: DebugError.launchFailed("\(command) timed out after \(Int(timeout))s"))
            }
        }
    }

    private func receive(_ data: Data) {
        if data.isEmpty { return }
        var messages: [JSONValue] = []
        lock.lock()
        decoder.append(data)
        while let frame = try? decoder.nextFrame() {
            if let value = try? JSONDecoder().decode(JSONValue.self, from: frame) { messages.append(value) }
        }
        lock.unlock()
        for message in messages { dispatch(message) }
    }

    private func dispatch(_ message: JSONValue) {
        switch message["type"]?.stringValue {
        case "response":
            guard let seq = message["request_seq"]?.intValue,
                  let continuation = lock.withLock({ pending.removeValue(forKey: seq) }) else { return }
            if message["success"]?.boolValue == true {
                continuation.resume(returning: message["body"] ?? .null)
            } else {
                let text = message["body"]?["error"]?["format"]?.stringValue ?? message["message"]?.stringValue ?? "request failed"
                continuation.resume(throwing: DebugError.launchFailed("\(message["command"]?.stringValue ?? "request"): \(text)"))
            }
        case "event":
            let handler = lock.withLock { eventHandler }
            handler?(message["event"]?.stringValue ?? "", message["body"] ?? .null)
        case "request":
            // Reverse requests (runInTerminal, startDebugging) are not supported; answer so the adapter does not hang.
            if let seq = message["seq"]?.intValue, let command = message["command"]?.stringValue {
                let reply: JSONValue = ["seq": .int(lock.withLock { defer { nextSeq += 1 }; return nextSeq }), "type": "response",
                                        "request_seq": .int(seq), "command": .string(command), "success": false,
                                        "message": "not supported by CrossKit"]
                if let data = try? reply.encoded() { try? process.write(MessageFramer.frame(data)) }
            }
        default:
            break
        }
    }

    private func receiveStderr(_ data: Data) {
        lock.lock()
        stderrTail.append(data)
        if stderrTail.count > 16 * 1024 { stderrTail = stderrTail.suffix(16 * 1024) }
        lock.unlock()
    }

    private func adapterExited(_ code: Int32) {
        let waiting: [CheckedContinuation<JSONValue, Error>] = lock.withLock {
            closed = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        let reason = DebugError.launchFailed("the debug adapter exited with code \(code). \(stderrText)")
        for continuation in waiting { continuation.resume(throwing: reason) }
        let handler = lock.withLock { eventHandler }
        handler?("adapterExited", ["exitCode": .int(Int(code))])
    }

    public func terminate() {
        process.closeStdin()
        if !process.waitForExit(timeout: 2) {
            process.terminateGroup()
            if !process.waitForExit(timeout: 2) { process.killGroup(); _ = process.waitForExit(timeout: 2) }
        }
    }
}
