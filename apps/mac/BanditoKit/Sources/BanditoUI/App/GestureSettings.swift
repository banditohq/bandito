import BanditoL10n
import Foundation
import Observation

/// The trackpad gestures from the design. Each one can be switched off in Settings → Keys and gestures.
public enum Gesture: String, CaseIterable, Sendable {
    case twoFingerSwipe, agentRowSwipe, pinch, panePinch, forcePress, doubleTapTwoFingers

    public var title: String {
        switch self {
        case .twoFingerSwipe: L10n.Gestures.TwoFingerSwipe.title
        case .agentRowSwipe: L10n.Gestures.AgentRow.title
        case .pinch: L10n.Gestures.Pinch.title
        case .panePinch: L10n.Gestures.PanePinch.title
        case .forcePress: L10n.Gestures.ForcePress.title
        case .doubleTapTwoFingers: L10n.Gestures.DoubleTap.title
        }
    }

    public var text: String {
        switch self {
        case .twoFingerSwipe: L10n.Gestures.TwoFingerSwipe.text
        case .agentRowSwipe: L10n.Gestures.AgentRow.text
        case .pinch: L10n.Gestures.Pinch.text
        case .panePinch: L10n.Gestures.PanePinch.text
        case .forcePress: L10n.Gestures.ForcePress.text
        case .doubleTapTwoFingers: L10n.Gestures.DoubleTap.text
        }
    }

    public var whereUsed: String {
        switch self {
        case .twoFingerSwipe: L10n.Gestures.TwoFingerSwipe.`where`
        case .agentRowSwipe: L10n.Gestures.AgentRow.`where`
        case .pinch: L10n.Gestures.Pinch.`where`
        case .panePinch: L10n.Gestures.PanePinch.`where`
        case .forcePress: L10n.Gestures.ForcePress.`where`
        case .doubleTapTwoFingers: L10n.Gestures.DoubleTap.`where`
        }
    }

    /// SF Symbol drawn on the gesture card.
    public var systemImage: String {
        switch self {
        case .twoFingerSwipe: "arrow.left.arrow.right"
        case .agentRowSwipe: "list.bullet.indent"
        case .pinch: "arrow.up.left.and.arrow.down.right"
        case .panePinch: "rectangle.expand.vertical"
        case .forcePress: "hand.point.up.left"
        case .doubleTapTwoFingers: "hand.tap"
        }
    }

    /// Off out of the box: the double tap is easy to trigger by accident.
    public var isOnByDefault: Bool {
        self != .doubleTapTwoFingers
    }
}

/// Which trackpad gestures are on, and how sensitive the swipes are. Stored under `gestures.v1`.
@MainActor
@Observable
public final class GestureSettings {
    public static let storageKey = "gestures.v1"

    @ObservationIgnored private let defaults: UserDefaults
    private var enabled: Set<Gesture>

    /// 0 is the firmest swipe, 1 the lightest. Clamped to 0...1.
    public var swipeSensitivity: Double {
        didSet {
            let clamped = min(max(swipeSensitivity, 0), 1)
            if clamped != swipeSensitivity {
                swipeSensitivity = clamped
            }
            save()
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = Set(Gesture.allCases.filter(\.isOnByDefault))
        swipeSensitivity = 0.5
        if let data = defaults.data(forKey: Self.storageKey),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        {
            enabled = Set(stored.enabled.compactMap(Gesture.init(rawValue:)))
            swipeSensitivity = min(max(stored.swipeSensitivity, 0), 1)
        }
    }

    public func isEnabled(_ gesture: Gesture) -> Bool {
        enabled.contains(gesture)
    }

    public func setEnabled(_ gesture: Gesture, _ on: Bool) {
        if on {
            enabled.insert(gesture)
        } else {
            enabled.remove(gesture)
        }
        save()
    }

    private struct Stored: Codable {
        var enabled: [String]
        var swipeSensitivity: Double
    }

    private func save() {
        let stored = Stored(enabled: enabled.map(\.rawValue).sorted(), swipeSensitivity: swipeSensitivity)
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
