import Foundation

public enum FramingError: Error, Equatable, LocalizedError {
    case invalidHeader(String)
    case missingContentLength
    case headerTooLarge
    case bodyTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader(let line): return "Invalid header line: \(line)"
        case .missingContentLength: return "Missing Content-Length header"
        case .headerTooLarge: return "Header section too large"
        case .bodyTooLarge(let size): return "Message body too large (\(size) bytes)"
        }
    }
}

/// Encodes messages with LSP base-protocol framing (`Content-Length: N\r\n\r\n<body>`).
public enum MessageFramer {
    public static func frame(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}

/// Incrementally decodes a byte stream into framed message bodies. Not thread-safe; feed it from one reader.
public final class FrameDecoder {
    private var buffer = Data()
    private static let separator = Data("\r\n\r\n".utf8)
    public var maxHeaderSize = 16 * 1024
    public var maxBodySize = 256 * 1024 * 1024

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete body, or nil if more bytes are needed.
    public func nextFrame() throws -> Data? {
        guard let headerEnd = buffer.range(of: Self.separator) else {
            if buffer.count > maxHeaderSize { throw FramingError.headerTooLarge }
            return nil
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw FramingError.invalidHeader("<non-UTF-8>")
        }
        var contentLength: Int?
        for line in header.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw FramingError.invalidHeader(line) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" {
                guard let length = Int(value), length >= 0 else { throw FramingError.invalidHeader(line) }
                contentLength = length
            }
        }
        guard let length = contentLength else { throw FramingError.missingContentLength }
        guard length <= maxBodySize else { throw FramingError.bodyTooLarge(length) }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer = Data(buffer[(bodyStart + length)...])
        return body
    }
}
