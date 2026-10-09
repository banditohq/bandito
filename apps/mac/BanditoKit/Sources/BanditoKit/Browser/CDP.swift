import Foundation

// Chrome DevTools Protocol: the commands the app sends to a page, and the messages it reads back.
// Pure encoding and parsing; the socket lives in `CDPClient`.

extension JSONValue {
    /// The number, when this is a number.
    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
}

public enum CDPMouseType: String, Sendable {
    case mouseMoved, mousePressed, mouseReleased, mouseWheel
}

public enum CDPMouseButton: String, Sendable {
    case none, left, middle, right
}

public enum CDPKeyType: String, Sendable {
    case keyDown, keyUp, rawKeyDown, char
}

/// One command of the protocol: its method name and its params.
public enum CDPCommand: Sendable {
    case navigate(url: String)
    case reload
    case navigationHistory
    case navigateToHistoryEntry(id: Int)
    case startScreencast(maxWidth: Int, maxHeight: Int, quality: Int)
    case stopScreencast
    /// Tells the page that the frame was received; the next frame comes only after this.
    case ackScreencastFrame(sessionId: Int)
    case mouse(
        type: CDPMouseType, x: Double, y: Double, button: CDPMouseButton, clickCount: Int,
        deltaX: Double, deltaY: Double, modifiers: KeyModifiers)
    case key(type: CDPKeyType, key: CDPKeyDescriptor, modifiers: KeyModifiers)
    /// Text typed as a whole (IME-friendly), without key events.
    case insertText(String)
    /// A ⌘ edit shortcut sent as a key press with a `commands` entry, so the page edits its selection.
    case editing(BrowserEdit, key: CDPKeyDescriptor, modifiers: KeyModifiers)
    case getTargets
    case createTarget(url: String)
    case activateTarget(id: String)

    public var method: String {
        switch self {
        case .navigate: "Page.navigate"
        case .reload: "Page.reload"
        case .navigationHistory: "Page.getNavigationHistory"
        case .navigateToHistoryEntry: "Page.navigateToHistoryEntry"
        case .startScreencast: "Page.startScreencast"
        case .stopScreencast: "Page.stopScreencast"
        case .ackScreencastFrame: "Page.screencastFrameAck"
        case .mouse: "Input.dispatchMouseEvent"
        case .key: "Input.dispatchKeyEvent"
        case .insertText: "Input.insertText"
        case .editing: "Input.dispatchKeyEvent"
        case .getTargets: "Target.getTargets"
        case .createTarget: "Target.createTarget"
        case .activateTarget: "Target.activateTarget"
        }
    }

    public var params: JSONValue {
        switch self {
        case .navigate(let url):
            return .object(["url": .string(url)])
        case .reload, .navigationHistory, .stopScreencast, .getTargets:
            return .object([:])
        case .navigateToHistoryEntry(let id):
            return .object(["entryId": .number(Double(id))])
        case .startScreencast(let maxWidth, let maxHeight, let quality):
            return .object([
                "format": .string("jpeg"),
                "quality": .number(Double(quality)),
                "maxWidth": .number(Double(maxWidth)),
                "maxHeight": .number(Double(maxHeight)),
            ])
        case .ackScreencastFrame(let sessionId):
            return .object(["sessionId": .number(Double(sessionId))])
        case .mouse(let type, let x, let y, let button, let clickCount, let deltaX, let deltaY, let modifiers):
            // Only presses and drags hold a button down; a release or a wheel tick reports none.
            let holding = type == .mousePressed || (type == .mouseMoved && button != .none)
            return .object([
                "type": .string(type.rawValue),
                "x": .number(x),
                "y": .number(y),
                "button": .string(button.rawValue),
                "buttons": .number(Double(holding ? BrowserKeys.buttonMask(button) : 0)),
                "clickCount": .number(Double(clickCount)),
                "deltaX": .number(deltaX),
                "deltaY": .number(deltaY),
                "modifiers": .number(Double(BrowserKeys.bitmask(modifiers))),
            ])
        case .key(let type, let key, let modifiers):
            var object: [String: JSONValue] = [
                "type": .string(type.rawValue),
                "key": .string(key.key),
                "code": .string(key.code),
                "windowsVirtualKeyCode": .number(Double(key.windowsVirtualKeyCode)),
                "modifiers": .number(Double(BrowserKeys.bitmask(modifiers))),
            ]
            if let text = key.text, type == .keyDown || type == .char {
                object["text"] = .string(text)
            }
            return .object(object)
        case .insertText(let text):
            return .object(["text": .string(text)])
        case .editing(let edit, let key, let modifiers):
            var object: [String: JSONValue] = [
                "type": .string(CDPKeyType.keyDown.rawValue),
                "key": .string(key.key),
                "code": .string(key.code),
                "windowsVirtualKeyCode": .number(Double(key.windowsVirtualKeyCode)),
                "modifiers": .number(Double(BrowserKeys.bitmask(modifiers))),
            ]
            // No text: a shortcut must not type its letter.
            if let name = edit.cdpCommandName {
                object["commands"] = .array([.string(name)])
            }
            return .object(object)
        case .createTarget(let url):
            return .object(["url": .string(url)])
        case .activateTarget(let id):
            return .object(["targetId": .string(id)])
        }
    }
}

