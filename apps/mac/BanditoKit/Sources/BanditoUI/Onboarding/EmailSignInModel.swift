import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// Sign-in by email code: ask for a code, then type or paste the six digits. A complete code is checked at once.
@MainActor
@Observable
final class EmailSignInModel {
    enum Phase: Equatable {
        case address
        case code
    }

    /// Bound to the email field.
    var email = ""
    private(set) var phase: Phase = .address
    private(set) var code = SixDigitCode()
    private(set) var errorText: String?
    private(set) var isBusy = false
    private(set) var signedIn: Session?
    private(set) var cooldown = ResendCooldown()

    @ObservationIgnored private let service: SignInService

    init(service: SignInService) {
        self.service = service
    }

    /// Asks the server for a code to `email`. A malformed address is refused here, without a request.
    func sendCode(now: Date) async {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard EmailAddressCheck.isPlausible(address) else {
            errorText = L10n.Onboarding.Account.invalidEmail
            return
        }
        isBusy = true
        errorText = nil
        defer { isBusy = false }
        do {
            try await service.emailStart(email: address)
            email = address
            phase = .code
            code = SixDigitCode()
            cooldown.markSent(at: now)
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }

    /// "Send a new code": allowed once the cooldown has passed.
    func resend(now: Date) async {
        guard cooldown.remaining(now: now) == 0 else { return }
        await sendCode(now: now)
    }

    /// One box was typed into, or a paste landed in box `index`. A complete code is sent to be checked.
    func enter(_ text: String, at index: Int) async {
        errorText = nil
        if code.input(text, at: index) {
            await verify()
        }
    }

    /// Checks the entered code. A wrong code clears the boxes so the person can try again.
    func verify() async {
        guard phase == .code, !isBusy, code.isComplete else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            signedIn = try await service.emailVerify(email: email, code: code.value)
        } catch {
            code = SixDigitCode()
            errorText = SignInMessages.text(for: error)
        }
    }

    /// Empties one box, for example when the person deletes its digit.
    func clearBox(at index: Int) {
        code.clear(at: index)
        errorText = nil
    }

    /// "Another email": back to the address field, with the code cleared.
    func changeEmail() {
        phase = .address
        code = SixDigitCode()
        errorText = nil
    }
}
