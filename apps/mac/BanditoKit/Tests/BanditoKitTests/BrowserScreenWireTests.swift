import Foundation
import Testing

@testable import BanditoKit

// Wire models of `browser.*` and `screen.*` (docs/ARCHITECTURE.md#screen) and the CDP command encoding.

private func json(_ text: String) throws -> Data {
    Data(text.utf8)
}

@Test func browserStatusDecodesRunningBrowser() throws {
    let data = try json(
        """
        {"running":true,"cdp":"relay","pid":4321,
         "started_at":1700000000000,"controller":"agent"}
        """)
    let status = try RPCClient.decoder.decode(BrowserStatus.self, from: data)
    #expect(status.running)
    #expect(status.cdp == "relay")
    #expect(status.isRelay)
    #expect(status.pid == 4321)
    #expect(status.startedAt == 1_700_000_000_000)
    #expect(status.controller == .agent)
}

@Test func browserStatusWhenStoppedNeedsOnlyRunning() throws {
    let data = try json(#"{"running":false}"#)
    let status = try RPCClient.decoder.decode(BrowserStatus.self, from: data)
    #expect(!status.running)
    #expect(status.cdp == nil)
    #expect(!status.isRelay)
    #expect(status.controller == .none)
}

@Test func controlHolderUsesWireNames() throws {
    #expect(try RPCClient.decoder.decode(ControlHolder.self, from: json(#""user""#)) == .user)
    #expect(try RPCClient.decoder.decode(ControlHolder.self, from: json(#""agent""#)) == .agent)
    #expect(try RPCClient.decoder.decode(ControlHolder.self, from: json(#""none""#)) == .none)
}

@Test func browserTabDecodesTargetListEntry() throws {
    let data = try json(
        """
        [{"description":"","devtoolsFrontendUrl":"","id":"ABC","title":"billing admin","type":"page",
          "url":"http://localhost:3000/admin","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/ABC"},
         {"id":"SW1","title":"worker","type":"service_worker","url":"http://localhost:3000/sw.js"}]
        """)
    let tabs = try JSONDecoder().decode([BrowserTab].self, from: data)
    #expect(tabs.count == 2)
    #expect(tabs[0].id == "ABC")
    #expect(tabs[0].title == "billing admin")
    #expect(tabs[0].url == "http://localhost:3000/admin")
    #expect(tabs[0].isPage)
    #expect(!tabs[1].isPage)
}

@Test func screenStatusDecodesWireReply() throws {
    let data = try json(
        """
        {"running":true,"display":":90","width":1280,"height":800,"vnc_port":5901,
         "vnc_password":"s3cret","started_at":1700000000000,"controller":"user","idle_ms":1200}
        """)
    let status = try RPCClient.decoder.decode(ScreenStatus.self, from: data)
    #expect(status.running)
    #expect(status.display == ":90")
    #expect(status.width == 1280)
    #expect(status.height == 800)
    #expect(status.vncPort == 5901)
    #expect(status.vncPassword == "s3cret")
    #expect(status.controller == .user)
    #expect(status.idleMs == 1200)
}

@Test func screenStatusWhenStoppedDecodesWithoutDetails() throws {
    let status = try RPCClient.decoder.decode(ScreenStatus.self, from: json(#"{"running":false}"#))
    #expect(!status.running)
    #expect(status.vncPort == nil)
    #expect(status.vncPassword == nil)
    #expect(status.controller == .none)
}

// MARK: CDP command encoding

private func parsed(_ text: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
    return try #require(object as? [String: Any])
}

@Test func cdpRequestCarriesIdMethodAndParams() throws {
    let text = CDP.encode(id: 7, command: .navigate(url: "https://example.com/"))
    let object = try parsed(text)
    #expect(object["id"] as? Int == 7)
    #expect(object["method"] as? String == "Page.navigate")
    let params = try #require(object["params"] as? [String: Any])
    #expect(params["url"] as? String == "https://example.com/")
}

@Test func startScreencastAsksForJpegWithSize() throws {
    let command = CDPCommand.startScreencast(maxWidth: 1280, maxHeight: 800, quality: 70)
    #expect(command.method == "Page.startScreencast")
    let object = try parsed(CDP.encode(id: 1, command: command))
    let params = try #require(object["params"] as? [String: Any])
    #expect(params["format"] as? String == "jpeg")
    #expect(params["quality"] as? Int == 70)
    #expect(params["maxWidth"] as? Int == 1280)
    #expect(params["maxHeight"] as? Int == 800)
}

@Test func screencastAckNamesTheSession() throws {
    let object = try parsed(CDP.encode(id: 2, command: .ackScreencastFrame(sessionId: 41)))
    #expect(object["method"] as? String == "Page.screencastFrameAck")
    let params = try #require(object["params"] as? [String: Any])
    #expect(params["sessionId"] as? Int == 41)
}

@Test func mouseEventCarriesTypeButtonAndModifiers() throws {
    let command = CDPCommand.mouse(
        type: .mousePressed, x: 10.5, y: 20, button: .left, clickCount: 1, deltaX: 0, deltaY: 0,
        modifiers: [.shift, .meta])
    #expect(command.method == "Input.dispatchMouseEvent")
    let object = try parsed(CDP.encode(id: 3, command: command))
    let params = try #require(object["params"] as? [String: Any])
    #expect(params["type"] as? String == "mousePressed")
    #expect(params["button"] as? String == "left")
    #expect(params["x"] as? Double == 10.5)
    #expect(params["clickCount"] as? Int == 1)
    #expect(params["modifiers"] as? Int == 8 | 4)
}

@Test func insertTextAndTabCommandsUseTheirMethods() throws {
    #expect(CDPCommand.insertText("héllo").method == "Input.insertText")
    #expect(CDPCommand.createTarget(url: "about:blank").method == "Target.createTarget")
    #expect(CDPCommand.activateTarget(id: "T1").method == "Target.activateTarget")
    #expect(CDPCommand.closeTarget(id: "T1").method == "Target.closeTarget")
    #expect(CDPCommand.getTargets.method == "Target.getTargets")
    #expect(CDPCommand.reload.method == "Page.reload")
    #expect(CDPCommand.navigationHistory.method == "Page.getNavigationHistory")
    #expect(CDPCommand.navigateToHistoryEntry(id: 5).method == "Page.navigateToHistoryEntry")
}

// MARK: CDP message parsing

@Test func parsesResponseErrorAndEvent() throws {
    let response = try CDP.parse(#"{"id":4,"result":{"frameId":"F"}}"#)
    guard case .response(let id, let result) = response else {
        Issue.record("expected a response, got \(response)")
        return
    }
    #expect(id == 4)
    #expect(result["frameId"]?.string == "F")

    let failure = try CDP.parse(#"{"id":5,"error":{"code":-32000,"message":"No node"}}"#)
    #expect(failure == .error(id: 5, code: -32000, message: "No node"))

    let event = try CDP.parse(#"{"method":"Page.frameNavigated","params":{"frame":{"url":"x"}}}"#)
    guard case .event(let method, let params) = event else {
        Issue.record("expected an event, got \(event)")
        return
    }
    #expect(method == "Page.frameNavigated")
    #expect(params["frame"]?["url"]?.string == "x")
}

@Test func screencastFrameIsDecodedFromItsEvent() throws {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01])
    let text = """
        {"method":"Page.screencastFrame","params":{"data":"\(jpeg.base64EncodedString())",
         "metadata":{"offsetTop":0,"pageScaleFactor":1,"deviceWidth":1280,"deviceHeight":800,
         "scrollOffsetX":0,"scrollOffsetY":0,"timestamp":1.5},"sessionId":12}}
        """
    guard case .event(let method, let params) = try CDP.parse(text) else {
        Issue.record("expected an event")
        return
    }
    #expect(method == "Page.screencastFrame")
    let frame = try #require(CDP.screencastFrame(from: params))
    #expect(frame.jpeg == jpeg)
    #expect(frame.sessionId == 12)
    #expect(frame.deviceWidth == 1280)
    #expect(frame.deviceHeight == 800)
}

@Test func screencastFrameWithBrokenDataIsRejected() throws {
    let text = #"{"method":"Page.screencastFrame","params":{"data":"%%%","metadata":{"deviceWidth":1,"deviceHeight":1},"sessionId":1}}"#
    guard case .event(_, let params) = try CDP.parse(text) else {
        Issue.record("expected an event")
        return
    }
    #expect(CDP.screencastFrame(from: params) == nil)
}

@Test func garbageIsNotCDP() {
    #expect(throws: (any Error).self) { try CDP.parse("not json") }
}

@Test func runningWithoutTheRelayIsNotConnectable() throws {
    let status = try RPCClient.decoder.decode(BrowserStatus.self, from: json(#"{"running":true,"cdp":"port"}"#))
    #expect(!status.isRelay)
}

@Test func cdpEvaluateEncodesTheExpression() throws {
    let text = CDP.encode(id: 4, command: .evaluate(expression: "1 + 1"))
    let object = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(object["method"] == .string("Runtime.evaluate"))
    #expect(object["params"]?["expression"] == .string("1 + 1"))
    #expect(object["params"]?["returnByValue"] == .bool(true))
}
