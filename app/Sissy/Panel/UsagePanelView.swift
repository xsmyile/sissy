import SwiftUI

/// Usage panel shown on a left-click of the status item. Reads the live
/// frame through `SissyModel`; every number it prints comes from
/// `UsagePanelSnapshot` so the panel and the pull-down menu cannot disagree.
struct UsagePanelView: View {
    let model: SissyModel

    /// Gives the popover a first responder on open, which is what makes
    /// Escape close it: AppKit routes `cancelOperation:` through the
    /// responder chain, and a panel of buttons has nothing that takes focus
    /// on its own unless Full Keyboard Access is on. The effect is disabled
    /// because the target is the whole panel — a focus ring around all of it
    /// would say nothing.
    @FocusState private var panelFocused: Bool

    private static let width: CGFloat = 340
    /// Cadence for both readouts the panel keeps on its own clock: the
    /// footer's age and the keep-awake control's duration. A second is finer
    /// than the duration needs — it changes by the minute — but the tick is
    /// what decides how late a change lands, and a minute-long one would show
    /// the wrong minute for most of it.
    private static let clockTick: TimeInterval = 1
    private static let secondaryWindowOpacity: Double = 0.55
    private static let controlButtonSize: CGFloat = 26
    private static let sissySize: CGFloat = 24

