import AppKit
import SwiftUI

/// What the switch that writes into the CLIs' own configuration has to say for
/// itself before it is flipped.
enum AgentHookCopy {
    static let title = "Name projects even when Sissy is off"

    static let caption = "Asks Claude Code and Codex to name the repository a session starts in."

    static let detail =
        "Without this, work in a worktree deleted while Sissy was not running counts towards "
        + "no project at all.\n\n"
        + "Sissy adds one line to ~/.claude/settings.json and ~/.codex/hooks.json. That line runs "
        + "a small script from Sissy's own folder whenever a session starts: it asks git which "
        + "repository the directory belongs to and writes the answer down. It reads nothing else "
        + "and sends nothing anywhere.\n\n"
        + "Switching this off removes both lines and the script. Deleting Sissy without switching "
        + "it off first does not. The two lines stay, and do nothing, because the script they "
        + "point at is gone."

    static let detailButtonLabel = "What Sissy writes"

    static let unknownHome = "this account"

    static let missingScript = "Sissy's own bundle"

    /// What a configuration Sissy could not rewrite is told back as, which is
    /// not the same sentence in both directions. A failed *install* leaves the
    /// switch on and the file as it was found, and the next launch re-affirms
    /// anyway. A failed *removal* leaves a line in a file the user asked Sissy
    /// to get out of, under a switch that already reads off — so it has to say
    /// that the line is still there, and that Sissy will go back for it.
    static func refusedCaption(_ names: [String], enabled: Bool) -> String {
        let joined = ListFormatter.localizedString(byJoining: names)
        guard enabled else {
            return "Sissy could not remove its hook from \(joined). The line is still there, "
                + "and Sissy tries again next time it starts."
        }
        return "Sissy could not write to \(joined)'s "
            + "configuration, so it was left as it was. The switch stays on and Sissy tries "
            + "again next time it starts."
    }
}

/// Settings that change what the menu bar and the panel show.
///
/// Every row is a `LabeledContent` whose label carries the title and its own
/// description, which is what keeps the tab inside the height budget: the
/// caption sits beside the control it explains rather than under it as a
/// full-width paragraph, and the platform words it as secondary rather than one
/// point below the label. Measured on the shape this replaced — a `Section` per
/// control, each with a full-width `callout` paragraph — the same eight controls
/// came to 779 pt of content against 471 pt.
struct GeneralSettingsView: View {
    let model: SissyModel

    @State private var confirmingDelete = false
    @State private var showingHookDetail = false
    @State private var showingExportDetail = false

    /// Wide enough that the detail reads as a paragraph rather than a column.
    private static let detailPopoverWidth: CGFloat = 280

    /// What the two armed modes cost. Both the names and both the bounds are
    /// read rather than written out: a caption that says ten minutes while the
    /// shipped policy waits fifteen, or that calls a mode by a name the picker
    /// above it no longer uses, is worse than no caption. These are also the
    /// only numbers in the app that say when a hold ends, and the only place it
    /// says what a closed lid does to one.
    private var keepAwakeCaption: String {
        let idle = UsageFormat.countdown(KeepAwakePolicy.default.idleWindow)
        let ceiling = UsageFormat.countdown(KeepAwakePolicy.default.manualCeiling)
        return "\(UsageFormat.keepAwakeTitle(.auto)) lets go \(idle) after the last turn; "
            + "\(UsageFormat.keepAwakeTitle(.on)) stops at \(ceiling). "
            + "Closing the lid sleeps the Mac either way."
    }

    private var agentHooksCaption: String {
        let refused = model.engine.agentHooksRefused
        guard !refused.isEmpty else { return AgentHookCopy.caption }
        return AgentHookCopy.refusedCaption(refused, enabled: model.engine.agentHooks)
    }