/// A message read from the page: the answer to a call, or an event.
public enum CDPMessage: Sendable, Equatable {
    case response(id: Int, result: JSONValue)
    case error(id: Int, code: Int, message: String)
    case event(method: String, params: JSONValue)
}

/// One screencast frame: a JPEG of the page at `deviceWidth` × `deviceHeight` CSS pixels.
public struct ScreencastFrame: Sendable, Equatable {
    public var jpeg: Data
    /// Must be sent back with `Page.screencastFrameAck`.
    public var sessionId: Int
    public var deviceWidth: Double
    public var deviceHeight: Double
}

public enum CDP {
    /// The request text: `{"id":…,"method":…,"params":…}`.
    public static func encode(id: Int, command: CDPCommand) -> String {
        let envelope: JSONValue = .object([
            "id": .number(Double(id)),
            "method": .string(command.method),
            "params": command.params,
        ])
        // Encoding a JSONValue cannot fail: it holds only finite numbers and strings.
        let data = (try? JSONEncoder().encode(envelope)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads one message. Throws when the text is not JSON or has neither an `id` nor a `method`.
    public static func parse(_ text: String) throws -> CDPMessage {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard case .object(let object) = value else { throw CDPError.badMessage }
        if let id = object["id"]?.numberValue {
            if let error = object["error"] {
                return .error(
                    id: Int(id),
                    code: Int(error["code"]?.numberValue ?? 0),
                    message: error["message"]?.string ?? "")
            }
            return .response(id: Int(id), result: object["result"] ?? .object([:]))
        }
        if let method = object["method"]?.string {
            return .event(method: method, params: object["params"] ?? .object([:]))
        }
        throw CDPError.badMessage
    }

    /// The frame of a `Page.screencastFrame` event's params, or nil when a field is missing or the data is not base64.
    public static func screencastFrame(from params: JSONValue) -> ScreencastFrame? {
        guard
            let encoded = params["data"]?.string,
            let jpeg = Data(base64Encoded: encoded),
            let sessionId = params["sessionId"]?.numberValue,
            let metadata = params["metadata"],
            let width = metadata["deviceWidth"]?.numberValue,
            let height = metadata["deviceHeight"]?.numberValue
        else { return nil }
        return ScreencastFrame(
            jpeg: jpeg, sessionId: Int(sessionId), deviceWidth: width, deviceHeight: height)
    }

    /// `ws://127.0.0.1:<local>/devtools/page/<id>` from the local HTTP URL that `forwardOnce` returned.
    public static func pageSocketURL(local: URL, pageId: String) -> URL? {
        socketURL(local: local, path: "/devtools/page/\(pageId)")
    }

    /// The browser-level socket: `ws://127.0.0.1:<local><path>`, for `Target.*` calls.
    public static func browserSocketURL(local: URL, path: String) -> URL? {
        socketURL(local: local, path: path.hasPrefix("/") ? path : "/" + path)
    }

    private static func socketURL(local: URL, path: String) -> URL? {
        guard var components = URLComponents(url: local, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "ws"
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
