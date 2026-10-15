import BanditoKit
import Foundation
import Observation
import UIKit
import os

/// Push on the phone (docs/IOS_APP.md, Push): asks Apple for a token while notifications are allowed, gives it to the
/// cloud (`PushDevice`), and tells the connected servers where to send (`PushRegistrar`).
@MainActor
final class PushCoordinator {
    static let shared = PushCoordinator()
    private static let log = Logger(subsystem: "dev.bandito", category: "push")

    let device: PushDevice
    private(set) var registrar: PushRegistrar?
    /// Whether the system lets Bandito show notifications. Nothing is asked of Apple, the cloud or a server while it is off.
    private(set) var isAllowed = false
    private var started = false
    /// Asks the system for a token. Replaced in tests.
    var registerForRemote: @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }

    init(device: PushDevice = PushDevice()) {
        self.device = device
    }

    /// Wires push to the servers and the settings. Call once, when the app's screens start (not for the demo world).
    func start(session: ServerSession, settings: IOSSettings, arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard !started else { return }
        started = true
        #if DEBUG
        PushDebug.installTestKey(from: arguments, keychain: .shared)
        let keep: Set<String> = [PushDebug.testServerRef]
        #else
        let keep: Set<String> = []
        #endif
        let registrar = PushRegistrar(
            keychain: .shared, device: device, servers: { session.servers }, isLoaded: { session.loaded },
            allowed: { [weak self] in self?.isAllowed ?? false },
            kinds: {
                PushKinds.kinds(
                    approvals: settings.notifyApprovals, answers: settings.notifyAnswers, errors: settings.notifyErrors)
            },
            language: { PushKinds.language(from: Locale.preferredLanguages.first) }, keepRefs: keep)
        self.registrar = registrar
        device.onHandleChange = { [weak self] in
            self?.registrar?.requestReconcile()
            #if DEBUG
            self?.writeDebug()
            #endif
        }
        session.forgetPush = { [weak registrar] server, unregister in
            await registrar?.forgotten(server, unregister: unregister)
        }
        observe(session: session, settings: settings)
        Task { await refreshPermission() }
    }

    /// Looks at the servers' connections and the notification switches; a change asks for a pass.
    private func observe(session: ServerSession, settings: IOSSettings) {
        withObservationTracking {
            _ = session.loaded
            for server in session.servers {
                _ = server.state
                _ = server.info?.features
            }
            _ = settings.notifyApprovals
            _ = settings.notifyAnswers
            _ = settings.notifyErrors
        } onChange: { [weak self] in
            Task { @MainActor in
                // Armed again first: a change while the pass runs is seen.
                self?.observe(session: session, settings: settings)
                self?.registrar?.requestReconcile()
            }
        }
    }

    /// The app came to the front: the permission and the language may have changed in the system's Settings.
    func appBecameActive() {
        Task { await refreshPermission() }
    }

    /// The person allowed notifications just now (any of the places that ask).
    func permissionGranted() async {
        await refreshPermission()
    }

    private func refreshPermission() async {
        let permission = await SystemNotifications.permission()
        isAllowed = permission == .allowed
        if isAllowed {
            // Apple advises asking at every launch: the token can change.
            registerForRemote()
        }
        await registrar?.reconcile()
        #if DEBUG
        writeDebug()
        #endif
    }

    func tokenReceived(_ data: Data) {
        Task {
            await device.tokenReceived(data)
            await registrar?.reconcile()
            #if DEBUG
            writeDebug()
            #endif
        }
    }

    /// Apple refused a token (no network, no entitlement, an unsigned build). Quiet: the next launch asks again.
    func registrationFailed(_ error: Error) {
        Self.log.error("no push token this time: \((error as NSError).code, privacy: .public)")
    }

    #if DEBUG
    private func writeDebug() {
        PushDebug.write(token: device.token, handle: device.handle, env: PushEnvironment.current(), allowed: isAllowed)
    }
    #endif
}
