import BanditoDesign
import BanditoL10n
import SwiftUI
import UIKit

/// The three live cards of "What you get": a crew, an approval, the night shift. Each card runs its small motion only
/// while it is the card on screen (`isActive`); the motion is state that changes a few times a second, never per frame.
struct FeatureCarousel: View {
    @Binding var card: Int
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: BanditoSpace.s4) {
            TabView(selection: $card) {
                CrewFeatureCard(reduceMotion: reduceMotion)
                    .tag(0)
                ApprovalFeatureCard(isActive: card == 1, reduceMotion: reduceMotion)
                    .tag(1)
                NightFeatureCard(isActive: card == 2, reduceMotion: reduceMotion)
                    .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .accessibilityElement(children: .contain)

            PageDots(count: OnboardingRules.cardCount, current: card)
        }
    }
}

/// The page indicator of the cards: the current one in cream, the others in the hairline tone.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: BanditoSpace.s2) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.Bandito.text : Color.Bandito.lineStrong)
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The frame all three cards share: the live picture on top, the title and one line under it, on a surface card.
private struct FeatureCardFrame<Visual: View>: View {
    let title: String
    let text: String
    @ViewBuilder let visual: Visual

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                // The picture sits in the middle of the free space, the copy at the bottom of the card.
                VStack(alignment: .leading, spacing: BanditoSpace.s4) {
                    Spacer(minLength: 0)
                    visual
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: BanditoSpace.s4)
                    Text(title)
                        .font(BanditoFont.display(size: 20, weight: 700))
                        .foregroundStyle(Color.Bandito.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(text)
                        .font(BanditoFont.text(size: 14.5))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(BanditoSpace.s5)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.Bandito.surface1))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
        .padding(.horizontal, BanditoSpace.s5)
        .padding(.vertical, BanditoSpace.s2)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - (a) A crew, not a chat

/// The team lineup: four raccoons with their moods (one blinks and smirks, one hops for a person, one thinks) and roles.
/// Their moods are Core Animation layers of their own (`CrewAvatar`), so the card needs no timer.
struct CrewFeatureCard: View {
    let reduceMotion: Bool

    private struct Member: Identifiable {
        let name: String
        let role: String
        let look: CrewLook
        let mood: AvatarMood
        var id: String { name }
    }

    private static let team: [Member] = [
        Member(name: "Forge", role: L10n.Ios.Onboarding.Role.builder,
               look: CrewLook(color: .peach, face: .chevronDash, customHex: nil), mood: .working),
        Member(name: "Scout", role: L10n.Ios.Onboarding.Role.researcher,
               look: CrewLook(color: .sky, face: .wink, customHex: nil), mood: .idle),
        Member(name: "Watch", role: L10n.Ios.Onboarding.Role.onCall,
               look: CrewLook(color: .rose, face: .dots, customHex: nil), mood: .needsYou),
        Member(name: "Quill", role: L10n.Ios.Onboarding.Role.docs,
               look: CrewLook(color: .sage, face: .carets, customHex: nil), mood: .thinking),
    ]

