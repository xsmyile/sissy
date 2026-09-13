import SwiftUI

/// The usage panel shown on a left-click of the status item: a header and the
/// page it belongs to.
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
    /// header's age and the keep-awake control's duration. A second is finer
    /// than the duration needs — it changes by the minute — but the tick is
    /// what decides how late a change lands, and a minute-long one would show
    /// the wrong minute for most of it.
    private static let clockTick: TimeInterval = 1
    private static let controlButtonSize: CGFloat = 26
    /// Larger than the legend's, because the header's title is 13 pt semibold
    /// against the legend's 12 pt medium and it sits between a back chevron
    /// and a 26 pt button. A mark sized for the quieter row reads as an
    /// afterthought here.
    private static let headerMarkSize: CGFloat = 18
    private static let headerTitleSize: CGFloat = 13
    private static let sissySize: CGFloat = 24

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
                providerHeader(open, live: live)
            } else {
                header(live)
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

    private func header(_ live: SissyModel.LiveFrame?) -> some View {
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
                    .font(.system(size: Self.headerTitleSize, weight: .semibold))
                    .lineLimit(1)
                secondLine(subtitle: menuHeader.subtitle, live: live)
            }

            Spacer(minLength: 0)

            headerControls
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    /// The app's own switches, which is why they are here and not on a
    /// provider's page: what the Mac is doing about sleep, and the way into
    /// Settings. Neither is about an account.
    private var headerControls: some View {
        HStack(spacing: 6) {
            keepAwakeButton(model.keepAwake)
            settingsButton
        }
    }

    /// What the header says under its title: why there is no reading, or when
    /// the one on screen landed.
    ///
    /// The two never compete. `subtitle` is set exactly while no frame has
    /// arrived, which is the same condition that leaves `live` nil, so the
    /// line is the age whenever there is an age to give and the reason
    /// otherwise. The date it replaced answered a question nobody opened the
    /// panel to ask.
    @ViewBuilder
    private func secondLine(subtitle: String?, live: SissyModel.LiveFrame?) -> some View {
        if let subtitle {
            Text(subtitle)
                .font(.system(size: PanelMetrics.headlineMeta))
                .foregroundStyle(.secondary)
        } else if let live {
            readingLine(
                live,
                holding: model.keepAwake.since,
                refreshing: !model.engine.refreshing.isEmpty
            )
        }
    }

    /// When the reading on screen landed, on its own clock.
    ///
    /// `TimelineView` rather than a value recomputed with the body: the
    /// instant it counts from is fixed, so the line stays true while the
    /// panel sits open and the engine emits nothing.
    private func readingLine(
        _ live: SissyModel.LiveFrame, holding: Date?, refreshing: Bool
    ) -> some View {
        TimelineView(.periodic(from: .now, by: Self.clockTick)) { context in
            Text(
                UsageFormat.reading(
                    age: context.date.timeIntervalSince(live.at),
                    holding: holding.map { context.date.timeIntervalSince($0) },
                    refreshing: refreshing)
            )
            .font(.system(size: PanelMetrics.headlineMeta))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    /// The header a provider page carries instead: the way back, whose page
    /// this is, and the refresh.
    ///
    /// One header rather than two stacked, which is what a navigation level
    /// reads as. Sissy, the keep-awake switch and the way into Settings belong
    /// to the app rather than to an account, so they stay home — one click
    /// away, which is where a global control can sit once the panel has
    /// somewhere to go.
    ///
    /// The age goes under the name for the same reason it goes under Sissy's:
    /// it is a property of the reading on screen, so it belongs beside what it
    /// dates. Here that puts it under the refresh button that resets it.
    private func providerHeader(
        _ row: UsagePanelSnapshot.ProviderRow, live: SissyModel.LiveFrame?
    ) -> some View {
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

            ProviderMark(id: row.id, size: Self.headerMarkSize, textSize: nil)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: Self.headerTitleSize, weight: .semibold))
                        .lineLimit(1)

                    if let plan = row.plan {
                        PlanBadge(plan: plan, tier: row.planTier)
                    }
                }

                if let live {
                    readingLine(
                        live, holding: nil,
                        refreshing: model.engine.refreshing.contains(row.id))
                }
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

    /// Styled as a switch rather than a footer glyph: it says what the
    /// machine is doing, and a link's styling made it read as navigation.
    ///
    /// Colour carries the two axes separately. The glass tints while the Mac
    /// is actually being held; a mode that is armed and holding nothing keeps
    /// the amber glyph without the tinted glass, so "armed" and "holding" stay
    /// legible apart. That second state has two causes — an automatic hold
    /// waiting for the agents to do something, and an assertion power
    /// management refused — and they look alike because they are alike: the
    /// Mac is free to sleep either way. The tooltip is what separates them.
    ///
    /// Toggling *and* choosing, from one control. A click is the switch it has
    /// always been, so the gesture people already have does not regress, and
    /// the three modes hang off the same button — the mode used to be
    /// reachable only from the status item's menu, and nothing in the panel
    /// said so.
    ///
    /// The right-click is the gesture the tooltip names and `.contextMenu` is
    /// what guarantees it. AppKit's own press-and-hold on a `primaryAction`
    /// menu normally opens it too, but that affordance is the menu indicator's
    /// and the indicator is hidden here: a chevron does not fit a 26 pt circle
    /// sitting beside the refresh button. Settings carries the same choice for
    /// anyone who never finds either gesture.
    private func keepAwakeButton(_ state: KeepAwakeState) -> some View {
        Menu {
            keepAwakeModes
        } label: {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: Self.controlButtonSize, height: Self.controlButtonSize)
                .foregroundStyle(state.mode == .off ? Color.secondary : Color.orange)
                .contentShape(.circle)
        } primaryAction: {
            model.setKeepAwake(state.mode == .off ? model.preferredKeepAwakeMode : .off)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(
            state.active ? .regular.tint(.orange.opacity(0.22)) : .regular,
            in: .circle
        )
        .help(UsageFormat.keepAwakeHelp(state, arming: model.preferredKeepAwakeMode))
        .contextMenu { keepAwakeModes }
    }

    /// The same circle as the keep-awake switch beside it, and grey where that
    /// one colours: this is the way out of the panel rather than something the
    /// panel is doing, so it takes the shape and gives up the tint.
    ///
    /// It came up from a footer that had nothing else left in it once the
    /// reading's age moved under the title. It belongs to home alone — a
    /// provider's page puts its refresh in this corner, and two round buttons
    /// that mean different things in the same place is how a header stops
    /// being read.
    ///
    /// `SettingsLink` is the only public way to open the `Settings` scene and
    /// it takes no action closure, so the simultaneous gesture is what aims
    /// the window at a tab.
    ///
    /// Filled and a point larger than the cup, which is what makes the two
    /// weigh the same: rendered side by side, an outline gear reads lighter
    /// than a filled cup at every size, and a filled one only catches up at
    /// 12.
    private var settingsButton: some View {
        SettingsLink {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Self.controlButtonSize, height: Self.controlButtonSize)
                .foregroundStyle(.secondary)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .help("Settings")
        .simultaneousGesture(TapGesture().onEnded { model.settingsTab = .general })
    }

    /// The three modes as a radio group, which is what an inline `Picker` in a
    /// menu renders to — the same shape as the status item's own menu, from
    /// the same words, so the two cannot drift.
    ///
    /// The selection reads the mode the model reports rather than a `@State`
    /// copy: the engine can move it on its own, when a manual hold reaches its
    /// ceiling and switches itself off.
    @ViewBuilder private var keepAwakeModes: some View {
        Picker("Keep awake", selection: keepAwakeModeBinding) {
            ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                Text(UsageFormat.keepAwakeTitle(mode)).tag(mode)
            }
        }
        .pickerStyle(.inline)
    }

    private var keepAwakeModeBinding: Binding<KeepAwakeMode> {
        Binding(
            get: { model.keepAwake.mode },
            set: { model.setKeepAwake($0) }
        )
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
}
