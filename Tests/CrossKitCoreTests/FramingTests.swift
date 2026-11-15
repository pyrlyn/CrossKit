import XCTest
@testable import CrossKitCore

final class FramingTests: XCTestCase {
    func testFrameRoundTrip() throws {
        let body = Data(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"#.utf8)
        let framed = MessageFramer.frame(body)
        XCTAssertTrue(String(decoding: framed, as: UTF8.self).hasPrefix("Content-Length: \(body.count)\r\n\r\n"))
        let decoder = FrameDecoder()
        decoder.append(framed)
        XCTAssertEqual(try decoder.nextFrame(), body)
        XCTAssertNil(try decoder.nextFrame())
    }

    func testPartialChunksAndMultipleMessages() throws {
        let a = Data(#"{"id":1}"#.utf8), b = Data(#"{"id":2,"text":"héllo wörld 👋"}"#.utf8)
        var stream = MessageFramer.frame(a)
        stream.append(MessageFramer.frame(b))
        let decoder = FrameDecoder()
        var frames: [Data] = []
        for byte in stream {
            decoder.append(Data([byte]))
            while let frame = try decoder.nextFrame() { frames.append(frame) }
        }
        XCTAssertEqual(frames, [a, b])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testContentLengthCountsBytesNotCharacters() throws {
        let body = Data(#"{"s":"ünïcödé"}"#.utf8)
        let header = String(decoding: MessageFramer.frame(body), as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("Content-Length: \(body.count)\r\n"))
        XCTAssertNotEqual(body.count, #"{"s":"ünïcödé"}"#.count)
    }

    func testExtraHeadersAndCaseInsensitivity() throws {
        let body = Data("{}".utf8)
        let decoder = FrameDecoder()
        decoder.append(Data("content-length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}".utf8))
        XCTAssertEqual(try decoder.nextFrame(), body)
    }

    func testMissingContentLengthThrows() {
        let decoder = FrameDecoder()
        decoder.append(Data("Content-Type: x\r\n\r\n{}".utf8))
        XCTAssertThrowsError(try decoder.nextFrame()) { XCTAssertEqual($0 as? FramingError, .missingContentLength) }
    }

    func testInvalidContentLengthThrows() {
        let decoder = FrameDecoder()
        decoder.append(Data("Content-Length: abc\r\n\r\n".utf8))
        XCTAssertThrowsError(try decoder.nextFrame())
    }

    func testOversizedHeaderThrows() {
        let decoder = FrameDecoder()
        decoder.maxHeaderSize = 16
        decoder.append(Data(String(repeating: "x", count: 64).utf8))
        XCTAssertThrowsError(try decoder.nextFrame()) { XCTAssertEqual($0 as? FramingError, .headerTooLarge) }
    }

    func testWaitsForCompleteBody() throws {
        let decoder = FrameDecoder()
        decoder.append(Data("Content-Length: 9\r\n\r\n{\"a\":".utf8))
        XCTAssertNil(try decoder.nextFrame())
        decoder.append(Data("12}".utf8))
        XCTAssertNil(try decoder.nextFrame())
        decoder.append(Data(" ".utf8))
        XCTAssertEqual(try decoder.nextFrame(), Data("{\"a\":12} ".utf8))
    }
}

final class RPCMessageTests: XCTestCase {
    func testParseKinds() throws {
        XCTAssertEqual(try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":3,"method":"workspace/configuration","params":{"items":[{}]}}"#.utf8)),
                       .request(id: 3, method: "workspace/configuration", params: ["items": [[:]]]))
        XCTAssertEqual(try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3}}"#.utf8)),
                       .notification(method: "window/logMessage", params: ["type": 3]))
        XCTAssertEqual(try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)),
                       .response(id: 1, result: .null, error: nil))
        XCTAssertEqual(try RPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":"x","error":{"code":-32601,"message":"nope"}}"#.utf8)),
                       .response(id: "x", result: nil, error: RPCError(code: -32601, message: "nope")))
    }

    func testEncodeRequestUsesIntegerIDs() throws {
        let data = try RPCMessage.request(id: .int(7), method: "initialize", params: ["rootUri": "file:///tmp"]).encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""id":7"#), text)
        XCTAssertTrue(text.contains(#""jsonrpc":"2.0""#))
        XCTAssertTrue(text.contains(#""rootUri":"file:///tmp""#), "slashes must not be escaped: \(text)")
        XCTAssertEqual(try RPCMessage.parse(data), .request(id: 7, method: "initialize", params: ["rootUri": "file:///tmp"]))
    }

    func testEncodeErrorResponse() throws {
        let data = try RPCMessage.response(id: 2, result: nil, error: RPCError(code: -32601, message: "x")).encoded()
        let value = try JSONValue.decode(data)
        XCTAssertEqual(value["error"]?["code"], -32601)
        XCTAssertNil(value["result"])
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = ["a": [1, 2.5, "s", true, nil], "b": ["c": "d"]]
        XCTAssertEqual(try JSONValue.decode(value.encoded()), value)
        XCTAssertEqual(value["a"]?[1]?.doubleValue, 2.5)
        XCTAssertEqual(value["a"]?[3]?.boolValue, true)
    }
}

final class LSPConvertTests: XCTestCase {
    func testLocationsAllShapes() {
        let range: JSONValue = ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 5]]
        XCTAssertEqual(LSPConvert.locations(["uri": "file:///a.rs", "range": range]).count, 1)
        XCTAssertEqual(LSPConvert.locations([["uri": "file:///a.rs", "range": range], ["uri": "file:///b.rs", "range": range]]).count, 2)
        let link = LSPConvert.locations([["targetUri": "file:///c.rs", "targetRange": range, "targetSelectionRange": range]])
        XCTAssertEqual(link.first?.path, "/c.rs")
        XCTAssertEqual(link.first?.range, BridgeRange(startLine: 1, startCharacter: 2, endLine: 1, endCharacter: 5))
        XCTAssertTrue(LSPConvert.locations(.null).isEmpty)
    }

    func testCompletionsListAndSnippets() {
        let result: JSONValue = ["isIncomplete": false, "items": [
            ["label": "compute_answer(…)", "insertTextFormat": 2, "insertText": "compute_answer(${1:value})$0", "sortText": "b"],
            ["label": "count", "detail": "usize"],
        ]]
        let items = LSPConvert.completions(result)
        XCTAssertEqual(items.map(\.insertText), ["compute_answer(value)", "count"])
        XCTAssertEqual(items[1].detail, "usize")
    }

    func testHoverShapes() {
        XCTAssertEqual(LSPConvert.hoverText(["contents": ["kind": "markdown", "value": "```rust\nfn f()\n```"]]), "```rust\nfn f()\n```")
        XCTAssertEqual(LSPConvert.hoverText(["contents": "plain"]), "plain")
        XCTAssertEqual(LSPConvert.hoverText(["contents": [["language": "zig", "value": "fn f() void"], "doc"]]), "fn f() void\n\ndoc")
        XCTAssertNil(LSPConvert.hoverText(.null))
    }

    func testStripSnippet() {
        XCTAssertEqual(LSPConvert.stripSnippet("foo(${1:a}, ${2:b})$0"), "foo(a, b)")
        XCTAssertEqual(LSPConvert.stripSnippet("x${1|one,two|}"), "xone")
        XCTAssertEqual(LSPConvert.stripSnippet("a\\$b$1"), "a$b")
    }
}
