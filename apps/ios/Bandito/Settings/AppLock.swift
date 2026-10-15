import BanditoDesign
import BanditoL10n
@preconcurrency import LocalAuthentication
import Observation
import SwiftUI

/// When the Face ID lock asks again: only when the lock is on and Bandito was away for at least the timeout.
enum AppLockPolicy {
    static func requiresUnlock(enabled: Bool, backgroundedAt: Date, returnedAt: Date, timeout: LockTimeout) -> Bool {
        enabled && returnedAt.timeIntervalSince(backgroundedAt) >= timeout.interval
    }
}

/// Whether the lock screen covers Bandito. Closed at launch when the lock is on, and again on a return after the timeout.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked: Bool
    private var backgroundedAt: Date?

    /// `lockedAtLaunch`: the setting read when the app is made. A link or a shared task can arrive before the first
    /// `.task` runs; a lock that opened closed only there let them through on a cold start.
    init(lockedAtLaunch: Bool = false) {
        isLocked = lockedAtLaunch
    }

    /// At launch: the lock starts closed when it is on.
    func start(enabled: Bool) {
        isLocked = enabled
    }

    /// Called on every scene phase change. `now` is a parameter so the timeout can be tested.
    func scenePhaseChanged(to phase: ScenePhase, enabled: Bool, timeout: LockTimeout, now: Date = .now) {
        switch phase {
        case .background:
            backgroundedAt = backgroundedAt ?? now
        case .active:
            if let since = backgroundedAt,
               AppLockPolicy.requiresUnlock(enabled: enabled, backgroundedAt: since, returnedAt: now, timeout: timeout) {
                isLocked = true
            }
            backgroundedAt = nil
        default:
            // Inactive is the system's own sheet (Face ID itself, the app switcher): it does not start the clock.
            break
        }
    }

    func unlock() {
        isLocked = false
    }
}

/// Face ID, or the passcode when there is no Face ID. A protocol, so the lock flow can be tested without a sensor.
@MainActor
protocol BiometricAuthenticating {
    /// Whether the owner can be checked at all: Face ID is set up, or at least a passcode is.
    var isAvailable: Bool { get }

    /// Asks the owner once. True only when the check passed.
    func authenticate(reason: String) async -> Bool
}

/// LocalAuthentication with the device-owner policy: Face ID first, the passcode as the fallback.
struct DeviceAuthenticator: BiometricAuthenticating {
    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async -> Bool {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// The cover shown while the lock is closed: the raccoon, the title and one button. It asks once as it appears.
struct LockScreen: View {
    let onUnlock: () async -> Void

    var body: some View {
        VStack(spacing: BanditoSpace.s5) {
            Spacer()
            Image("Raccoon")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            Text(L10n.Ios.Settings.Security.lockedTitle)
                .font(BanditoFont.display(size: 24, weight: 700))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Spacer()
            Button(L10n.Ios.Settings.Security.unlock) {
                Task { await onUnlock() }
            }
            .buttonStyle(SignalButtonStyle())
        }
        .padding(BanditoSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg.ignoresSafeArea())
        .task { await onUnlock() }
    }
}
