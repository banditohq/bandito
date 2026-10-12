import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import SwiftUI

/// What the page area of the browser shows. Decided by `BrowserPageStateRule`.
enum BrowserPageState: Equatable {
    /// The server's browser has no tab (the person closed the last one): a note, and a button for a new tab.
    case noTabs
    /// A blank tab (`about:blank`, `chrome://newtab`): the start page, with the address field in focus.
    case startPage
    /// A page is connected and its first picture has not come yet.
    case waitingForFrame
    /// No picture came for `BrowserPageStateRule.frameTimeout`: the page area says so and offers a retry.
    case frameTimedOut
    /// The picture of the page.
    case showsPage
}

/// Chooses the page state from what the model knows. Pure, so the order of the checks is easy to read and test.
enum BrowserPageStateRule {
    /// How long a page may wait for its first picture before the retry is offered.
    static let frameTimeout: Duration = .seconds(10)

    /// - Parameters:
    ///   - hasTabs: the browser lists at least one tab.
    ///   - url: the address of the shown page; empty while it is not known yet.
    ///   - hasFrame: a picture of the page exists.
    ///   - frameWaitExpired: the wait for the first picture has run out.
    static func make(hasTabs: Bool, url: String, hasFrame: Bool, frameWaitExpired: Bool) -> BrowserPageState {
        guard hasTabs else { return .noTabs }
        // A blank tab is the start page whether or not a picture came: a blank page has no picture to wait for.
        // An address not known yet is not blank: it waits like any page.
        if !url.isEmpty, BrowserTabLabel.isBlank(url) { return .startPage }
        if hasFrame { return .showsPage }
        return frameWaitExpired ? .frameTimedOut : .waitingForFrame
    }
}

/// The addresses the person opened on one server, newest first, at most `limit`. Kept in the app's defaults, so the
/// start page can offer them before the server has any history to show.
enum BrowserRecentAddresses {
    static let limit = 8

    static func key(serverKey: String) -> String {
        "browser.recent.\(serverKey)"
    }

    static func list(serverKey: String, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key(serverKey: serverKey)) ?? []
    }

    /// Records `url` as the newest address. Only web addresses are kept: a blank page or a browser page is no address
    /// worth coming back to.
    static func remember(_ url: String, serverKey: String, defaults: UserDefaults = .standard) {
        let current = list(serverKey: serverKey, defaults: defaults)
        let next = recording(url, into: current)
        guard next != current else { return }
        defaults.set(next, forKey: key(serverKey: serverKey))
    }

    /// The list with `url` first and no repeats, cut to `limit`. A non-web address leaves the list as it is.
    static func recording(_ url: String, into list: [String]) -> [String] {
        guard isWebAddress(url) else { return list }
        return Array(([url] + list.filter { $0 != url }).prefix(limit))
    }

    static func isWebAddress(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}

/// The browser has no tab: says so, and offers a new one (⌘T is the same action, in the keymap).
struct BrowserNoTabsView: View {
    let onNewTab: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            VStack(spacing: 6) {
                Text(L10n.Browser.noTabsTitle)
                    .font(BanditoFont.text(size: 14, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Browser.noTabsHint)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button(L10n.Browser.newTab, action: onNewTab)
                .banditoButton(.signal())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A new tab. The address field above has the focus; below it, the addresses opened recently on this server and the
/// tabs agents opened.
struct BrowserStartPageView: View {
    let recent: [String]
    let agentTabs: [BrowserTab]
    let onOpenAddress: (String) -> Void
    let onSelectTab: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(L10n.Browser.startHint)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(L10n.Browser.startRecent)
                        .padding(.bottom, 4)
                    if recent.isEmpty {
                        Text(L10n.Browser.startNoRecent)
                            .font(BanditoFont.text(size: 12.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    ForEach(recent, id: \.self) { url in
                        Button {
                            onOpenAddress(url)
                        } label: {
                            let host = BrowserTabLabel.domain(of: url)
                            StartRow(title: host.isEmpty ? url : host, subtitle: url)
                        }
                        .banditoButton(.row(cornerRadius: 11))
                    }
                }
                if !agentTabs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(L10n.Browser.startAgentTabs)
                            .padding(.bottom, 4)
                        ForEach(agentTabs) { tab in
                            let label = BrowserTabLabel.make(title: tab.title, url: tab.url, newTabTitle: L10n.Browser.newTab)
                            Button {
                                onSelectTab(tab.id)
                            } label: {
                                StartRow(title: label.title, subtitle: tab.url)
                            }
                            .banditoButton(.row(cornerRadius: 11))
                        }
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One row of the start page: a title, and the address under it.
private struct StartRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Text(subtitle)
                .font(BanditoFont.text(size: 11.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

/// The page sent no picture in time: says so, and offers to connect the picture again.
struct BrowserFrameTimedOutView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(L10n.Browser.frameTimeoutTitle)
                .font(BanditoFont.text(size: 14, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Button(L10n.Browser.frameTimeoutRetry, action: onRetry)
                .banditoButton(.signal())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
