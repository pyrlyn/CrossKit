import Foundation
import CoreFoundation

public enum BridgePortError: Error, LocalizedError {
    case nameInUse(String)
    case hostUnavailable
    case send(Int32)
    case malformedReply

    public var errorDescription: String? {
        switch self {
        case .nameInUse(let name): return "Bridge port \(name) is already in use (is another CrossKit instance running?)"
        case .hostUnavailable: return "CrossKit host app is not reachable. Open the CrossKit app once."
        case .send(let code):
            switch code {
            case kCFMessagePortSendTimeout, kCFMessagePortReceiveTimeout: return "CrossKit host app did not answer in time."
            default: return "CrossKit bridge error \(code)."
            }
        case .malformedReply: return "CrossKit host app sent an unreadable reply."
        }
    }
}

/// Transport between the sandboxed extension and the host app: a CFMessagePort (Mach) named
/// `<app group>.bridge`. The App Sandbox lets an extension look up Mach names prefixed with its
/// App Group, and no files are shared, so no container permissions are involved.
/// Payloads are JSON with the same Content-Length framing used for LSP.
public final class BridgeServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BridgeRequest) async -> BridgeResponse
    public let portName: String
    private let handler: Handler
    private var port: CFMessagePort?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private var startError: Error?

    public init(portName: String = SharedPaths.bridgePortName, handler: @escaping Handler) {
        self.portName = portName
        self.handler = handler
    }

    public func start() throws {
        let thread = Thread { [self] in self.run() }
        thread.name = "CrossKit.bridge"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
        if let startError { throw startError }
    }

    private func run() {
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: CFMessagePortCallBack = { _, _, data, info in
            guard let info else { return nil }
            let server = Unmanaged<BridgeServer>.fromOpaque(info).takeUnretainedValue()
            let reply = server.respond(to: (data as Data?) ?? Data())
            return Unmanaged.passRetained(reply as CFData)
        }
        var shouldFree: DarwinBoolean = false
        guard let port = CFMessagePortCreateLocal(nil, portName as CFString, callback, &context, &shouldFree) else {
            startError = BridgePortError.nameInUse(portName)
            ready.signal()
            return
        }
        self.port = port
        runLoop = CFRunLoopGetCurrent()
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        ready.signal()
        CFRunLoopRun()
    }

    /// Runs the async handler and blocks the port thread until it finishes (requests are serialized).
    func respond(to data: Data) -> Data {
        let response: BridgeResponse
        let decoder = FrameDecoder()
        decoder.append(data)
        if let body = try? decoder.nextFrame(), let request = try? JSONDecoder().decode(BridgeRequest.self, from: body) {
            let box = ResponseBox()
            let done = DispatchSemaphore(value: 0)
            let handler = self.handler
            Task.detached(priority: .userInitiated) {
                box.value = await handler(request)
                done.signal()
            }
            done.wait()
            response = box.value ?? .failure("No response")
        } else {
            response = .failure("Malformed bridge request")
        }
        return MessagePort.encode(response)
    }

    public func stop() {
        if let port { CFMessagePortInvalidate(port) }
        port = nil
        if let runLoop { CFRunLoopStop(runLoop) }
        runLoop = nil
    }
}

private final class ResponseBox: @unchecked Sendable {
    var value: BridgeResponse?
}

enum MessagePort {
    static func encode<T: Encodable>(_ value: T) -> Data {
        MessageFramer.frame((try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = FrameDecoder()
        decoder.append(data)
        guard let body = try decoder.nextFrame() else { throw BridgePortError.malformedReply }
        return try JSONDecoder().decode(type, from: body)
    }
}

/// Extension side of the bridge.
public final class BridgeClient: @unchecked Sendable {
    public let portName: String
    public let timeout: TimeInterval
    private let launchHost: (@Sendable () -> Void)?
    public var connectRetryWindow: TimeInterval = 15

    public init(portName: String = SharedPaths.bridgePortName, timeout: TimeInterval = 120,
                launchHost: (@Sendable () -> Void)? = nil) {
        self.portName = portName
        self.timeout = timeout
        self.launchHost = launchHost
    }

    public func send(_ request: BridgeRequest) async throws -> BridgeResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.sendBlocking(request) })
            }
        }
    }

    public func sendBlocking(_ request: BridgeRequest) throws -> BridgeResponse {
        // Note: CF caches remote ports per name within a process; do not invalidate them here.
        let port = try remotePort()
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 1, MessagePort.encode(request) as CFData, 10, timeout,
                                              CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let data = reply?.takeRetainedValue() else {
            throw BridgePortError.send(status)
        }
        return try MessagePort.decode(BridgeResponse.self, from: data as Data)
    }

    private func remotePort() throws -> CFMessagePort {
        if let port = CFMessagePortCreateRemote(nil, portName as CFString) { return port }
        guard let launchHost else { throw BridgePortError.hostUnavailable }
        launchHost()
        let deadline = Date().addingTimeInterval(connectRetryWindow)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if let port = CFMessagePortCreateRemote(nil, portName as CFString) { return port }
        }
        throw BridgePortError.hostUnavailable
    }
}
