import BanditoKit
import Foundation
import Observation
import UIKit

/// Why the connect screen shows an error, as data: the words are chosen by the view (`PairProblemText`).
enum PairProblem: Equatable {
    case input(PairInputError)
    case failure(PairFailure)
    /// The Keychain refused the token: the device was disconnected again on the server.
    case saveKey
    /// The server shares a certificate or key with one already here, but is not that server.
    case differentServer
}

/// Where a link came from. Every one is shown and confirmed before anything is sent (a code on a poster, or a link
/// from a web page or a message, cannot connect the phone to a server unasked); the screen words a scan as a code.
enum LinkOrigin {
    case scan, paste, url
}

/// The state of the "Connect a server" screen: what is shown, and the pairing in flight. One pairing at a time.
@MainActor
@Observable
final class PairModel {
    enum Phase: Equatable {
        /// The scanner, the paste button and the way to type an address.
        case choose
        case manual
        /// A link that came from outside: the server's name and addresses, and a button.
        case confirmLink(PairRequest, origin: LinkOrigin)
        /// An address typed without a fingerprint: the one the server presents, to compare with the Mac's.
        case trust(PairRequest, fingerprint: String)
        case working
        case done(serverID: UUID, name: String, route: ConnectionRoute?)
        case failed(PairProblem, back: Back)
    }

    /// Where "Try again" goes.
    enum Back: Equatable {
        case choose, manual
    }

    private(set) var phase: Phase
    /// A Mac's sign-in code (`bandito://join`) was scanned or pasted here: it is not a server, so the account takes it.
    var onJoin: (@MainActor (JoinTicket) -> Void)?
    let session: ServerSession
    private let redeem: @Sendable (PairRequest, String?, String) async throws -> PairedDevice
    private let probe: @Sendable (DirectHost) async -> String?
    private let revoke: @Sendable (PairedDevice) async -> Void
    private let deviceName: String
    private var task: Task<Void, Never>?
    /// The last scanned text that was not a link, and when: the camera sees the same code many times a second.
    private var lastIgnored: (text: String, at: Date)?

    init(
        session: ServerSession, startsOnTypedForm: Bool = false, deviceName: String = UIDevice.current.name,
        redeem: @escaping @Sendable (PairRequest, String?, String) async throws -> PairedDevice = { request, fingerprint, name in
            try await DevicePairing.redeem(request, fingerprint: fingerprint, deviceName: name)
        },
        probe: @escaping @Sendable (DirectHost) async -> String? = { await FingerprintProbe.fetch(host: $0) },
        revoke: @escaping @Sendable (PairedDevice) async -> Void = { await DevicePairing.revoke($0) }
    ) {
        self.session = session
        phase = startsOnTypedForm ? .manual : .choose
        self.deviceName = deviceName
        self.redeem = redeem
        self.probe = probe
        self.revoke = revoke
    }

    var isWorking: Bool { phase == .working }

    // MARK: Input

    /// A text that may hold a link: a scanned QR code, the clipboard, or a `bandito://pair` URL opened from outside.
    /// While a pairing runs, or an answer waits for the person, more of them are ignored.
    func submitLink(_ text: String, origin: LinkOrigin) {
        switch phase {
        case .choose, .manual, .failed: break
        case .confirmLink, .trust, .working, .done: return
        }
        if let ticket = JoinTicket.find(in: text), let onJoin {
            onJoin(ticket)
            return
        }
        if origin == .scan, !PairInput.containsLink(text) {
            // Some other QR code: said once, not at camera speed.
            if let last = lastIgnored, last.text == text, Date().timeIntervalSince(last.at) < 3 { return }
            lastIgnored = (text, Date())
        }
        do {
            // Whatever its way in, a link is shown first: the name and the addresses it brings, and one button.
            phase = .confirmLink(try PairInput.parseLink(text), origin: origin)
        } catch let error as PairInputError {
            phase = .failed(.input(error), back: .choose)
        } catch {
            phase = .failed(.failure(.other), back: .choose)
        }
    }

    func showManual() {
        guard case .choose = phase else { return }
        phase = .manual
    }

    func backToChoose() {
        task?.cancel()
        task = nil
        phase = .choose
    }

    /// Takes what was typed. With a fingerprint it connects; without, it asks the server for it and shows it.
    func submitManual(address: String, code: String, fingerprint: String) {
        switch phase {
        case .manual, .failed: break
        default: return
        }
        let request: PairRequest
        do {
            request = try PairInput.parseManual(address: address, code: code, fingerprint: fingerprint)
        } catch let error as PairInputError {
            phase = .failed(.input(error), back: .manual)
            return
        } catch {
            phase = .failed(.failure(.other), back: .manual)
            return
        }
        if let pin = request.fingerprint {
            start(request, fingerprint: pin, back: .manual)
            return
        }
        phase = .working
        task?.cancel()
        task = Task { [probe] in
            // Not trusted yet: only the handshake is made, to read the fingerprint. Nothing else is sent.
            guard let host = request.hosts.first.flatMap({ DirectHost.parse($0) }) else {
                self.phase = .failed(.input(.badAddress), back: .manual)
                return
            }
            let seen = await probe(host)
            guard !Task.isCancelled else { return }
            if let seen {
                self.phase = .trust(request, fingerprint: seen)
            } else {
                self.phase = .failed(.failure(.unreachable), back: .manual)
            }
        }
    }

    // MARK: Answers

    /// "Connect" on a link that came from outside.
    func confirmLink() {
        guard case .confirmLink(let request, _) = phase, request.fingerprint != nil || request.isRelayOnly else { return }
        start(request, fingerprint: request.fingerprint, back: .choose)
    }

    /// "They match": the fingerprint the person compared becomes the pin.
    func confirmTrust() {
        guard case .trust(let request, let fingerprint) = phase else { return }
        start(request, fingerprint: fingerprint, back: .manual)
    }

    /// The name the person settled on, after "Connected".
    func finish(name: String) {
        guard case .done(let id, _, _) = phase else { return }
        session.rename(id, to: name)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: Pairing

    private func start(_ request: PairRequest, back: Back) {
        guard request.fingerprint != nil || request.isRelayOnly else { return }
        start(request, fingerprint: request.fingerprint, back: back)
    }

    private func start(_ request: PairRequest, fingerprint: String?, back: Back) {
        phase = .working
        task?.cancel()
        task = Task { [redeem, revoke, deviceName] in
            do {
                let paired = try await redeem(request, fingerprint, deviceName)
                // From here to the end there is no suspension that a cancel could cut: the token is kept or undone.
                do {
                    try self.session.add(paired.config)
                } catch {
                    await revoke(paired)
                    self.phase = .failed((error as? ServerSession.SessionError) == .differentServer ? .differentServer : .saveKey, back: back)
                    return
                }
                self.phase = .done(serverID: paired.config.id, name: paired.config.name, route: paired.route)
            } catch {
                guard !Task.isCancelled else { return }
                if let input = error as? PairInputError {
                    self.phase = .failed(.input(input), back: back)
                } else {
                    var failure = PairFailure.classify(error)
                    // No internet on the phone looks like "no answer"; for a link with the relay it is the relay that is out of reach.
                    if failure == .unreachable, request.relay != nil { failure = .cloudUnreachable }
                    self.phase = .failed(.failure(failure), back: back)
                }
            }
        }
    }

    func tryAgain() {
        guard case .failed(_, let back) = phase else { return }
        phase = back == .manual ? .manual : .choose
    }
}
