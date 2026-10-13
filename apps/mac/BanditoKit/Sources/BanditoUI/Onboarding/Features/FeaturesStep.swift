import BanditoDesign
import BanditoL10n
import SwiftUI

/// Step 2: "What you get". Three live cards — a crew, an approval you can press, the night shift — with arrows and
/// the left and right keys, dots, and a way past them. Nothing advances by itself. Only the card on screen exists, so
/// the two others run no timer and draw no frame.
struct FeaturesStep: View {
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    private var reduceMotion: Bool {
        MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: systemReduceMotion)
    }

    var body: some View {
        let _ = PerfCounters.hit("OnboardingFeaturesStep")
        let card = onboarding.card
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                arrow("chevron.left", label: L10n.Onboarding.Features.previousCard, enabled: card > 0) {
                    onboarding.showCard(card - 1)
                }
                ZStack {
                    FeatureCardView(card: card, reduceMotion: reduceMotion)
                        .id(card)
                        .transition(.opacity)
                }
                .frame(maxWidth: 640)
                .frame(height: 400)
                .banditoAnimation(BanditoMotion.ease, value: card)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    L10n.Onboarding.Features.cardOf(
                        current: String(card + 1), total: String(OnboardingRules.cardCount)))
                arrow("chevron.right", label: L10n.Onboarding.Features.nextCard, enabled: card < OnboardingRules.cardCount - 1) {
                    onboarding.showCard(card + 1)
                }
            }
            HStack {
                // The dots sit under the card; Skip at the right edge keeps the dots centered.
                Color.clear.frame(width: 80, height: 1)
                Spacer(minLength: 0)
                PageDots(count: OnboardingRules.cardCount, current: card) { onboarding.showCard($0) }
                Spacer(minLength: 0)
                Button(L10n.Ios.Onboarding.skip) { onboarding.skipFeatures() }
                    .banditoButton(.link)
                    .fixedSize()
                    .frame(width: 80, alignment: .trailing)
            }
            .frame(maxWidth: 640 + 2 * 54)
        }
        .frame(maxWidth: .infinity)
        .background { arrowKeys(card: card) }
        .onboardingNext(OnboardingNextAction(title: L10n.Common.next, isEnabled: true) { onboarding.nextCard() })
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
        }
        .banditoButton(.icon(size: 40, label: label))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    /// ← and → turn the cards, with no field focused. Hidden buttons carry the shortcuts, so VoiceOver does not see them.
    private func arrowKeys(card: Int) -> some View {
        HStack {
            Button("") { onboarding.showCard(card - 1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(card == 0)
            Button("") { onboarding.showCard(card + 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(card >= OnboardingRules.cardCount - 1)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// The page dots of the cards: the current one is a longer cream pill, the others hairline dots; each one is a button.
private struct PageDots: View {
    let count: Int
    let current: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Button { onSelect(index) } label: {
                    Capsule()
                        .fill(index == current ? Color.Bandito.text : Color.Bandito.lineStrong)
                        .frame(width: index == current ? 20 : 7, height: 7)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    L10n.Onboarding.Features.cardOf(current: String(index + 1), total: String(count)))
                .accessibilityAddTraits(index == current ? .isSelected : [])
            }
        }
    }
}

/// The frame all three cards share: the live picture on top, the title and one line under it, on a surface card.
private struct FeatureCardFrame<Visual: View>: View {
    let title: String
    let text: String
    @ViewBuilder let visual: Visual

    var body: some View {
        let _ = PerfCounters.hit("OnboardingFeatureCard")
        VStack(alignment: .leading, spacing: 0) {
            visual
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(BanditoFont.display(size: 22, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(BanditoFont.text(size: 15, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 18)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.Bandito.surface1))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }
}

/// The picture's panel: a softly lit surface under the live part of a card, the same look on all three.
private struct FeaturePanel<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(22)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.14), Color.Bandito.surface2.opacity(0.0)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    .background(Color.Bandito.surface2.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }
}

/// The card of the number: a switch, so a card that is not shown is not built.
struct FeatureCardView: View {
    let card: Int
    let reduceMotion: Bool

    var body: some View {
        switch card {
        case 1: ApprovalFeatureCard(reduceMotion: reduceMotion)
        case 2: NightFeatureCard(reduceMotion: reduceMotion)
        default: CrewFeatureCard(reduceMotion: reduceMotion)
        }
    }
}

// MARK: - (a) A crew, not a chat

/// The team lineup: four raccoons with their moods (one works, one rests and blinks, one hops for a person, one
/// thinks) and roles. The moods are Core Animation layers of the avatar, so the card needs no timer.
private struct CrewFeatureCard: View {
    let reduceMotion: Bool

    private struct Member: Identifiable {
        let name: String
        let role: String
        let color: AvatarColor
        let face: AvatarFace
        let mood: AvatarMood
        var id: String { name }
    }

    private static var team: [Member] {
        [
            Member(name: "Forge", role: L10n.Ios.Onboarding.Role.builder, color: .peach, face: .chevronDash, mood: .working),
            Member(name: "Scout", role: L10n.Ios.Onboarding.Role.researcher, color: .sky, face: .wink, mood: .idle),
            Member(name: "Watch", role: L10n.Ios.Onboarding.Role.onCall, color: .rose, face: .dots, mood: .needsYou),
            Member(name: "Quill", role: L10n.Ios.Onboarding.Role.docs, color: .sage, face: .carets, mood: .thinking),
        ]
    }

    var body: some View {
        FeatureCardFrame(title: L10n.Ios.Onboarding.Features.Crew.title, text: L10n.Ios.Onboarding.Features.Crew.text) {
            FeaturePanel(tint: AvatarColor.peach.color) {
            HStack(alignment: .center, spacing: 14) {
                ForEach(Self.team) { member in
                    VStack(spacing: 8) {
                        RaccoonAvatar(
                            name: member.name, color: member.color, face: member.face, size: 72,
                            mood: reduceMotion ? .idle : member.mood)
                        Text(member.name)
                            .font(BanditoFont.display(size: 13.5, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        Text(member.role)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            }
        }
    }
}

// MARK: - (b) Nothing risky without you

/// The state of the demo approval: waiting for the person, or allowed (and back to waiting after `holdSeconds`).
enum ApprovalDemoState: Equatable, Sendable {
    case waiting
    case allowed

    /// How long the "Allowed" state stays before the card asks again.
    static let holdSeconds: Double = 2
}

/// An approval card the person can press: "Approve" turns it into a check mark and a green edge, and after two
/// seconds it asks again. "Deny" is shown, as on Welcome, and does nothing here.
private struct ApprovalFeatureCard: View {
    let reduceMotion: Bool
    @State private var state: ApprovalDemoState = .waiting

    private var allowed: Bool { state == .allowed }

    var body: some View {
        FeatureCardFrame(
            title: L10n.Ios.Onboarding.Features.Approval.title, text: L10n.Ios.Onboarding.Features.Approval.text
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(allowed ? Color.Bandito.ok : Color.Bandito.signal)
                        .frame(width: 8, height: 8)
                    // Demo content, not translated (names and a command, as on Welcome).
                    Text("Forge")
                        .font(BanditoFont.display(size: 14, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                    Text(L10n.Ios.Crew.needsYou)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                    Spacer(minLength: 0)
                }
                // Demo content, not translated.
                Text("git push origin main")
                    .font(BanditoFont.mono(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 10) {
                    // Decorative, as on Welcome: not a control here.
                    Text(L10n.Approval.deny)
                        .font(BanditoFont.text(size: 13.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text2)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .overlay(Capsule().stroke(Color.Bandito.lineStrong, lineWidth: 1))
                        .accessibilityHidden(true)
                    Button(action: allow) {
                        ZStack {
                            Text(L10n.Approval.approve)
                                .opacity(allowed ? 0 : 1)
                            Label(L10n.Ios.Onboarding.Features.Approval.allowed, systemImage: "checkmark")
                                .opacity(allowed ? 1 : 0)
                        }
                        .font(BanditoFont.display(size: 13.5, weight: 600))
                        .foregroundStyle(Color.Bandito.bg)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(Capsule().fill(allowed ? Color.Bandito.ok : Color.Bandito.text))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle(reduceMotion: reduceMotion))
                    .disabled(allowed)
                    .accessibilityLabel(allowed ? L10n.Ios.Onboarding.Features.Approval.allowed : L10n.Approval.approve)
                }
                .scaleEffect(allowed && !reduceMotion ? 1.012 : 1)
                .animation(reduceMotion ? nil : BanditoMotion.ease, value: allowed)
            }
            .padding(18)
            .frame(maxWidth: 440)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.Bandito.surface2))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(allowed ? Color.Bandito.ok : Color.Bandito.signal, lineWidth: 1)
                    .animation(reduceMotion ? nil : BanditoMotion.ease, value: allowed)
            )
        }
        .task(id: state) {
            guard state == .allowed else { return }
            try? await Task.sleep(for: .seconds(ApprovalDemoState.holdSeconds))
            if !Task.isCancelled {
                withAnimation(reduceMotion ? nil : BanditoMotion.ease) { state = .waiting }
            }
        }
    }

    private func allow() {
        guard state == .waiting else { return }
        withAnimation(reduceMotion ? nil : BanditoMotion.ease) { state = .allowed }
    }
}

/// The press of a button: a small scale down on the brand's fast curve.
private struct PressScaleStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : BanditoMotion.ease, value: configuration.isPressed)
    }
}

// MARK: - (c) Works while you sleep

/// The night shift as pure values: four events between 22:00 and 08:00, then the morning. The times are minutes after
/// 22:00. A cycle lights the events one by one, turns the moon into the sun, and starts again.
enum NightShift {
    /// Minutes after 22:00 of each event, in order.
    static let eventMinutes: [Int] = [40, 200, 305, 570]
    /// The shift's length: 22:00 to 08:00.
    static let lengthMinutes = 600
    static let firstEventAt: Double = 0.8
    static let stepSeconds: Double = 0.8
    static let morningAt: Double = firstEventAt + stepSeconds * Double(eventMinutes.count) + 0.6
    static let cycleSeconds: Double = morningAt + 3

    /// How far along the strip an event is, 0 to 1.
    static func fraction(ofMinute minute: Int) -> Double {
        min(max(Double(minute) / Double(lengthMinutes), 0), 1)
    }

    /// The state `seconds` into a cycle: how many events are lit, and whether it is morning.
    static func state(at seconds: Double) -> (lit: Int, morning: Bool) {
        let t = seconds.truncatingRemainder(dividingBy: cycleSeconds)
        let lit: Int
        if t < firstEventAt {
            lit = 0
        } else {
            lit = min(Int((t - firstEventAt) / stepSeconds) + 1, eventMinutes.count)
        }
        return (lit, t >= morningAt)
    }

    /// The moments in a cycle at which the state changes, in order, ending with the end of the cycle.
    static let changes: [Double] = (0..<eventMinutes.count).map { firstEventAt + stepSeconds * Double($0) } + [morningAt, cycleSeconds]

    /// Seconds from `seconds` into a cycle to the next change of the state. The card sleeps exactly this long, so it
    /// wakes six times per cycle, not five times a second.
    static func secondsToNextChange(from seconds: Double) -> Double {
        let t = seconds.truncatingRemainder(dividingBy: cycleSeconds)
        let next = changes.first { $0 > t + 0.000_1 } ?? cycleSeconds
        return max(next - t, 0.05)
    }
}

/// The night shift: a strip from 22:00 to 08:00 with its events lighting up, and the moon turning into the sun.
/// Only while the card is on screen and the app is the active one; it sleeps until the next event, never per frame.
private struct NightFeatureCard: View {
    let reduceMotion: Bool

    /// The events lit so far and whether the morning has come.
    @State private var lit = 0
    @State private var morning = false

    var body: some View {
        FeatureCardFrame(title: L10n.Ios.Onboarding.Features.Night.title, text: L10n.Ios.Onboarding.Features.Night.text) {
            FeaturePanel(tint: morning ? AvatarColor.peach.color : AvatarColor.sky.color) {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    Image(systemName: "moon.stars.fill").opacity(morning ? 0 : 1)
                    Image(systemName: "sun.max.fill").opacity(morning ? 1 : 0)
                }
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(morning ? AvatarColor.peach.color : AvatarColor.sky.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
                NightStrip(lit: lit, morning: morning)
                    .frame(height: 46)
                Text(caption)
                    .font(BanditoFont.text(size: 14.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .id(caption)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : BanditoMotion.ease, value: caption)
            }
            }
            .frame(maxWidth: 520)
        }
        .task {
            if reduceMotion {
                lit = NightShift.eventMinutes.count
                morning = true
                return
            }
            var elapsed: Double = 0
            while !Task.isCancelled {
                // Written only when it changes, so the card is rebuilt on each event and on nothing else.
                let next = NightShift.state(at: elapsed)
                if next.lit != lit { lit = next.lit }
                if next.morning != morning { morning = next.morning }
                let wait = NightShift.secondsToNextChange(from: elapsed)
                try? await Task.sleep(for: .seconds(wait))
                elapsed += wait
                // A hidden app waits at the end of the cycle without drawing: the strip is not seen anyway.
                while !Task.isCancelled && !AppActivity.isActive {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// The line under the strip: the shift's start, then the latest event, then the morning.
    private var caption: String {
        if morning { return L10n.Ios.Onboarding.Features.Night.morning }
        switch lit {
        case 0: return L10n.Ios.Onboarding.Features.Night.start
        case 1: return L10n.Ios.Onboarding.Features.Night.event1
        case 2: return L10n.Ios.Onboarding.Features.Night.event2
        case 3: return L10n.Ios.Onboarding.Features.Night.event3
        default: return L10n.Ios.Onboarding.Features.Night.event4
        }
    }
}

/// The strip itself: a hairline with the events as dots (lit ones in green), the hours at both ends. Only colors
/// change between the states; the geometry is set once.
private struct NightStrip: View {
    let lit: Int
    let morning: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(morning ? Color.Bandito.text3 : Color.Bandito.lineStrong)
                    .frame(width: width, height: 4)
                    .offset(y: 10)
                ForEach(Array(NightShift.eventMinutes.enumerated()), id: \.offset) { index, minute in
                    Circle()
                        .fill(index < lit ? Color.Bandito.ok : Color.Bandito.bg)
                        .overlay(Circle().stroke(index < lit ? Color.Bandito.ok : Color.Bandito.text3, lineWidth: 1.5))
                        .frame(width: 12, height: 12)
                        .offset(x: width * NightShift.fraction(ofMinute: minute) - 6, y: 6)
                }
                HStack {
                    Text(L10n.Ios.Onboarding.Features.Night.from)
                    Spacer(minLength: 0)
                    Text(L10n.Ios.Onboarding.Features.Night.to)
                }
                .font(BanditoFont.mono(size: 11, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .offset(y: 26)
                .frame(width: width)
            }
        }
        .accessibilityHidden(true)
    }
}