    private static var dateLine: String {
        "Today · "
            + Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func makeSnapshot(_ frame: FrameData) -> UsagePanelSnapshot {
        UsagePanelSnapshot.make(frame: frame)
    }

    var body: some View {
        let live = model.liveFrame
        let snapshot = live.map { makeSnapshot($0.frame) }
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let snapshot {
                headline(snapshot)
                if !snapshot.providers.isEmpty {
                    Divider()
                    providers(snapshot.providers)
                }
                if !snapshot.projects.isEmpty {
                    Divider()
                    projects(snapshot.projects)
                }
                if let history = snapshot.history {
                    Divider()
                    historyRow(history)
                }
            } else {
                placeholder
            }
            Divider()
            footer(live)
        }
        .frame(width: Self.width)
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .defaultFocus($panelFocused, true)
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
        .padding(.horizontal, 14)
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

    // MARK: Headline

    private func headline(_ snapshot: UsagePanelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.tokens)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("tokens")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let delta = snapshot.delta {
                    deltaChip(delta)
                }
            }
            Text(subline(snapshot))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .animation(.default, value: snapshot.tokens)
    }

    private func subline(_ snapshot: UsagePanelSnapshot) -> String {
        snapshot.burn == FrameBuilder.placeholder
            ? snapshot.cost : "\(snapshot.cost) · \(snapshot.burn)/h"
    }

    private func deltaChip(_ delta: UsagePanelSnapshot.TokenDelta) -> some View {
        HStack(spacing: 3) {
            Image(systemName: deltaSymbol(delta.direction))
                .font(.system(size: 9, weight: .bold))
            Text("\(delta.percent)%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
            Text("vs yesterday")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(deltaTint(delta.direction))
    }

    private func deltaSymbol(_ direction: UsagePanelSnapshot.DeltaDirection) -> String {
        switch direction {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "equal"
        }
    }

    private func deltaTint(_ direction: UsagePanelSnapshot.DeltaDirection) -> Color {
        switch direction {
        case .up: return .green
        case .down: return .red
        case .flat: return .secondary
        }
    }

    // MARK: History

    /// One line, under the day's own numbers, for what came before it. It is
    /// deliberately the quietest thing in the panel: the archive answers a
    /// question asked at the end of a month, not one asked while working.
    private func historyRow(_ row: UsagePanelSnapshot.HistoryRow) -> some View {
        HStack(spacing: 6) {
            Text(row.label)
                .font(.system(size: 12))
            Spacer(minLength: 0)
            Text("\(row.tokens) · \(row.cost)")
                .font(.system(size: 12))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Projects

    /// Where the day's money went, under the providers that spent it. The
    /// question is the same one either way — a provider row says which tool,
    /// a project row says which work — so the rows are the same shape, one
    /// step quieter.
    private func projects(_ rows: [UsagePanelSnapshot.ProjectRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By project")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                projectRow(row)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func projectRow(_ row: UsagePanelSnapshot.ProjectRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(row.tokens) · \(row.cost)")
                    .font(.system(size: 12))
                    .monospacedDigit()
            }
            shareBar(row.share, tint: .secondary)
        }
        .help(row.path ?? "")
    }

    // MARK: Providers

    private func providers(_ rows: [UsagePanelSnapshot.ProviderRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                providerRow(row)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// A provider shows its subscription windows when the CLI reports them,
    /// and its share of the day when it does not. Never both: the two bars
    /// carry percentages of different things, and side by side neither reads.
    private func providerRow(_ row: UsagePanelSnapshot.ProviderRow) -> some View {
        let tint = ProviderPalette.tint(for: row.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                if let plan = row.plan {
                    planBadge(plan, tier: row.planTier)
                }
                Spacer(minLength: 0)
                Text("\(row.tokens) · \(row.cost)")
                    .font(.system(size: 12))
                    .monospacedDigit()
            }

            if row.windows.isEmpty {
                shareBar(row.share, tint: tint)
                Text("\(Int((row.share * 100).rounded()))% of today")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ForEach(Array(row.windows.enumerated()), id: \.element.id) { index, window in
                    windowRow(window, tint: tint)
                        .opacity(index == 0 ? 1 : Self.secondaryWindowOpacity)
                }
            }
        }
    }

    /// The account's plan, badged rather than set as plain text beside the
    /// name: "Codex Plus" reads as a product OpenAI sells, and the pill is
    /// what says the word is an attribute of the account instead. It yields
    /// its width first — of the three things on this line, the plan is the
    /// one a reader can still infer once it is gone.
    ///
    /// `tier` is present only when the account is metered at some other
    /// plan's limits, which is a sentence and not a badge.
    private func planBadge(_ plan: String, tier: String?) -> some View {
        Text(plan)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .layoutPriority(-1)
            .help(tier.map { "\($0) rate limits" } ?? plan)
    }

    /// The bar, its reading, and — once the window is old enough to project
    /// from — the line that says whether that reading is ahead or behind.
    private func windowRow(
        _ window: UsagePanelSnapshot.WindowRow,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                shareBar(window.fraction, tint: tint, pace: window.pace)

                Text("\(window.percent)%")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)

                Text("\(window.label) · \(UsageFormat.resetLabel(window.resetsAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 74, alignment: .trailing)
            }

            if let pace = window.pace {
                Text(
                    UsageFormat.paceCaption(
                        deltaPercent: pace.deltaPercent, runsOutAt: pace.runsOutAt)
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    /// Width of the pace mark itself, and of the hole cut for it.
    ///
    /// The mark is punched out of the bar rather than painted over it: at
    /// 5 pt tall, a line drawn on top of a fill of similar weight disappears
    /// into it, and the gap is what makes two points of colour read.
    private static let paceMarkWidth: CGFloat = 2
    private static let paceMarkGap: CGFloat = 5

    /// Where the mark's centre lands, kept a half-gap inside the bar so a
    /// window in its last minutes draws a whole mark instead of half of one.
    private func paceMarkCentre(_ pace: UsagePanelSnapshot.Pace, in width: CGFloat) -> CGFloat {
        let inset = Self.paceMarkGap / 2
        guard width > Self.paceMarkGap else { return width / 2 }
        return min(max(width * pace.expectedFraction, inset), width - inset)
    }

    /// Green under the mark and red over it, which is the whole reading: the
    /// bar says where you are, the mark says where even consumption would have
    /// put you, and the colour says which of the two is ahead.
    ///
    /// The two branches exist for the compositing group, not for the mark.
    /// Cutting the gap needs one; a bar without a mark must not pay for one,
    /// and the project rows and the share bars are most of the bars the panel
    /// draws.
    @ViewBuilder
    private func shareBar(
        _ share: Double,
        tint: Color,
        pace: UsagePanelSnapshot.Pace? = nil
    ) -> some View {
        GeometryReader { geometry in
            let fill = max(geometry.size.width * share, share > 0 ? 3 : 0)
            if let pace {
                let centre = paceMarkCentre(pace, in: geometry.size.width)
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        barBody(fill: fill, tint: tint)
                        Capsule()
                            .frame(width: Self.paceMarkGap)
                            .offset(x: centre - Self.paceMarkGap / 2)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()

                    Capsule()
                        .fill(pace.isOverPace ? Color.red : Color.green)
                        .frame(width: Self.paceMarkWidth)
                        .offset(x: centre - Self.paceMarkWidth / 2)
                }
            } else {
                ZStack(alignment: .leading) {
                    barBody(fill: fill, tint: tint)
                }
            }
        }
        .frame(height: 5)
        .animation(.default, value: share)
    }

    @ViewBuilder
    private func barBody(fill: CGFloat, tint: Color) -> some View {
        Capsule()
            .fill(.quaternary)
        Capsule()
            .fill(tint.gradient)
            .frame(width: fill)
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
        .padding(.horizontal, 14)
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
        .padding(.horizontal, 14)
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
