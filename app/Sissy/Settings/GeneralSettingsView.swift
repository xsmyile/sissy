import AppKit
import SwiftUI

/// What the switch that writes into the CLIs' own configuration has to say for
/// itself before it is flipped.
enum AgentHookCopy {
    static let title = "Name projects even when Sissy is off"

    static let caption =
        "Asks Claude Code and Codex to tell Sissy which repository a session is working in, "
        + "at the moment it starts. Without it, work in a worktree deleted while Sissy was "
        + "not running counts towards no project at all."

    static let detail =
        "Sissy adds one line to ~/.claude/settings.json and ~/.codex/hooks.json. That line runs "
        + "a small script from Sissy's own folder whenever a session starts: it asks git which "
        + "repository the directory belongs to and writes the answer down. It reads nothing else "
        + "and sends nothing anywhere.\n\n"
        + "Switching this off removes both lines and the script. Deleting Sissy without switching "
        + "it off first does not — the two lines stay, and do nothing, because the script they "
        + "point at is gone."

    static let detailButtonLabel = "What Sissy writes"

    static let unknownHome = "this account"

    static let missingScript = "Sissy's own bundle"

    static func refusedCaption(_ names: [String]) -> String {
        "Sissy could not write to \(ListFormatter.localizedString(byJoining: names))'s "
            + "configuration, so it was left as it was. The switch stays on and Sissy tries "
            + "again next time it starts."
    }
}

/// Settings that change what the menu bar and the panel show.
struct GeneralSettingsView: View {
    let model: SissyModel

    @State private var confirmingDelete = false
    @State private var showingHookDetail = false

    /// Wide enough that the detail reads as a paragraph rather than a column.
    private static let detailPopoverWidth: CGFloat = 280

    /// What the two armed modes cost. Both the names and both the bounds are
    /// read rather than written out: a caption that says ten minutes while the
    /// shipped policy waits fifteen, or that calls a mode by a name the picker
    /// above it no longer uses, is worse than no caption. These are also the
    /// only numbers in the app that say when a hold ends.
    private var keepAwakeCaption: String {
        let idle = UsageFormat.countdown(KeepAwakePolicy.default.idleWindow)
        let ceiling = UsageFormat.countdown(KeepAwakePolicy.default.manualCeiling)
        return "\(UsageFormat.keepAwakeTitle(.auto)) holds the Mac only while a turn has "
            + "landed in the last \(idle), and lets go after. "
            + "\(UsageFormat.keepAwakeTitle(.on)) holds it until you switch it off, "
            + "\(ceiling) at the outside. Closing the lid sleeps the Mac under either."
    }

    private var agentHooksCaption: String {
        let refused = model.engine.agentHooksRefused
        guard model.engine.agentHooks, !refused.isEmpty else { return AgentHookCopy.caption }
        return AgentHookCopy.refusedCaption(refused)
    }

    /// A button rather than a tooltip, for the reason the limits switch has
    /// one: this is the only thing Sissy writes outside its own folder, and
    /// what it writes has to be readable before the switch is flipped.
    private var agentHooksDetailButton: some View {
        Button {
            showingHookDetail = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(AgentHookCopy.detailButtonLabel)
        .popover(isPresented: $showingHookDetail, arrowEdge: .bottom) {
            Text(AgentHookCopy.detail)
                .font(.callout)
                .frame(width: Self.detailPopoverWidth)
                .padding()
        }
    }

    private var agentHooksBinding: Binding<Bool> {
        Binding(
            get: { model.engine.agentHooks },
            set: { model.setAgentHooks($0) }
        )
    }

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
                Picker("Keep awake", selection: keepAwakeModeBinding) {
                    ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                        Text(UsageFormat.keepAwakeTitle(mode)).tag(mode)
                    }
                }
                Text(keepAwakeCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Keep the screen on too", isOn: keepScreenAwakeBinding)
                Text(
                    "Applies whenever the Mac is being held. Off lets the display sleep and the Mac "
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
                LabeledContent {
                    Toggle(AgentHookCopy.title, isOn: agentHooksBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    HStack(spacing: 4) {
                        Text(AgentHookCopy.title)
                        agentHooksDetailButton
                    }
                }
                Text(agentHooksCaption)
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

    private var keepAwakeModeBinding: Binding<KeepAwakeMode> {
        Binding(
            get: { model.keepAwake.mode },
            set: { model.setKeepAwake($0) }
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
