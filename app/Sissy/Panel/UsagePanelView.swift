import SwiftUI

/// The usage panel shown on a left-click of the status item: a header, a page,
/// and a footer.
///
/// The panel holds two surfaces because it answers two questions. `PanelOverview`
/// is what today costs and whether there is room to keep working;
/// `PanelProviderPage` is what one account is doing. A `switch` rather than a
/// `TabView` is the whole implementation of "only the selected page exists" —
/// `UsagePanelController` drops the host on close because a retained view graph
/// costs a layout and a rasterization on every frame the engine emits, and
/// three live pages would hand that back while the panel is open.
///
/// Every number it prints comes from `UsagePanelSnapshot`, so the panel and the
/// pull-down menu cannot disagree.
struct UsagePanelView: View {
    let model: SissyModel

    /// Which surface is on screen. Local to the view rather than on the model:
    /// the panel is dropped when it closes, and a page selection that outlived
    /// it would reopen on a provider the user last glanced at instead of home.
    @State private var page: Page = .overview

    /// Gives the popover a first responder on open, which is what makes
    /// Escape close it: AppKit routes `cancelOperation:` through the
    /// responder chain, and a panel of buttons has nothing that takes focus
    /// on its own unless Full Keyboard Access is on. The effect is disabled
    /// because the target is the whole panel — a focus ring around all of it
    /// would say nothing.
    @FocusState private var panelFocused: Bool

    enum Page: Equatable {
        case overview
        case provider(String)
    }

    /// Cadence for both readouts the panel keeps on its own clock: the
    /// footer's age and the keep-awake control's duration. A second is finer
    /// than the duration needs — it changes by the minute — but the tick is
    /// what decides how late a change lands, and a minute-long one would show
    /// the wrong minute for most of it.
    private static let clockTick: TimeInterval = 1
    private static let controlButtonSize: CGFloat = 26
    private static let sissySize: CGFloat = 24

