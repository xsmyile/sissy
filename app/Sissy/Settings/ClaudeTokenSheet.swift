import SwiftUI

/// What the token row and its sheet say.
///
/// Every line names the CLI command that mints the token, because the whole
/// feature is unreachable without it and there is nowhere else a user would
/// learn it.
enum ClaudeTokenCopy {
    static let rowTitle = "Claude token"
    static let set = "Set token…"
    static let replace = "Replace…"
    static let remove = "Remove"

    static let usingCLI =
        "Without one, Sissy reads Claude Code's own keychain item — and macOS asks again "
        + "every time the CLI refreshes its login, which is roughly hourly."
    static let usingManaged =
        "Sissy reads the token you gave it, from a keychain item of its own. Claude Code's "
        + "item is not touched, so macOS stops asking."

    static let sheetTitle = "Give Sissy a Claude token"
    static let instructions =
        "Run claude setup-token in a terminal and paste what it prints. It is a long-lived "
        + "token for your own subscription; Sissy stores it in its own keychain item, never "
        + "logs it and never includes it in diagnostics or an export."
    static let field = "Token"
    static let save = "Check and save"
    static let cancel = "Cancel"

    /// Said before a token is sent anywhere, so an obvious mis-paste — an API
    /// key, a whole shell line — is named rather than spent on a request. A
    /// hint and not a block: only the endpoint can actually say, and a prefix
    /// hardcoded here must never become the reason a valid token is refused.
    static let shapeHint =
        "That does not look like a setup-token — they begin with "
        + ClaudeTokenStore.tokenPrefix + ". You can still try it."

    static let emptyPaste = "Nothing was pasted."

    static func saveFailed(_ error: Error) -> String {
        guard case ClaudeTokenStoreError.keychain(let status) = error else {
            return "The token could not be saved."
        }
        return "The keychain refused to store the token (OSStatus \(status))."
    }

    /// What the endpoint's answer means, worded as the next thing to do.
    static func outcome(_ verification: ClaudeTokenVerification) -> String {
        switch verification {
        case .accepted:
            return "Accepted."
        case .acceptedWithoutWindows:
            return "Accepted, but this account publishes no limit windows."
        case .rejected:
            return "The endpoint did not accept that token. Run claude setup-token again "
                + "and paste the new one."
        case .missingScope:
            return "That token was minted without the scope the usage endpoint needs. "
                + "Run claude setup-token again to get one that has it."
        case .rateLimited:
            return "The endpoint is rate-limiting this Mac right now, so the token could "
                + "not be checked. Try again in a few minutes."
        case .failed(let reason):
            return reason
        }
    }
}

/// The paste, and the check that decides whether it is worth keeping.
///
/// The check is not a nicety: `claude setup-token` publishes no expiry and no
/// scope list that Sissy can read, so the endpoint is the only thing that can
/// tell a good token from a bad one. Running it here is what stops a bad paste
/// from becoming gauges that simply never arrive.
struct ClaudeTokenSheet: View {
    let model: SissyModel

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var checking = false
    @State private var outcome: ClaudeTokenVerification?

    private static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ClaudeTokenCopy.sheetTitle).font(.headline)
            Text(ClaudeTokenCopy.instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(ClaudeTokenCopy.field, text: $token)
                .textFieldStyle(.roundedBorder)
                .disabled(checking)

            if let message = hint {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(outcome?.isUsable == true ? .secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(ClaudeTokenCopy.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(ClaudeTokenCopy.save) { check() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || token.isEmpty)
            }
        }
        .padding()
        .frame(width: Self.width)
        // The field holds a live credential, so it does not outlive the sheet
        // even by the length of a SwiftUI state cache.
        .onDisappear { token = "" }
    }

    /// The one line under the field: what the endpoint answered if it has been
    /// asked, and otherwise whether the paste even looks like a token.
    private var hint: String? {
        if let outcome { return ClaudeTokenCopy.outcome(outcome) }
        if token.isEmpty || ClaudeTokenStore.looksLikeToken(token) { return nil }
        return ClaudeTokenCopy.shapeHint
    }

    private func check() {
        checking = true
        outcome = nil
        Task {
            let verdict = await model.engine.setClaudeToken(token)
            checking = false
            if verdict.isUsable {
                dismiss()
            } else {
                outcome = verdict
            }
        }
    }
}
