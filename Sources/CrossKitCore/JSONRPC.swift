import Foundation

public struct RPCError: Error, Equatable, Sendable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { "LSP error \(code): \(message)" }

    public static let methodNotFound = -32601
}

/// A decoded JSON-RPC 2.0 message.
public enum RPCMessage: Equatable {
    case request(id: JSONValue, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONValue, result: JSONValue?, error: RPCError?)

    public static func parse(_ data: Data) throws -> RPCMessage {
        let value = try JSONValue.decode(data)
        guard case .object(let object) = value else {
            throw FramingError.invalidHeader("JSON-RPC message is not an object")
        }
        let id = object["id"]
        if let method = object["method"]?.stringValue {
            if let id, !id.isNull {
                return .request(id: id, method: method, params: object["params"])
            }
            return .notification(method: method, params: object["params"])
        }
        guard let id else { throw FramingError.invalidHeader("JSON-RPC message without id or method") }
        var rpcError: RPCError?
        if let error = object["error"], case .object(let e) = error {
            rpcError = RPCError(code: e["code"]?.intValue ?? 0, message: e["message"]?.stringValue ?? "", data: e["data"])
        }
        return .response(id: id, result: object["result"], error: rpcError)
    }

    public func encoded() throws -> Data {
        var object: [String: JSONValue] = ["jsonrpc": "2.0"]
        switch self {
        case .request(let id, let method, let params):
            object["id"] = id
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .notification(let method, let params):
            object["method"] = .string(method)
            if let params { object["params"] = params }
        case .response(let id, let result, let error):
            object["id"] = id
            if let error {
                var e: [String: JSONValue] = ["code": .int(error.code), "message": .string(error.message)]
                if let data = error.data { e["data"] = data }
                object["error"] = .object(e)
            } else {
                object["result"] = result ?? .null
            }
        }
        return try JSONValue.object(object).encoded()
    }

    /// Body wrapped in Content-Length framing, ready to write to a server's stdin.
    public func framed() throws -> Data {
        MessageFramer.frame(try encoded())
    }
}