    private static var dateLine: String {
        "Today · "
            + Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// The provider the current page is about, when there is one and the frame
    /// still carries it.
    ///
    /// A provider can leave the frame while its page is open — the slices are
    /// today's spenders, and a day rolls over — so the page falls back home
    /// rather than rendering a row that no longer exists.
    static func openRow(_ page: Page, in providers: [UsagePanelSnapshot.ProviderRow])
        -> UsagePanelSnapshot.ProviderRow?
    {
        guard case .provider(let id) = page else { return nil }
        return providers.first { $0.id == id }
    }

    var body: some View {
        let live = model.liveFrame
        let snapshot = live.map { UsagePanelSnapshot.make(frame: $0.frame) }
        let open = Self.openRow(page, in: snapshot?.providers ?? [])
        return VStack(alignment: .leading, spacing: 0) {
            if let open {
                providerHeader(open)
            } else {
                header
            }
            Divider()
            if let snapshot {
                if let open {
                    PanelProviderPage(
                        row: open, limitsEnabled: model.engine.claudeLimits
                    ) { model.refreshProvider(open.id) }
                } else {
                    PanelOverview(snapshot: snapshot) { page = .provider($0) }
                }
            } else {
                placeholder
            }
            Divider()
            footer(live)
        }
        .frame(width: PanelMetrics.width)
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .defaultFocus($panelFocused, true)
        .onChange(of: open == nil) { _, gone in
            if gone { page = .overview }
        }
    }

    // MARK: Header

    private var header: some View {
        let menuHeader = model.menuSnapshot.header
        return HStack(spacing: 10) {
            PanelSissy(
                isAsleep: menuHeader.isAsleep,
                lastFrameAt: model.lastFrameAt,
                motionEnabled: model.preferences.sissyMotion,
                size: Self.sissySize
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(menuHeader.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(menuHeader.subtitle ?? Self.dateLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            keepAwakeControl
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    /// The header a provider page carries instead: the way back, whose page
    /// this is, and the refresh.
    ///
    /// One header rather than two stacked, which is what a navigation level
    /// reads as. Sissy and the keep-awake switch belong to the app rather than
    /// to an account, so they stay home — one click away, which is where a
    /// global control can sit once the panel has somewhere to go.
    private func providerHeader(_ row: UsagePanelSnapshot.ProviderRow) -> some View {
        HStack(spacing: 8) {
            Button {
                page = .overview
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to today")

            Circle()
                .fill(ProviderPalette.tint(for: row.id))
                .frame(width: 7, height: 7)

            Text(row.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            if let plan = row.plan {
                PlanBadge(plan: plan, tier: row.planTier)
            }

            Spacer(minLength: 0)

            Button {
                model.refreshProvider(row.id)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: Self.controlButtonSize, height: Self.controlButtonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .glassEffect(.regular, in: .circle)
            .help(UsageFormat.refreshHelp(row.id))
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    /// The panel's one control, with how long the hold has been in force
    /// beside it.
    ///
    /// The elapsed reading sits outside the button rather than inside its
    /// tooltip because a tooltip is only true while it is open: `.help` is
    /// rebuilt when the body is, and a panel whose model has not changed
    /// would offer an hour-old duration to someone hovering now. The instant
    /// it counts from is fixed, so the clock runs off `TimelineView` and owes
    /// nothing to the next frame arriving.
    private var keepAwakeControl: some View {
        let state = model.keepAwake
        return HStack(spacing: 6) {
            if let since = state.since {
                TimelineView(.periodic(from: .now, by: Self.clockTick)) { context in
                    Text(UsageFormat.held(context.date.timeIntervalSince(since)))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            keepAwakeButton(state)
        }
    }

    /// Styled as a switch rather than a footer glyph: it says what the
    /// machine is doing, and a link's styling made it read as navigation.
    ///
    /// Colour carries the two axes separately. The glass tints while the Mac
    /// is actually being held; a mode that is armed and holding nothing keeps
    /// the amber glyph without the tinted glass, so "armed" and "holding" stay
    /// legible apart. That second state has two causes — an automatic hold
    /// waiting for the agents to do something, and an assertion power
    /// management refused — and they look alike because they are alike: the
    /// Mac is free to sleep either way. The tooltip is what separates them,
    /// and the menu is what says which mode is selected.
    ///
    /// Toggling, not cycling: three modes do not fit a button, so this one
    /// puts the switch back where the menu last left it rather than stepping
    /// through them.
    private func keepAwakeButton(_ state: KeepAwakeState) -> some View {
        Button {
            model.setKeepAwake(state.mode == .off ? model.preferredKeepAwakeMode : .off)
        } label: {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: Self.controlButtonSize, height: Self.controlButtonSize)
                .foregroundStyle(state.mode == .off ? Color.secondary : Color.orange)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(
            state.active ? .regular.tint(.orange.opacity(0.22)) : .regular,
            in: .circle
        )
        .help(keepAwakeHelp(state))
    }

    /// Names the lid in every wording that claims the Mac stays up, because
    /// the assertion holds off *idle* sleep and nothing else: a MacBook closed
    /// on a running agent sleeps anyway, and someone who learns that from a
    /// lost run blames Sissy for it.
    ///
    /// The screen clause follows `coversScreen`, which is the effect and not
    /// the setting, so a display assertion power management refused stops this
    /// promising a screen that is already dimming. The off state claims
    /// nothing about the screen at all — what a click would hold depends on a
    /// setting this tooltip is not the place to teach.
    private func keepAwakeHelp(_ state: KeepAwakeState) -> String {
        switch (state.mode, state.active) {
        case (.off, _):
            return "Keep this Mac awake · closing the lid still sleeps it"
        case (_, true):
            let since = state.since.map { " since \($0.formatted(.dateTime.hour().minute()))" } ?? ""
            let what =
                state.coversScreen
                ? "Keeping this Mac and its screen awake\(since), so it will not lock."
                : "Keeping this Mac awake\(since) — the screen still sleeps and locks."
            return what + " Closing the lid sleeps it anyway · click to allow sleep"
        case (.auto, false):
            return "Waiting for the agents · the Mac will be held while they work"
        case (.on, false):
            return "Switched on · the Mac is not being held awake"
        }
    }

    // MARK: Placeholder

    private var placeholderDetail: String {
        if !model.engine.isWarm { return "The first reading lands as soon as they are read." }
        if model.engine.filesWatched == 0 {
            return "Sissy reads ~/.claude/projects and ~/.codex/sessions. Neither has anything in it."
        }
        return "The first turn of the day shows up here within a few seconds of landing."
    }

    /// Why there is no reading, in the words the header already used, plus
    /// what happens next. Three outcomes rather than one: the readers are
    /// still walking the trees, they found no session logs at all, or they
    /// found logs and today is simply still empty — and only the middle one
    /// is something to act on.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.menuSnapshot.header.subtitle ?? "")
                .font(.system(size: 12, weight: .medium))
            Text(placeholderDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 14)
    }

    // MARK: Footer

    /// Carries the age of the frame only while one is live: the panel body
    /// already says what it is waiting for, and repeating it in the footer
    /// read as two problems.
    private func footer(_ live: SissyModel.LiveFrame?) -> some View {
        HStack(spacing: 6) {
            if let live {
                TimelineView(.periodic(from: .now, by: Self.clockTick)) { context in
                    Text("updated " + UsageFormat.age(context.date.timeIntervalSince(live.at)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            settingsLink("gearshape", help: "Settings", tab: .general)
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 10)
    }

    /// `SettingsLink` is the only public way to open the `Settings` scene, and
    /// it takes no action closure — the simultaneous gesture is what lets a
    /// footer button aim the window at its own tab.
    private func settingsLink(_ symbol: String, help: String, tab: SettingsTab) -> some View {
        SettingsLink {
            footerIcon(symbol)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .simultaneousGesture(TapGesture().onEnded { model.settingsTab = tab })
    }

    private func footerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .frame(width: 16, height: 16)
    }
}
