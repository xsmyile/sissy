import AppKit
import SwiftUI

/// Settings that change what the menu bar and the panel show.
struct GeneralSettingsView: View {
    let model: SissyModel

    @State private var confirmingDelete = false

    private var historyCaption: String {
        let days = model.engine.historyRetentionDays
        guard days > 0 else {
            return "Switched off in server.json, so Sissy records nothing beyond the day it "
                + "is counting. Delete removes what an earlier run left."
        }
        return "A day-by-model record kept in history/ for \(days) days, so the panel can show "
            + "more than today. Nothing in it leaves this Mac."
    }

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
                Toggle("Keep the screen on too", isOn: keepScreenAwakeBinding)
                Text(
                    "Applies while keep awake is on. Off lets the display sleep and the Mac "
                        + "lock itself on its usual schedule, with the Mac still held awake "
                        + "underneath for the agents."
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

                LabeledContent("Usage history") {
                    Button("Delete") { confirmingDelete = true }
                        .buttonStyle(.link)
                }
                Text(historyCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Delete the usage history Sissy has recorded?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) { model.deleteUsageHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Today keeps counting. The days before it are gone, and the session logs "
                    + "they were read from may have been rotated since."
            )
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

    private var keepScreenAwakeBinding: Binding<Bool> {
        Binding(
            get: { model.engine.keepScreenAwake },
            set: { model.setKeepScreenAwake($0) }
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
