import BanditoDesign
import BanditoKit
import SwiftUI

/// Raccoon avatar: a rounded tile in an agent color, the dark mask and a face on it.
/// Without explicit `color` / `face`, both come from a stable hash of `name`.
/// `mood` animates the face (blinking, scanning, hopping…); with Reduce Motion it stays at rest.
public struct RaccoonAvatar: View {
    public let name: String
    public let color: AvatarColor?
    public let face: AvatarFace
    public let size: CGFloat
    public let mood: AvatarMood
    /// A custom tile color as `#RRGGBB`, used instead of `color` when it is valid.
    public let customHex: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    /// The avatar is inside the part of a scroll view that shows (see `AvatarPresence`).
    @State private var onScreen = true
    /// The Core Animation layers of the moving mood are in a window and show.
    @State private var layerShown = false
    /// Repeating motion stands still: Reduce Motion, or "Less" / "Off" in settings.
    private var still: Bool { reduceMotion || !MotionLevel(stored: motionLevel).allowsRepeatingMotion }
    /// No frames are asked for while the avatar is scrolled out of view, or (a sleeping one) while the window is not
    /// the active one: nobody sees the "z" rise.
    private var paused: Bool {
        AvatarSleepPolicy.paused(mood: mood, still: still, onScreen: onScreen, windowActive: scenePhase == .active)
    }

    /// - Parameters:
    ///   - name: Agent name; also the seed for the automatic color and face and for the rhythm.
    ///   - color: Tile color, or `nil` to derive it from `name`.
    ///   - face: Face on the mask, or `.auto` to derive it from `name`.
    ///   - size: Edge of the square tile in points.
    ///   - mood: Expression; `.idle` blinks.
    ///   - customHex: Tile color as `#RRGGBB`; wins over `color` when valid.
    public init(
        name: String, color: AvatarColor? = nil, face: AvatarFace = .auto, size: CGFloat = 40,
        mood: AvatarMood = .idle, customHex: String? = nil
    ) {
        self.name = name
        self.color = color
        self.face = face
        self.size = size
        self.mood = mood
        self.customHex = customHex
    }

    public var body: some View {
        let resolved = AvatarResolver.resolve(name: name, color: color, face: face)
        let tint = customHex.flatMap(AvatarHex.value).map { Color(hex: $0) } ?? resolved.color.color
        let phase = AvatarPose.phase(for: name)
        ZStack {
            // One frame drawn with the window. While the mood moves, Core Animation draws the avatar instead (see
            // `LayerMotion`): the frame stays only where no layer can show (a picture made of the view).
            RaccoonFace(
                resolved: resolved, tint: tint,
                pose: AvatarPose.make(
                    mood: mood, time: Date().timeIntervalSinceReferenceDate, phase: phase, reduceMotion: still),
                size: size)
                .opacity(!still && layerShown ? 0 : 1)
            #if os(macOS)
            // The layers stay while the avatar scrolls away and back; only their animation stops (`running`), so a
            // scroll of the sidebar makes and drops no views.
            if !still {
                AvatarMotion(
                    spec: AvatarMotionSpec(
                        body: .raccoon(resolved), tintKey: customHex ?? resolved.color.rawValue, size: size, mood: mood,
                        phase: phase),
                    tint: tint, picture: nil, running: !paused,
                    onShown: { shown in if layerShown != shown { layerShown = shown } })
            }
            #endif
        }
        .frame(width: size, height: size)
        .avatarPresence($onScreen)
        // Decorative: the agent name is always shown next to the avatar.
        .accessibilityHidden(true)
    }
}

/// Agent avatar: `RaccoonAvatar` with color and face derived from the agent name.
public struct AgentAvatar: View {
    /// Agent name; seeds the automatic color and face.
    public var name: String
    /// Edge of the square tile in points.
    public var size: CGFloat
    /// Expression of the face.
    public var mood: AvatarMood

    public init(name: String, size: CGFloat = 40, mood: AvatarMood = .idle) {
        self.name = name
        self.size = size
        self.mood = mood
    }

    public var body: some View {
        RaccoonAvatar(name: name, size: size, mood: mood)
    }
}

/// Tells an avatar whether it is inside the part of a scroll view that shows (macOS 15 and later), so that one scrolled
/// out of view asks for no frames. The state is written only when the answer changes, a few times per scroll at most.
/// Before macOS 15, and outside a scroll view, the avatar counts as on screen.
private struct AvatarPresence: ViewModifier {
    @Binding var onScreen: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { visible in
                if visible != onScreen { onScreen = visible }
            }
        } else {
            content
        }
    }
}

extension View {
    func avatarPresence(_ onScreen: Binding<Bool>) -> some View {
        modifier(AvatarPresence(onScreen: onScreen))
    }
}

/// When an avatar needs a new frame: 30 times a second while its mood moves, and not at all in between. An idle
/// raccoon blinks for a third of a second every five seconds, so it is drawn about seven times per blink instead of
/// a hundred times; a row of agents in the sidebar costs next to nothing.
struct AvatarSchedule: TimelineSchedule {
    let mood: AvatarMood
    let phase: Double
    let paused: Bool

    static let frameInterval: TimeInterval = 1.0 / 30
    /// A sleeping avatar moves slowly (a "z" rises in 2.6 s) and is drawn all the time, so it gets fewer frames.
    static let sleepingInterval: TimeInterval = 1.0 / 12

    /// The time between two frames of `mood`.
    static func interval(for mood: AvatarMood) -> TimeInterval {
        mood == .sleeping ? sleepingInterval : frameInterval
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        // Paused, or the system asks for few updates (low power, window hidden): one frame, then nothing.
        if paused || mode == .lowFrequency {
            var done = false
            return AnyIterator {
                if done { return nil }
                done = true
                return startDate
            }
        }
        let window = AvatarPose.activeWindow(for: mood)
        let interval = Self.interval(for: mood)
        var next = startDate
        return AnyIterator {
            let date = next
            next = Self.after(date, window: window, phase: phase, interval: interval)
            return date
        }
    }

    /// The frame after `date`: the next tick inside the moving part of the cycle, or the start of the next one.
    static func after(
        _ date: Date, window: (period: Double, start: Double, end: Double)?, phase: Double,
        interval: TimeInterval = frameInterval
    ) -> Date {
        let tick = date.addingTimeInterval(interval)
        guard let window else { return tick }
        func inside(_ d: Date) -> Bool {
            let p = (d.timeIntervalSinceReferenceDate + phase).truncatingRemainder(dividingBy: window.period) / window.period
            return p >= window.start && p <= window.end
        }
        // Inside the moving part, and the first frame after it (so the pose comes back to rest), are drawn.
        if inside(tick) || inside(date) { return tick }
        let t = tick.timeIntervalSinceReferenceDate + phase
        let position = t.truncatingRemainder(dividingBy: window.period) / window.period
        // Jump to the start of the next moving part (this cycle's, or the next cycle's).
        let cycleStart = t - position * window.period
        var start = cycleStart + window.start * window.period
        if start <= t { start += window.period }
        return Date(timeIntervalSinceReferenceDate: start - phase)
    }
}
