import BanditoDesign
import BanditoKit
import BanditoL10n
import CoreGraphics
import SwiftUI

/// The nickname and avatar colour of the signed-in account, kept on this Mac per user id
/// (`profile.nickname.<id>`, `profile.avatarColor.<id>`). Nothing is stored while nobody is signed in.
@MainActor
@Observable
final class ProfileStore {
    private(set) var userID: String?
    private(set) var nickname = ""
    private(set) var colorIndex = 0
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func nicknameKey(_ userID: String) -> String { "profile.nickname.\(userID)" }
    static func colorKey(_ userID: String) -> String { "profile.avatarColor.\(userID)" }

    /// Loads the values of this account. Nil means nobody is signed in: the values are reset.
    func bind(userID: String?) {
        guard userID != self.userID else { return }
        self.userID = userID
        guard let userID else {
            nickname = ""
            colorIndex = 0
            return
        }
        nickname = defaults.string(forKey: Self.nicknameKey(userID)) ?? ""
        colorIndex = Self.validColor(defaults.object(forKey: Self.colorKey(userID)) as? Int)
    }

    /// Saves the nickname. Blank removes it, so the account name shows again.
    func setNickname(_ value: String) {
        guard let userID else { return }
        let trimmed = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        nickname = trimmed
        defaults.set(trimmed.isEmpty ? nil : trimmed, forKey: Self.nicknameKey(userID))
    }

    func setColorIndex(_ index: Int) {
        guard let userID, AvatarColor.allCases.indices.contains(index) else { return }
        colorIndex = index
        defaults.set(index, forKey: Self.colorKey(userID))
    }

    /// Removes this account's nickname and colour from this Mac (sign-out, reset). The account stays bound.
    func clear() {
        guard let userID else { return }
        defaults.removeObject(forKey: Self.nicknameKey(userID))
        defaults.removeObject(forKey: Self.colorKey(userID))
        nickname = ""
        colorIndex = 0
    }

    private static func validColor(_ stored: Int?) -> Int {
        guard let stored, AvatarColor.allCases.indices.contains(stored) else { return 0 }
        return stored
    }
}

/// Names shown on the profile.
enum ProfileNames {
    /// The name the profile shows: the nickname the person set, else the name on the account, else the e-mail.
    static func displayName(nickname: String?, account: AccountUser?) -> String? {
        [nickname, account?.name, account?.email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

extension AvatarColor {
    /// The colour at a stored index. Out-of-range indexes fall back to the first colour.
    static func at(_ index: Int) -> AvatarColor {
        allCases.indices.contains(index) ? allCases[index] : allCases[0]
    }
}

/// A round avatar: the profile photo when there is one, else the first letter of the name on the chosen colour, or a
/// person when nobody is signed in.
struct ProfileAvatar: View {
    /// The name the avatar stands for. Nil shows the generic person.
    let name: String?
    let color: AvatarColor
    /// The profile photo, if this Mac has one.
    var picture: CGImage?
    var size: CGFloat = 28

    var body: some View {
        Circle()
            .fill(initial == nil ? Color.Bandito.surface3 : color.color)
            .frame(width: size, height: size)
            .overlay {
                if let picture {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                } else if let initial {
                    Text(initial)
                        .font(BanditoFont.font(size: size * 0.42, weight: 600))
                        .foregroundStyle(Color.Bandito.bg)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
            .accessibilityHidden(true)
    }

    private var initial: String? {
        guard let first = name?.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        return String(first).uppercased()
    }
}
