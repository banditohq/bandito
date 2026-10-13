import BanditoKit
import BanditoL10n
import Foundation

/// The words for each thing that can go wrong while connecting, and how loud it is.
struct PairProblemText: Equatable {
    var title: String?
    var message: String
    /// Someone else may be answering at the address: shown in the danger color, with no "try again" in the way.
    var isAlarm: Bool

    init(_ problem: PairProblem) {
        switch problem {
        case .input(let error):
            self.init(message: Self.text(for: error))
        case .failure(let failure):
            switch failure {
            case .codeRejected: self.init(message: L10n.Ios.Connect.Error.codeRejected)
            case .tooManyAttempts: self.init(message: L10n.Ios.Connect.Error.tooMany)
            case .fingerprintMismatch:
                self.init(title: L10n.Ios.Connect.Error.mismatchTitle, message: L10n.Ios.Connect.Error.mismatch, isAlarm: true)
            case .unreachable: self.init(message: L10n.Ios.Connect.Error.unreachable)
            case .serverOffline: self.init(message: L10n.Ios.Connect.Error.offline)
            case .cloudLimit: self.init(message: L10n.Ios.Connect.Error.cloudLimit)
            case .cloudKey: self.init(title: L10n.Ios.Connect.Error.mismatchTitle, message: L10n.Ios.Connect.Error.cloudKey, isAlarm: true)
            case .cloudUnreachable: self.init(message: L10n.Ios.Connect.Error.cloudUnreachable)
            case .other: self.init(message: L10n.Ios.Connect.Error.generic)
            }
        case .saveKey:
            self.init(message: L10n.Ios.Connect.Error.saveKey)
        }
    }

    private init(title: String? = nil, message: String, isAlarm: Bool = false) {
        self.title = title
        self.message = message
        self.isAlarm = isAlarm
    }

    private static func text(for error: PairInputError) -> String {
        switch error {
        case .notALink: L10n.Ios.Connect.Error.notALink
        case .updateApp: L10n.Ios.Connect.Error.updateApp
        case .badCode: L10n.Ios.Connect.Error.badCode
        case .badFingerprint: L10n.Ios.Connect.Error.badFingerprint
        case .noAddress: L10n.Ios.Connect.Error.noAddress
        case .badAddress: L10n.Ios.Connect.Error.badAddress
        case .badRelay: L10n.Ios.Connect.Error.notALink
        }
    }
}

/// What the scanner may do, from the camera's permission and whether there is a camera at all.
enum CameraAccess: Equatable {
    /// Not asked yet: the screen explains why, and asks when the person taps.
    case notAsked
    case allowed
    /// Refused (or restricted): the way out is Settings, or another way to connect.
    case denied
    /// No camera (the Simulator): the other two ways are the only ones.
    case unavailable

    enum Status {
        case notDetermined, restricted, denied, authorized
    }

    static func from(status: Status, hasCamera: Bool) -> CameraAccess {
        guard hasCamera else { return .unavailable }
        switch status {
        case .notDetermined: return .notAsked
        case .authorized: return .allowed
        case .restricted, .denied: return .denied
        }
    }
}

/// The fingerprint as a person compares it: four lines of eight byte pairs.
enum FingerprintLines {
    static func lines(_ fingerprint: String) -> [String] {
        let pairs = PairText.pairs(fingerprint)
        return stride(from: 0, to: pairs.count, by: 8).map { pairs[$0..<min($0 + 8, pairs.count)].joined(separator: ":") }
    }
}

enum PairText {
    static func pairs(_ fingerprint: String) -> [String] {
        let chars = Array(fingerprint.uppercased())
        return stride(from: 0, to: chars.count, by: 2).map { String(chars[$0..<min($0 + 2, chars.count)]) }
    }
}