    /// A button rather than a tooltip, for the reason the claude.ai import has
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
            return "Switched off in server.json, so nothing is recorded beyond the day Sissy is "
                + "counting. Export and Delete still reach what an earlier run left."
        }
        return "A day-by-model record kept in history/ for \(days) days. Sissy sends none of it "
            + "anywhere, and Export is the only way any of it leaves this Mac."
    }

    /// What the export carries, said before it is pressed rather than
    /// discovered in the file. The rows name repository paths, and a folder
    /// name is often a client's name — the panel renders the last component
    /// for exactly that reason, and a file leaving the machine cannot. It
    /// hangs off the ⓘ for the reason the hook detail does: the row's own
    /// caption has to fit beside its buttons.
    private static let exportDetail =
        "One CSV per provider plus a combined one, at the archive's own grain: a row per day, "
        + "model and project, with the tokens and the cost as recorded rather than as the panel "
        + "rounds them. A month or a quarter is a pivot table away. The rows carry the full path "
        + "of every repository the work was in, so choose where the folder goes accordingly. "
        + "A further file, sissy-activity.csv, carries one row a day per provider: how many "
        + "minutes were worked, how many of those were sub-agents, and in how many sittings. It "
        + "names no repository."

    private static let exportDetailButtonLabel = "What the export carries"

    /// The ⓘ beside Usage history, for the reason the hook switch has one:
    /// what a button sends off the Mac has to be readable before it is pressed.
    private var exportDetailButton: some View {
        Button {
            showingExportDetail = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Self.exportDetailButtonLabel)
        .popover(isPresented: $showingExportDetail, arrowEdge: .bottom) {
            Text(Self.exportDetail)
                .font(.callout)
                .frame(width: Self.detailPopoverWidth)
                .padding()
        }
    }

    var body: some View {
        Form {
            Section {
                startAtLogin
                animateSissy
                limitsReading
                agentHooks
                // Only ever reached by a configuration Sissy could not
                // rewrite. The launch path retries on its own; this is for
                // someone who has just fixed whatever stopped it and does not
                // want to restart the app to find out.
                if !model.engine.agentHooksRefused.isEmpty {
                    Button("Retry") { model.engine.retryAgentHooks() }
                        .buttonStyle(.link)
                }
            }

            Section {
                keepAwake
                keepScreenAwake
            }

            Section {
                files
                usageHistory
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
        // last set: the user can undo it from System Settings. Coming back
        // from there does not make the window appear again, so the switch
        // also reads it whenever the app becomes active while it is open.
        .task { model.loginItem.refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            model.loginItem.refresh()
        }
    }

    private var startAtLogin: some View {
        LabeledContent {
            if model.loginItem.requiresApproval {
                Button("Approve in Login Items") { model.loginItem.openLoginItemsSettings() }
            } else {
                Toggle("Start at login", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        } label: {
            Text("Start at login")
            Text("Sissy counts only while it is running, so this is what keeps a day complete.")
        }
    }

    private var animateSissy: some View {
        LabeledContent {
            Toggle("Animate Sissy", isOn: sissyMotionBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            Text("Animate Sissy")
            Text(
                "A blink when usage lands, the eye shut while nothing is. "
                    + "Follows Reduce Motion."
            )
        }
    }

    /// Which end of a rate-limit window the panel's gauges print.
    ///
    /// A picker of two rather than a switch: both ends are readings and
    /// neither is the feature being turned on, which is what a switch would
    /// say. The caption names the one thing the choice does *not* move, since
    /// the bar is what the eye reads first and it fills the same way either
    /// way — the mark on it sits where even consumption would have got to, and
    /// a fill measured from the other end would put the two on opposite sides.
    private var limitsReading: some View {
        LabeledContent {
            Picker("Limits show", selection: limitsReadingBinding) {
                ForEach(LimitsReading.allCases, id: \.self) { reading in
                    Text(UsageFormat.limitsReadingTitle(reading)).tag(reading)
                }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text("Limits show")
            Text(
                "Whether a rate-limit gauge prints what has been spent or what is still "
                    + "there. The bar fills with what has been spent either way."
            )
        }
    }

    private var limitsReadingBinding: Binding<LimitsReading> {
        Binding(
            get: { model.preferences.limitsReading },
            set: { model.setLimitsReading($0) }
        )
    }

    private var agentHooks: some View {
        LabeledContent {
            Toggle(AgentHookCopy.title, isOn: agentHooksBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            HStack(spacing: 4) {
                Text(AgentHookCopy.title)
                agentHooksDetailButton
            }
            Text(agentHooksCaption)
        }
    }

    private var keepAwake: some View {
        LabeledContent {
            Picker("Keep awake", selection: keepAwakeModeBinding) {
                ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                    Text(UsageFormat.keepAwakeTitle(mode)).tag(mode)
                }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text("Keep awake")
            Text(keepAwakeCaption)
        }
    }

    private var keepScreenAwake: some View {
        LabeledContent {
            Toggle("Keep the screen on too", isOn: keepScreenAwakeBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            Text("Keep the screen on too")
            Text("Off lets the display sleep while the Mac stays awake underneath for the agents.")
        }
    }

    /// Names both files Sissy writes outside its own folder, which is what the
    /// hook switch promises can be found.
    private var files: some View {
        LabeledContent {
            HStack(spacing: 14) {
                Button("Open logs") { model.openLogs() }
                    .buttonStyle(.link)
                Button("Show in Finder") { revealConfig() }
                    .buttonStyle(.link)
            }
        } label: {
            Text("Files")
            Text(verbatim: (SissyPaths.appSupportDir.path as NSString).abbreviatingWithTildeInPath)
            Text("Session hooks: ~/.claude/settings.json and ~/.codex/hooks.json")
        }
        .textSelection(.enabled)
    }

    private var usageHistory: some View {
        LabeledContent {
            HStack(spacing: 14) {
                Button("Export CSV") { model.exportUsageHistory() }
                    .buttonStyle(.link)
                Button("Delete") { confirmingDelete = true }
                    .buttonStyle(.link)
            }
        } label: {
            HStack(spacing: 4) {
                Text("Usage history")
                exportDetailButton
            }
            Text(historyCaption)
        }
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
