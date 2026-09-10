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
                LabeledContent("Start at login") {
                    if model.loginItem.requiresApproval {
                        Button("Approve in Login Items") { model.loginItem.openLoginItemsSettings() }
                    } else {
                        Toggle("Start at login", isOn: launchAtLoginBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                Text(
                    "Puts the menu bar icon back after a restart. The server starts at login on "
                        + "its own once it's on, so usage keeps counting either way."
                )
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
                Toggle("Animate Sissy", isOn: sissyMotionBinding)
                Text(
                    "A blink when new usage lands, in the menu bar and in the panel, "
                        + "and the eye shutting while the server is away. Nothing in between. "
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
        // `SMAppService` is the only record of the login item, so the switch
        // reads it whenever the window appears rather than trusting what it
        // last set: the user can undo it from System Settings.
        .task { model.loginItem.refresh() }
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

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.loginItem.isEnabled },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private var sissyMotionBinding: Binding<Bool> {
        Binding(
            get: { model.preferences.sissyMotion },
            set: { model.setSissyMotion($0) }
        )
    }

    private func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([SissyPaths.appSupportDir])
    }
}
