import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Where "All changes" goes.
enum WhatsNewLinks {
    static let changelog = URL(string: "https://bandito.dev/changelog")!
}

/// The sheet: loads the notes (kept after the first read), then shows `WhatsNewContent`.
struct WhatsNewSheet: View {
    /// The skipped versions to list below the current one (newest first).
    let skipped: [String]

    @State private var library: ReleaseNotesLibrary?

    var body: some View {
        Group {
            if let library {
                WhatsNewContent(
                    notes: WhatsNewStore.currentVersion.flatMap { library.notes(for: $0) },
                    version: WhatsNewStore.currentVersion ?? "",
                    older: skipped.compactMap { library.notes(for: $0) },
                    preferredLanguages: WhatsNewStore.preferredLanguages)
            } else {
                Color.Bandito.surface2.frame(width: WhatsNewContent.width, height: WhatsNewContent.height)
            }
        }
        .task { library = await WhatsNewLibraryStore.shared.library() }
    }
}

/// The content, with the data handed in (the snapshots and the tests build it without a bundle).
struct WhatsNewContent: View {
    static let width: CGFloat = 560
    static let height: CGFloat = 624

    /// The notes of the version on screen; nil shows a short line and the link.
    let notes: ReleaseNotes?
    let version: String
    /// Skipped versions, newest first, each folded under the current one.
    var older: [ReleaseNotes] = []
    /// The app's languages in order: the notes open in the first one they have.
    let preferredLanguages: [String]
    /// No motion whatever the settings say (the snapshots draw the finished picture).
    var still = false
    /// The sheet's height and the versions open at first: the real sheet is `height` tall with all folded; the
    /// snapshots show the folded list from a taller one.
    var height = WhatsNewContent.height
    var initiallyOpen: Set<String> = []

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    /// The language of the notes on this screen only; nil is the default (the app's language, or English).
    @State private var picked: String?
    @State private var openVersions: Set<String> = []
    @State private var seeded = false

    private var reduced: Bool { still || MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion) }

    private var language: String {
        picked ?? notes?.defaultLanguage(preferred: preferredLanguages) ?? ReleaseNotes.fallbackLanguage
    }

    var body: some View {
        let _ = PerfCounters.hit("WhatsNew.body")
        ZStack {
            Color.Bandito.surface2
            glow
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let notes {
                            ForEach(notes.lines(language: language)) { line in
                                WhatsNewCard(line: line, animate: !reduced)
                            }
                        } else {
                            Text(L10n.WhatsNew.empty)
                                .font(BanditoFont.text(size: 14))
                                .foregroundStyle(Color.Bandito.text2)
                                .padding(.vertical, 20)
                        }
                        if !older.isEmpty { earlier }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.automatic)
                ActionRow {
                    Button(L10n.WhatsNew.allChanges) { openURL(WhatsNewLinks.changelog) }
                        .banditoButton(.quiet())
                    Button(L10n.WhatsNew.continue) { dismiss() }
                        .banditoButton(.signal())
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            }
        }
        .frame(width: Self.width, height: height)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            if !initiallyOpen.isEmpty { openVersions = initiallyOpen }
        }
        .onExitCommand { dismiss() }
        .accessibilityElement(children: .contain)
    }

    /// A soft glow of the signal colour behind the raccoon; one static gradient.
    private var glow: some View {
        RadialGradient(
            colors: [Color.Bandito.signal.opacity(colorScheme == .dark ? 0.16 : 0.12), .clear],
            center: .top, startRadius: 0, endRadius: 320)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                RaccoonLightsHost(reduceMotion: reduced, dark: colorScheme == .dark)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text(L10n.WhatsNew.title(version: version))
                    .font(BanditoFont.display(size: 20, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let date = Self.dateText(notes?.date) {
                    Text(date)
                        .font(BanditoFont.text(size: 12.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 44)
            if notes != nil { languageMenu }
        }
        .padding(.top, 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var languageMenu: some View {
        BanditoSelect(
            selection: Binding(get: { language }, set: { code in if code != picked { picked = code } }),
            sections: [SelectSection(options: ReleaseNotes.languages.compactMap { code in
                L10n.languages.first { $0.code == code }.map {
                    SelectOption(value: code, title: $0.native, subtitle: code.uppercased())
                }
            })],
            label: L10n.WhatsNew.language, placeholder: InterfaceLanguage.nativeName(code: language),
            field: { _ in
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.system(size: 11, weight: .medium))
                        .accessibilityHidden(true)
                    Text(InterfaceLanguage.nativeName(code: language))
                        .font(BanditoFont.text(size: 12, weight: 500))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(0.7)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.Bandito.text)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.Bandito.text.opacity(0.05), in: Capsule())
                .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.12), lineWidth: 1))
            },
            footer: { _ in EmptyView() },
            style: .compact)
    }

    /// The skipped versions, folded: a tap opens the lines of one.
    private var earlier: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.WhatsNew.earlier)
                .font(BanditoFont.text(size: 11.5, weight: 600))
                .foregroundStyle(Color.Bandito.text3)
                .textCase(.uppercase)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            ForEach(older, id: \.version) { entry in
                let isOpen = openVersions.contains(entry.version)
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        if isOpen { openVersions.remove(entry.version) } else { openVersions.insert(entry.version) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                                .foregroundStyle(Color.Bandito.text3)
                                .accessibilityHidden(true)
                            Text(L10n.WhatsNew.olderVersion(version: entry.version))
                                .font(BanditoFont.text(size: 13, weight: 600))
                                .foregroundStyle(Color.Bandito.text2)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(isOpen ? L10n.AgentSheet.advancedExpanded : L10n.AgentSheet.advancedCollapsed)
                    if isOpen {
                        ForEach(entry.lines(language: entry.hasLanguage(language) ? language : ReleaseNotes.fallbackLanguage)) { line in
                            WhatsNewCompactLine(line: line)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    /// "13 October 2026" in the app's language; nil for a bad date.
    static func dateText(_ text: String?) -> String? {
        guard let text, let date = ReleaseNotes.parseDate(text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return DateFormatterCache.shared.string(
            from: date, calendar: calendar, locale: L10n.locale, dateStyle: .long, timeStyle: .none)
    }
}

/// One card: the symbol on the signal tint, the title and one line. It comes in after a short delay by its place
/// (a cascade); the delay is a task of the card, so closing the sheet cancels it. Reduce Motion: there at once.
struct WhatsNewCard: View {
    let line: ReleaseNotes.Line
    let animate: Bool

    @State private var appeared: Bool

    init(line: ReleaseNotes.Line, animate: Bool) {
        self.line = line
        self.animate = animate
        _appeared = State(initialValue: !animate)
    }

    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        let _ = PerfCounters.hit("WhatsNew.card")
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: line.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.signal)
                .frame(width: 38, height: 38)
                .background(Color.Bandito.signal.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(line.title)
                    .font(BanditoFont.text(size: 15, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(line.text)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .background(Color.Bandito.surface1, in: Self.shape)
        .overlay(Self.shape.strokeBorder(Color.Bandito.text.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .banditoAnimation(.easeOut(duration: 0.4), value: appeared)
        .task {
            guard !appeared else { return }
            try? await Task.sleep(for: .milliseconds(140 + 90 * line.id))
            guard !Task.isCancelled else { return }
            appeared = true
        }
    }
}

/// A line of an earlier version: the symbol, the title, the text, small.
private struct WhatsNewCompactLine: View {
    let line: ReleaseNotes.Line

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: line.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.Bandito.signal)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(BanditoFont.text(size: 12.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Text(line.text)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
