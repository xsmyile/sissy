import AppKit
import SwiftUI

/// Settings that change what the menu bar and the panel show.
struct GeneralSettingsView: View {
    let model: SissyModel

    var body: some View {
        Form {
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
                    "Sissy counts while it is running, so leaving this on is what keeps the "
                        + "day complete after a restart."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Animate Sissy", isOn: sissyMotionBinding)
                Text(
                    "A blink when new usage lands, in the menu bar and in the panel, "
                        + "and the eye shutting while there is nothing to show. Nothing in between. "
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
