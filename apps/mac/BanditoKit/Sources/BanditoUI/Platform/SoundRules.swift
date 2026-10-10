import Foundation

/// A sound set: the same events, drawn in one character. The Settings page lists them in this order.
public enum SoundKit: String, CaseIterable, Sendable {
    /// Warm sine tones, quiet.
    case soft
    /// Keyboard clicks: a noise burst that rings through a resonance.
    case mechanics
    /// High bells.
    case glass
    /// 8-bit square waves.
    case retro
}

/// What makes a sound. The first four are the person's own actions, the last three come from agents.
public enum SoundEvent: String, CaseIterable, Sendable {
    /// A button was pressed.
    case click
    /// A character was typed into the message box.
    case type
    /// The mode or tab changed.
    case tab
    /// A message was sent.
    case send
    /// An agent finished its turn.
    case done
    /// An agent waits for the person (an approval or a question). The most noticeable sound.
    case needsYou
    /// An agent's turn failed.
    case error

    /// Agent events come from the agents, not from the person. They may play while the window is in the background.
    public var isAgentEvent: Bool {
        switch self {
        case .done, .needsYou, .error: true
        case .click, .type, .tab, .send: false
        }
    }

    /// Relative level inside a set: the set's peak is scaled by this.
    var loudness: Double {
        switch self {
        case .click: 0.6
        case .type: 0.45
        case .tab: 0.55
        case .send: 0.65
        case .done: 0.75
        case .needsYou: 1.0
        case .error: 0.9
        }
    }
}

/// The person's choices for sound, read from the same keys the Settings → Sounds page writes.
public struct SoundSettings: Equatable, Sendable {
    /// The main switch. Off by default.
    public static let enabledKey = "sound.enabled"
    public static let kitKey = "sound.kit"
    public static let volumeKey = "sound.volume"
    public static let backgroundKey = "sound.background"
    /// The per-event switch key, e.g. `sound.event.click`.
    public static func eventKey(_ event: SoundEvent) -> String { "sound.event.\(event.rawValue)" }

    public var enabled: Bool
    public var kit: SoundKit
    /// 0 to 1. Applies to every sound.
    public var volume: Double
    /// The events that make a sound. All on by default.
    public var events: Set<SoundEvent>
    /// "And when the window is in the background": agent events also play when Bandito is not in front.
    public var playsInBackground: Bool

    public init(
        enabled: Bool = false, kit: SoundKit = .soft, volume: Double = 0.6,
        events: Set<SoundEvent> = Set(SoundEvent.allCases), playsInBackground: Bool = false
    ) {
        self.enabled = enabled
        self.kit = kit
        self.volume = min(max(volume, 0), 1)
        self.events = events
        self.playsInBackground = playsInBackground
    }

    /// Reads the keys the Settings → Sounds page writes. A missing or unknown value takes the default.
    public init(defaults: UserDefaults) {
        self.init(
            enabled: defaults.object(forKey: Self.enabledKey) as? Bool ?? false,
            kit: defaults.string(forKey: Self.kitKey).flatMap(SoundKit.init(rawValue:)) ?? .soft,
            volume: defaults.object(forKey: Self.volumeKey) as? Double ?? 0.6,
            events: Set(SoundEvent.allCases.filter { defaults.object(forKey: Self.eventKey($0)) as? Bool ?? true }),
            playsInBackground: defaults.object(forKey: Self.backgroundKey) as? Bool ?? false)
    }
}

/// Decides whether a sound plays now. Pure, so the rules can be tested without the audio system.
public enum SoundRules {
    /// The person's own actions play only in the active window. Agent events play in the active window; when the
    /// window is in the background or closed, only with "And when the window is in the background", and a closed
    /// window gives only "done" and "needs you" (never an error).
    public static func shouldPlay(
        _ event: SoundEvent, settings: SoundSettings, windowActive: Bool, windowVisible: Bool
    ) -> Bool {
        guard settings.enabled, settings.events.contains(event) else { return false }
        if windowActive { return true }
        guard event.isAgentEvent, settings.playsInBackground else { return false }
        if !windowVisible { return event != .error }
        return true
    }

    /// A character was added at the end of the draft: the message box's typing sound. Pasting, deleting, and
    /// inserting a snippet are not typing, so they stay silent.
    public static func isTypedCharacter(old: String, new: String) -> Bool {
        new.count == old.count + 1
    }
}

/// Keeps `type` to 25 sounds a second: a sound at least 40 ms after the last one that played.
public struct TypeThrottle: Sendable {
    /// The shortest gap between two typing sounds, in milliseconds.
    public static let minimumGap = 40

    private var last: Int?

    public init() {}

    /// `true` when a sound may play at `millisecond` (any steady clock in milliseconds). Records it when it may.
    public mutating func allow(atMillisecond millisecond: Int) -> Bool {
        if let last, millisecond - last < Self.minimumGap { return false }
        last = millisecond
        return true
    }
}

/// Pitch variants for `type`: seven steps from -3% to +3%, so repeated keys do not sound identical.
public enum SoundPitch {
    public static let factors: [Double] = (0..<7).map { 1 + 0.03 * Double($0 - 3) / 3 }
}
