import AppKit
import SwiftUI

/// Settings that reach the daemon's `server.json`.
struct AdvancedSettingsView: View {
    let model: SissyModel

    @State private var revealToken = false

    var body: some View {
        Form {
            Section("Bearer token") {
                HStack(spacing: 8) {
                    if revealToken {
                        TextField("Token", text: .constant(model.preferences.authToken))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                    } else {
                        SecureField("Token", text: .constant(model.preferences.authToken))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                    }
                    Button(revealToken ? "Hide" : "Reveal") { revealToken.toggle() }
                    Button("Copy") { copyToken() }
                }
                Text(
                    "The paired device must carry the same token or its handshake is rejected "
                        + "without a visible error. Rotate it from the Device tab, which "
                        + "reprovisions the device in the same step."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.preferences.authToken, forType: .string)
    }
}
