import AppKit
import SwiftUI

/// Settings that change what the menu bar and the panel show.
struct GeneralSettingsView: View {
    let model: SissyModel

    private var server: SissyModel.ServerItemSnapshot { model.menuSnapshot.server }

    var body: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    HStack(spacing: 8) {
                        if !server.isEnabled && model.serverIsBusy {
                            ProgressView().controlSize(.small)
                        }
                        if server.requiresApproval {
                            Button("Approve in Login Items") { model.toggleServer() }
                        } else {
                            Toggle("Server", isOn: serverBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!server.isEnabled)
                        }
                    }
                }
                Text(serverCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Claude Code limits", isOn: claudeLimitsBinding)
                Text(
                    "Reads the token Claude Code already keeps in your keychain to show its "
                        + "5-hour and weekly windows next to Codex's. macOS asks for your "
                        + "permission, and asks again whenever Sissy's own binary changes; "
                        + "Sissy only ever reads the token, never writes or refreshes it."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Animate the mascot", isOn: mascotMotionBinding)
                Text(
                    "A blink or an ear twitch every few minutes, and nothing in between. "
                        + "Follows the system's Reduce Motion setting."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Files") {
                    HStack(spacing: 14) {
                        Button("Open logs") { model.openLogs() }
                            .buttonStyle(.link)
                        Button("Show in Finder") { revealConfig() }
                            .buttonStyle(.link)
                    }
                }
                Text(verbatim: (SissyPaths.appSupportDir.path as NSString).abbreviatingWithTildeInPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var serverCaption: String {
        let endpoint = "\(model.preferences.serverHost):\(model.preferences.serverPort)"
        return "\(server.subtitle) · \(endpoint). Runs as a background agent and keeps counting "
            + "after you quit Sissy."
    }

    private var serverBinding: Binding<Bool> {
        Binding(
            get: { server.isOn },
            set: { model.setServer(running: $0) }
        )
    }

    private var claudeLimitsBinding: Binding<Bool> {
        Binding(
            get: { model.preferences.claudeLimits },
            set: { model.setClaudeLimits($0) }
        )
    }

    private var mascotMotionBinding: Binding<Bool> {
        Binding(
            get: { model.preferences.mascotMotion },
            set: { model.setMascotMotion($0) }
        )
    }

    private func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([SissyPaths.appSupportDir])
    }
}