    var body: some View {
        FeatureCardFrame(title: L10n.Ios.Onboarding.Features.Crew.title, text: L10n.Ios.Onboarding.Features.Crew.text) {
            HStack(alignment: .top, spacing: BanditoSpace.s2) {
                ForEach(Self.team) { member in
                    VStack(spacing: BanditoSpace.s2) {
                        CrewAvatar(name: member.name, look: member.look, mood: reduceMotion ? .idle : member.mood, size: 56)
                        Text(member.name)
                            .font(BanditoFont.display(size: 12.5, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        Text(member.role)
                            .font(BanditoFont.text(size: 11.5))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
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

/// An approval card the person can press: "Allow" turns it into a check mark, a success haptic and a green edge, and
/// after two seconds it asks again. Deny is shown, as in the Mac's demo, and does nothing here.
struct ApprovalFeatureCard: View {
    let isActive: Bool
    let reduceMotion: Bool

    @State private var state: ApprovalDemoState = .waiting

    private var allowed: Bool { state == .allowed }

    var body: some View {
        FeatureCardFrame(
            title: L10n.Ios.Onboarding.Features.Approval.title,
            text: L10n.Ios.Onboarding.Features.Approval.text
        ) {
            VStack(alignment: .leading, spacing: BanditoSpace.s3) {
                HStack(spacing: BanditoSpace.s2) {
                    Circle()
                        .fill(allowed ? Color.Bandito.ok : Color.Bandito.signal)
                        .frame(width: 7, height: 7)
                    Text("Forge")
                        .font(BanditoFont.display(size: 13, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                    Text(L10n.Ios.Crew.needsYou)
                        .font(BanditoFont.text(size: 11.5))
                        .foregroundStyle(Color.Bandito.text3)
                    Spacer(minLength: 0)
                }
                Text("git push origin main")
                    .font(BanditoFont.mono(size: 12.5))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(2)
                    .padding(.horizontal, BanditoSpace.s3)
                    .padding(.vertical, BanditoSpace.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: BanditoSpace.s2) {
                    // Decorative, as on the Mac: not a control here.
                    Text(L10n.Approval.deny)
                        .font(BanditoFont.text(size: 13, weight: 500))
                        .foregroundStyle(Color.Bandito.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .overlay(Capsule().stroke(Color.Bandito.lineStrong, lineWidth: 1))
                        .accessibilityHidden(true)
                    Button(action: allow) {
                        ZStack {
                            Text(L10n.Approval.approve)
                                .opacity(allowed ? 0 : 1)
                            Label(L10n.Ios.Onboarding.Features.Approval.allowed, systemImage: "checkmark")
                                .opacity(allowed ? 1 : 0)
                        }
                        .font(BanditoFont.display(size: 13, weight: 600))
                        .foregroundStyle(Color.Bandito.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Capsule().fill(allowed ? Color.Bandito.ok : Color.Bandito.text))
                    }
                    .buttonStyle(ApprovalPressStyle(reduceMotion: reduceMotion))
                    .disabled(allowed)
                    .accessibilityLabel(allowed ? L10n.Ios.Onboarding.Features.Approval.allowed : L10n.Approval.approve)
                }
                .scaleEffect(allowed && !reduceMotion ? 1.015 : 1)
                .animation(reduceMotion ? nil : BanditoMotion.ease, value: allowed)
            }
            .padding(BanditoSpace.s4)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.Bandito.surface2))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(allowed ? Color.Bandito.ok : Color.Bandito.signal, lineWidth: 1)
                    .animation(reduceMotion ? nil : BanditoMotion.ease, value: allowed)
            )
        }
        .task(id: isActive ? state : .waiting) {
            guard isActive, state == .allowed else { return }
            try? await Task.sleep(for: .seconds(ApprovalDemoState.holdSeconds))
            if !Task.isCancelled {
                withAnimation(reduceMotion ? nil : BanditoMotion.ease) { state = .waiting }
            }
        }
    }

    private func allow() {
        guard state == .waiting else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(reduceMotion ? nil : BanditoMotion.ease) {
            state = .allowed
        }
    }
}

/// The press of the Allow button: a small scale down, on the brand's fast curve.
private struct ApprovalPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : BanditoMotion.ease, value: configuration.isPressed)
    }
}

// MARK: - (c) They work while you sleep

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
}

/// The night shift: a strip from 22:00 to 08:00 with its events lighting up, and the moon turning into the sun.
struct NightFeatureCard: View {
    let isActive: Bool
    let reduceMotion: Bool

    /// The events lit so far and whether the morning has come.
    @State private var lit = 0
    @State private var morning = false

    var body: some View {
        FeatureCardFrame(title: L10n.Ios.Onboarding.Features.Night.title, text: L10n.Ios.Onboarding.Features.Night.text) {
            VStack(alignment: .leading, spacing: BanditoSpace.s4) {
                HStack {
                    ZStack {
                        Image(systemName: "moon.stars.fill")
                            .opacity(morning ? 0 : 1)
                        Image(systemName: "sun.max.fill")
                            .opacity(morning ? 1 : 0)
                    }
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.Bandito.text)
                    .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .frame(height: 26)
                NightStrip(lit: lit, morning: morning)
                    .frame(height: 46)
                Text(caption)
                    .font(BanditoFont.text(size: 13.5))
                    .foregroundStyle(Color.Bandito.text)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .id(caption)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : BanditoMotion.ease, value: caption)
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
            if reduceMotion {
                lit = NightShift.eventMinutes.count
                morning = true
                return
            }
            // A tick every 0.2 s; the state is written only when it changes, so the view re-renders on each event, not
            // on each tick.
            var elapsed: Double = 0
            while !Task.isCancelled {
                let next = NightShift.state(at: elapsed)
                if next.lit != lit { lit = next.lit }
                if next.morning != morning { morning = next.morning }
                try? await Task.sleep(for: .milliseconds(200))
                elapsed += 0.2
            }
        }
    }

    /// The line under the strip: the shift's start, then the latest event, then the morning.
    private var caption: String {
        if morning {
            return L10n.Ios.Onboarding.Features.Night.morning
        }
        switch lit {
        case 0: return L10n.Ios.Onboarding.Features.Night.start
        case 1: return L10n.Ios.Onboarding.Features.Night.event1
        case 2: return L10n.Ios.Onboarding.Features.Night.event2
        case 3: return L10n.Ios.Onboarding.Features.Night.event3
        default: return L10n.Ios.Onboarding.Features.Night.event4
        }
    }
}

/// The strip itself: a hairline with the events as dots (lit ones in sage), the hours at both ends. Only colors change
/// between the states; the geometry is set once.
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
                .font(BanditoFont.mono(size: 11))
                .foregroundStyle(Color.Bandito.text3)
                .offset(y: 26)
                .frame(width: width)
            }
        }
        .accessibilityHidden(true)
    }
}
