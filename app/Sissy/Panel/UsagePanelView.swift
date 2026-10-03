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
///
/// **The header stays, the page scrolls, and only at the screen's edge.** The
/// popover has no title bar and no way back once its content runs past the
/// bottom of the screen, so the page below the header sits in a scroll view
/// bounded by what the screen leaves. A page that fits is untouched — the
/// scroll view is set to the page's own measured height and scrolling is
/// disabled — so the popover is the size it has always been on every Mac big
/// enough for it, which is every Mac the author owns.
///
/// Scrolling the header away instead would take the back chevron and the
/// controls with it, which is the one row that has to be reachable from
/// anywhere on the page.
///
/// **No divider under the header.** The line it drew said "the page starts
/// here" on a page that was already starting there, and it was the first of
/// the hairlines the platters replaced. What is left of its job is the one
/// case where content runs under the header, and the scroll view's own soft
/// edge answers that case and only that one.
struct UsagePanelView: View {
    let model: SissyModel
    /// How tall the panel may be on the screen it is opening on, which the
    /// controller resolves per showing. The panel sizes to its content under
    /// this and scrolls at it — a ceiling rather than a height, so a short
    /// page is exactly as tall as it was before there was one.
    let maxHeight: CGFloat
    /// The Disk tab's cleanup rows, made by the controller for this showing
    /// and cancelled when it closes, so a size lives exactly as long as the
    /// panel it was measured for.
    let cleanup: DiskCleanupModel

    /// Which surface is on screen. Local to the view rather than on the model:
    /// the panel is dropped when it closes, and a page selection that outlived
    /// it would reopen on a provider the user last glanced at instead of home.
    @State private var page: Page = .overview

    /// Which module's tab `Page.overview` is showing. Local for the reason the
    /// page is, and always `usage` on open: a tab that outlived the panel
    /// would reopen on whatever was glanced at last rather than on the day.
    @State private var tab: PanelTab = .usage

    /// Gives the popover a first responder on open, which is what makes
    /// Escape close it: AppKit routes `cancelOperation:` through the
    /// responder chain, and a panel of buttons has nothing that takes focus
    /// on its own unless Full Keyboard Access is on. The effect is disabled
    /// because the target is the whole panel — a focus ring around all of it
    /// would say nothing.
    @FocusState private var panelFocused: Bool

    /// The header block and the page, measured rather than derived.
    ///
    /// A `ScrollView` is greedy: given a flexible proposal it takes all of it,
    /// so a page 300 pt tall under a 957 pt ceiling reported 957 and the
    /// popover opened at the height of the screen. Measured on macOS 26 —
    /// `.frame(maxHeight:)` on the panel, `.fixedSize` on the scroll view and
    /// both together all produce that. What works is giving the scroll view an
    /// explicit height: the page is measured inside it and the scroll view is
    /// set to the smaller of that and what the header leaves. The ceiling
    /// therefore cannot be applied to the panel as a whole, because the
    /// greedy child is what it would be clamping.
    @State private var headerHeight: CGFloat = 0
    @State private var pageHeight: CGFloat = 0

    /// What the page has once the header has taken its share.
    private var availableForPage: CGFloat { max(maxHeight - headerHeight, 0) }

    /// The archive's reading of the days the panel's period covers, for a
    /// picked window's headline and any window's strip. Fetched while the
    /// panel is open and dropped with it, so a closed panel reads nothing.
    @State private var spanReading: UsageSpanReading?
    /// Each forge's counters over a picked window, fetched only while the
    /// Forge tab is on screen over one. Each carries its own dates, so an
    /// answer for other days is ignored rather than cleared.
    @State private var forgeSpan: [ForgeSpanReading] = []

    /// What the span fetch is keyed on: the days, and while they reach today
    /// the archive's own total, which moves when today's file is rewritten.
    /// A frame that changed nothing on disk re-reads nothing.
    private struct SpanFetch: Equatable {
        let span: UsageDaySpan?
        let tokens: Int?
        let cost: Decimal?
    }

    enum Page: Equatable {
        /// The selected tab's own page, which is the only level the tab bar
        /// is drawn on: every case below is one level in from one of them,
        /// and the way back returns to the tab it was opened from.
        case overview
        /// The vendor's page, and which of its accounts to open on — the row
        /// that was clicked, so a gauge per account leads where it reads.
        case provider(String, account: String?)
        /// That vendor's services, one level in from its page, carrying the
        /// account with them so the way back lands where it was left.
        ///
        /// A page rather than the nested `.popover` it replaced. Apple's own
        /// guidance rules that out — *"Never show a cascade or hierarchy of
        /// popovers, in which one emerges from another"* — and the cost was
        /// measured: see `PanelProviderStatus`.
        case services(String, account: String?)
        /// That vendor's week by model and effort, one level in from the
        /// `By effort` row on its page, which is the only door to it. The
        /// account travels for the way back, as it does for the services.
        case effort(String, account: String?)
        /// Every project of the day, unfolded: one level in from the Overview
        /// when no provider is named, and from a vendor's own page when one
        /// is. The account travels for the same reason it does above — the way
        /// back has to land on the page that was left, not on that vendor's
        /// first account.
        case projects(String?, account: String?)
        /// Which repositories commit under a name their forge does not
        /// expect, one level in from the Overview. `focus` is the repository
        /// the page was opened about — a project row's own, or the single
        /// repository the Overview's line names — and nil where it was opened
        /// to read the whole list.
        case identities(focus: String?)
        /// The presets and a month of the archive to pick the panel's period
        /// from, one level in from the header's calendar button. A pick
        /// returns to the tab it was opened from.
        case calendar
    }

    private static let controlButtonSize: CGFloat = 26
    /// The back chevron's target, smaller than the round controls opposite it:
    /// it is a glyph on the text line rather than a button on glass, and a
    /// 26 pt box around it would make the header's left edge read as heavier
    /// than its right.
    private static let backButtonSize: CGFloat = 20
    /// Above and below every header's row, home's and each page's alike, so
    /// the tab bar and the page under a header start at one height.
    private static let headerVerticalPadding: CGFloat = 12
    /// How far the glass under the keep-awake switch is tinted while a hold
    /// is in force. Enough to read as lit next to an untinted circle, short of
    /// a filled button — it is a state, not a selection.
    private static let heldGlassTint: Double = 0.22
    /// Larger than the legend's, because the header's title is 13 pt semibold
    /// against the legend's 12 pt medium and it sits between a back chevron
    /// and a 26 pt button. A mark sized for the quieter row reads as an
    /// afterthought here.
    private static let headerMarkSize: CGFloat = 18
    private static let headerTitleSize: CGFloat = 13
    private static let sissySize: CGFloat = 24

    /// Which account the open page was aimed at, or nil on the Overview and
    /// for a vendor whose Overview row is not per account.
    private var openAccount: String? {
        switch page {
        case .overview, .identities, .calendar: nil
        case .provider(_, let account), .services(_, let account),
            .effort(_, let account), .projects(_, let account):
            account
        }
    }

    /// A provider can leave the frame while its page is open — the slices are
    /// today's spenders, and a day rolls over — so the page falls back home
    /// rather than rendering a row that no longer exists.
    nonisolated static func openRow(_ page: Page, in providers: [UsagePanelSnapshot.ProviderRow])
        -> UsagePanelSnapshot.ProviderRow?
    {
        switch page {
        case .overview, .identities, .calendar: return nil
        case .provider(let id, _), .services(let id, _), .effort(let id, _):
            return providers.first { $0.id == id }
        case .projects(let id, _):
            guard let id else { return nil }
            return providers.first { $0.id == id }
        }
    }

    /// The status reading the services page is about, when that is the page and
    /// there is still a reading to show.
    ///
    /// The monitor can stop publishing one — a feed that has never answered, a
    /// provider switched off mid-visit — and an empty services page is worse
    /// than the page it was opened from, so the panel falls back to the
    /// vendor's own page rather than drawing a heading over nothing.
    private func servicesReading(of row: UsagePanelSnapshot.ProviderRow?)
        -> UsagePanelSnapshot.StatusRow?
    {
        guard case .services = page else { return nil }
        return row?.status
    }

    /// The projects page's own rows, built only while that page is open.
    ///
    /// The snapshot is remade on every frame the panel is open for, and the
    /// unfolded list is wanted on one page that usually is not, so this hangs
    /// off the page rather than off `UsagePanelSnapshot.make`. It reads over
    /// the snapshot's window, which is the Overview's.
    private func projectsPage(
        of frame: FrameData?, snapshot: UsagePanelSnapshot?
    ) -> UsagePanelSnapshot.ProjectsPage? {
        guard case .projects(let provider, _) = page, let frame else { return nil }
        return UsagePanelSnapshot.projectsPage(
            frame: frame, provider: provider, period: snapshot?.period ?? .preset(.today),
            window: snapshot?.window)
    }

    var body: some View {
        let live = model.liveFrame
        let now = Date()
        let history = live?.frame.history ?? [:]
        let period = UsagePanelSnapshot.resolve(
            model.usagePeriod, periods: UsagePanelSnapshot.availablePeriods(history))
        let earliest = history[.all]?.earliestDay
        let days = UsagePanelSnapshot.windowSpan(period, earliest: earliest, now: now)
        let snapshot = live.map {
            UsagePanelSnapshot.make(
                frame: $0.frame,
                period: period,
                span: spanReading,
                forgeSpan: forgeSpan,
                claudeAccounts: model.engine.claudeAccounts,
                limitsReading: model.preferences.limitsReading,
                now: now)
        }
        let open = Self.openRow(page, in: snapshot?.providers ?? [])
        let tabs = snapshot.map { PanelTab.visible(in: $0, network: model.engine.network) } ?? [.usage]
        let liveDemand = page == .overview && tabs.contains(tab) ? tab.liveReadings : []
        let readings = PageReadings(
            open: open, services: servicesReading(of: open),
            projects: projectsPage(of: live?.frame, snapshot: snapshot),
            days: period == .preset(.today) ? nil : days, earliest: earliest)
        let spanFetch = Self.spanFetch(period, days: days, history: history, now: now)
        let forgeFetch = forgeFetch(period)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header(for: page, live: live, readings: readings)
                if page == .overview, tabs.count > 1, let snapshot {
                    PanelTabBar(tabs: tabs, selection: $tab) { $0.badge(in: snapshot) }
                }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                headerHeight = $0
            }

            ScrollView(.vertical) {
                Group {
                    if let snapshot {
                        content(for: page, snapshot: snapshot, live: live, readings: readings)
                    } else {
                        placeholder
                    }
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    pageHeight = $0
                }
            }
            .frame(height: min(pageHeight, availableForPage))
            .scrollDisabled(pageHeight <= availableForPage)
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .frame(width: PanelMetrics.width)
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .defaultFocus($panelFocused, true)
        .onChange(of: open == nil) { _, gone in
            if gone { page = .overview }
        }
        .onChange(of: liveDemand, initial: true) { _, wanted in
            model.engine.setLiveDemand(wanted)
        }
        .onChange(of: tabs.contains(tab)) { _, present in
            if !present {
                tab = .usage
                page = .overview
            }
        }
        .task(id: spanFetch) {
            guard let span = spanFetch.span else { return }
            let reading = await model.engine.usageHistoryReading(over: span)
            guard !Task.isCancelled else { return }
            spanReading = reading
        }
        .task(id: forgeFetch) {
            guard let span = forgeFetch else { return }
            let readings = await model.engine.forgeActivity(from: span.from, to: span.to)
            guard !Task.isCancelled else { return }
            forgeSpan = readings
        }
    }

    /// The days the span reading is fetched for: none under the `Today`
    /// preset, which reads the live tail, and the period's days otherwise.
    private static func spanFetch(
        _ period: UsageRange, days: UsageDaySpan?, history: [UsagePeriod: UsageHistoryRollup],
        now: Date
    ) -> SpanFetch {
        guard period != .preset(.today) else { return SpanFetch(span: nil, tokens: nil, cost: nil) }
        let archive = period.includesToday(now: now) ? history[.all] : nil
        return SpanFetch(span: days, tokens: archive?.tokens, cost: archive?.cost)
    }

    /// The picked window the Forge tab is asking the forges about, nil while
    /// that tab is not on screen or the period is a preset, which the poll
    /// already answers.
    private func forgeFetch(_ period: UsageRange) -> UsageDaySpan? {
        guard page == .overview, tab == .forge, case .days(let span) = period else { return nil }
        return span
    }

    // MARK: Page routing

    /// A page's own readings, resolved once per frame against the current
    /// snapshot and handed to both `header(for:live:readings:)` and
    /// `content(for:snapshot:live:readings:)` so the two agree without
    /// resolving them twice.
    private struct PageReadings {
        let open: UsagePanelSnapshot.ProviderRow?
        let services: UsagePanelSnapshot.StatusRow?
        let projects: UsagePanelSnapshot.ProjectsPage?
        /// The days the panel reads over, nil under the `Today` preset, for
        /// the calendar's band.
        let days: UsageDaySpan?
        /// The first day the archive holds, which bounds the calendar.
        let earliest: Date?
    }

    /// The header for `target`, exhaustive over every `Page` case so a case
    /// added without one fails to compile.
    @ViewBuilder
    private func header(
        for target: Page, live: SissyModel.LiveFrame?, readings: PageReadings
    ) -> some View {
        switch target {
        case .overview:
            header(live)
        case .provider:
            providerOrHomeHeader(readings.open, live: live) { _ in .overview }
        case .services:
            providerOrHomeHeader(readings.open, live: live) { row in
                readings.services == nil ? .overview : .provider(row.id, account: openAccount)
            }
        case .effort:
            providerOrHomeHeader(readings.open, live: live) { row in
                .provider(row.id, account: openAccount)
            }
        case .projects:
            if let projects = readings.projects {
                projectsHeader(projects)
            } else {
                header(live)
            }
        case .identities:
            identitiesHeader(checkedAt: live?.frame.identitiesCheckedAt)
        case .calendar:
            subpageHeader(back: .overview, mark: nil, title: "Calendar") {
                EmptyView()
            } trailing: {
                EmptyView()
            }
        }
    }

    /// The provider header while its row is still in the frame, and the
    /// Overview's own header once it is not: the slices are today's
    /// spenders, and a day rolls over while a provider's page is open.
    @ViewBuilder
    private func providerOrHomeHeader(
        _ open: UsagePanelSnapshot.ProviderRow?, live: SissyModel.LiveFrame?,
        back: (UsagePanelSnapshot.ProviderRow) -> Page
    ) -> some View {
        if let open {
            providerHeader(open, live: live, back: back(open))
        } else {
            header(live)
        }
    }

    /// The content for `target`, exhaustive over every `Page` case for the
    /// same reason the header is. A services page whose reading is gone
    /// falls back to the provider page, since that is all it has left to
    /// draw.
    @ViewBuilder
    private func content(
        for target: Page, snapshot: UsagePanelSnapshot, live: SissyModel.LiveFrame?,
        readings: PageReadings
    ) -> some View {
        switch target {
        case .overview:
            home(snapshot, live: live)
        case .provider:
            if let open = readings.open {
                providerPage(open, live: live)
            } else {
                overview(snapshot)
            }
        case .services:
            servicesContent(snapshot: snapshot, live: live, readings: readings)
        case .effort:
            effortContent(snapshot: snapshot, readings: readings)
        case .projects:
            if let projects = readings.projects {
                PanelProjectsPage(
                    page: projects,
                    openIdentities: { page = .identities(focus: $0) })
            } else {
                overview(snapshot)
            }
        case .identities:
            PanelIdentities(rows: snapshot.identities, focus: Self.identityFocus(target))
        case .calendar:
            PanelCalendar(
                period: snapshot.period,
                periods: snapshot.periods,
                reading: [
                    UsageFormat.periodHeading(snapshot.period), "\(snapshot.tokens) tokens",
                    snapshot.cost,
                ].joined(separator: " · "),
                window: readings.days,
                earliest: readings.earliest,
                load: { await model.engine.usageHistoryReading(over: $0) },
                select: {
                    model.setUsagePeriod($0)
                    page = .overview
                })
        }
    }

    /// The services page, or the provider page once the reading it was
    /// opened on is gone, or home once the provider is too.
    @ViewBuilder
    private func servicesContent(
        snapshot: UsagePanelSnapshot, live: SissyModel.LiveFrame?, readings: PageReadings
    ) -> some View {
        if let open = readings.open, let services = readings.services {
            PanelProviderStatusPage(provider: open.id, row: services)
        } else if let open = readings.open {
            providerPage(open, live: live)
        } else {
            overview(snapshot)
        }
    }

    /// The effort page, or home once its provider has left the frame.
    @ViewBuilder
    private func effortContent(snapshot: UsagePanelSnapshot, readings: PageReadings)
        -> some View
    {
        if let open = readings.open {
            PanelEffortPage(
                provider: open.id, today: open.effort,
                loadHistory: {
                    await model.engine.usageHistorySeries(provider: $0)
                })
        } else {
            overview(snapshot)
        }
    }

    /// The selected tab's page, or Usage's for a tab whose module has gone
    /// in the frame this body was built from. The `onChange` on the tab list
    /// moves the selection back on the next pass; this is what draws until it
    /// does.
    @ViewBuilder
    private func home(_ snapshot: UsagePanelSnapshot, live: SissyModel.LiveFrame?) -> some View {
        switch tab {
        case .usage:
            overview(snapshot)
        case .sessions:
            if let live {
                PanelSessions(
                    block: UsagePanelSnapshot.makeAgents(live.frame, window: snapshot.window),
                    period: snapshot.period,
                    observedAt: live.frame.agentMemory?.current.observedAt,
                    refreshing: model.engine.refreshingAgents,
                    refresh: { model.engine.refreshAgentProcesses() })
            }
        case .mac:
            if let mac = snapshot.mac {
                PanelMac(block: mac)
            } else {
                overview(snapshot)
            }
        case .disk:
            if let disk = snapshot.disk {
                PanelDisk(block: disk, engine: model.engine, cleanup: cleanup)
            } else {
                overview(snapshot)
            }
        case .network:
            PanelNetwork(engine: model.engine)
        case .forge:
            PanelForge(
                snapshot: snapshot,
                refreshingForge: model.engine.refreshingForge.union(forgeAwaited(snapshot)),
                refreshForge: { model.engine.refreshForge($0) },
                openIdentities: { page = .identities(focus: $0) })
        }
    }

    /// The forge rows still waiting on their answer for a picked window,
    /// which their labels word as being read rather than as a dash with no
    /// reason beside it.
    private func forgeAwaited(_ snapshot: UsagePanelSnapshot) -> Set<String> {
        guard case .days(let span) = snapshot.period else { return [] }
        let answered = Set(
            forgeSpan.filter { $0.from == span.from && $0.to == span.to }.map(\.id))
        return Set(snapshot.forge.map(\.id)).subtracting(answered)
    }

    /// The panel's home, and what every page one level in falls back to once
    /// its own reading is gone.
    private func overview(_ snapshot: UsagePanelSnapshot) -> some View {
        PanelOverview(
            snapshot: snapshot,
            meteringProviders: model.engine.providers.count {
                $0.activation.isMetering
            },
            openProvider: { page = .provider($0, account: $1) },
            openProjects: { page = .projects(nil, account: nil) },
            openIdentities: { page = .identities(focus: $0) },
            resetPeriod: { model.setUsagePeriod(.preset(.today)) },
            selectDay: { day in
                guard let span = UsageDaySpan(from: day, to: day) else { return }
                model.setUsagePeriod(.days(span))
            }
        )
    }

    /// That provider's own page: its windows, identity, credits and day.
    ///
    /// `onAddAccount` reads the vendor off `row.id` rather than off the
    /// button that opens it: the control sits on that provider's own account
    /// menu, so a press can only ever mean "another of this one".
    private func providerPage(
        _ row: UsagePanelSnapshot.ProviderRow, live: SissyModel.LiveFrame?
    ) -> some View {
        let slice = live?.frame.providers.first { $0.id == row.id }
        return PanelProviderPage(
            row: row,
            openOnAccount: openAccount,
            onSelectAccount: { model.engine.activateClaudeAccount(uuid: $0) },
            onAddAccount: { model.engine.addAccount(for: row.id) },
            switchFailure: model.engine.accountSwitchFailure,
            switchingAccount: model.engine.switchingClaudeAccount,
            resetSpending: model.engine.spendingCodexReset,
            resetReport: model.engine.codexResetReport,
            useReset: { model.engine.useCodexReset(account: $0.account) },
            refresh: { model.engine.refreshProvider(row.id) },
            openServices: { page = .services(row.id, account: $0) },
            openProjects: { page = .projects(row.id, account: $0) },
            openEffort: { page = .effort(row.id, account: $0) },
            openIdentities: { page = .identities(focus: $0) },
            loadHistory: {
                await model.engine.usageHistorySeries(provider: $0)
            },
            todayTokens: slice?.tokens ?? 0,
            todayCost: slice?.cost ?? 0
        )
    }

    // MARK: Header

    /// Which repository the identities page was opened about, if any.
    static func identityFocus(_ page: Page) -> String? {
        guard case .identities(let focus) = page else { return nil }
        return focus
    }

    /// The identities page's own header: the way back, the title, when the
    /// repositories were last read, and a re-read.
    ///
    /// The refresh is not a nicety here. A user on this page has usually just
    /// corrected a repository in a terminal, and waiting out a sweep interval
    /// to watch the row clear reads as the correction not having worked. The
    /// age under the title is what answers a press that changed nothing: the
    /// rows stand still, so without it the button reads as broken.
    private func identitiesHeader(checkedAt: Date?) -> some View {
        subpageHeader(back: .overview, mark: nil, title: "Identities") {
            TimelineView(.periodic(from: .now, by: PanelMetrics.clockTick)) { context in
                if let line = UsageFormat.identitiesReading(
                    checkedAt: checkedAt, refreshing: model.engine.refreshingIdentities,
                    now: context.date)
                {
                    Text(line)
                        .font(.system(size: PanelMetrics.headlineMeta))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } trailing: {
            refreshButton(help: "Read every repository's commit identity again") {
                model.engine.refreshIdentities()
            }
        }
    }

    /// The shell every page one level in shares: the way back, whose page
    /// it is, the title with its line under it, and a control at the end.
    ///
    /// One shell rather than one per page, for the reason `backButton` is
    /// one control: three headers each drawing their own were free to drift
    /// a point apart, and a user moving between the pages reads that as the
    /// panel jumping.
    private func subpageHeader<Subtitle: View, Trailing: View>(
        back destination: Page,
        mark: String?,
        title: String,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            backButton(to: destination)

            if let mark {
                ProviderMark(id: mark, size: Self.headerMarkSize, textSize: nil)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: Self.headerTitleSize, weight: .semibold))
                    .lineLimit(1)
                subtitle()
            }

            Spacer(minLength: 0)

            trailing()
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, Self.headerVerticalPadding)
    }

    /// The re-read at the end of a header, on glass beside the page's title
    /// like the home header's switches.
    private func refreshButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: Self.controlButtonSize, height: Self.controlButtonSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .glassEffect(.regular, in: .circle)
        .help(help)
    }

    private func header(_ live: SissyModel.LiveFrame?) -> some View {
        let menuHeader = model.menuSnapshot.header
        return HStack(spacing: 10) {
            PanelSissy(
                isAsleep: menuHeader.isAsleep,
                lastFrameAt: model.lastFrameAt,
                motionEnabled: model.preferences.sissyMotion,
                isHolding: model.keepAwake.active,
                size: Self.sissySize
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(menuHeader.title)
                    .font(.system(size: Self.headerTitleSize, weight: .semibold))
                    .lineLimit(1)
                secondLine(subtitle: menuHeader.subtitle, live: live)
            }

            Spacer(minLength: 0)

            headerControls(live)
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, Self.headerVerticalPadding)
    }

    /// The app's own switches, which is why they are here and not on a
    /// provider's page: which window the panel reads over, what the Mac is
    /// doing about sleep, and the way into Settings. None is about an account.
    private func headerControls(_ live: SissyModel.LiveFrame?) -> some View {
        let periods = live.map { UsagePanelSnapshot.availablePeriods($0.frame.history) } ?? []
        return HStack(spacing: 6) {
            periodButton(
                periods, chosen: UsagePanelSnapshot.resolve(model.usagePeriod, periods: periods))
            keepAwakeButton(model.keepAwake)
            settingsButton
        }
    }

    /// The panel's one period, which Usage, Sessions and Forge all read over.
    ///
    /// **One control for the panel, in the header**, decided 2026-09-28. The
    /// period was a popup on Usage's headline, then Sessions and Forge each
    /// grew one of their own: three answers to one question, in two sizes,
    /// one remembered and two not, and the first of them moved a page the
    /// user was not looking at. Up here it sits above every tab it moves.
    ///
    /// **An icon, so every reading names its window.** A circle beside the
    /// keep-awake switch costs the header no width, and the price is that its
    /// closed face does not say which window is chosen: the headline's
    /// subline and the Sessions and Forge labels say it instead. The one
    /// thing the face does say is that the window is a picked one rather than
    /// a preset, in the accent, because a picked window is the one that
    /// expires and the one a user forgets they set.
    ///
    /// **A click opens the calendar and a right-click the presets**, decided
    /// 2026-10-03 (#310). The calendar is a page rather than a popover, for
    /// the reason every page one level in is; the presets keep the menu they
    /// had, through `.contextMenu` as the keep-awake switch beside it does,
    /// with a picked window listed first so the menu says what is chosen.
    ///
    /// Disabled on Mac, Disk and Network, which read the moment and have no
    /// window, rather than hidden: a header whose controls come and go with
    /// the tab moves under the pointer. Absent while the archive answers
    /// nothing but today, since a control whose every option answers the
    /// number on screen is a control about a feature.
    @ViewBuilder
    private func periodButton(_ periods: [UsagePeriod], chosen: UsageRange) -> some View {
        if periods.count > 1 {
            let picked = chosen.isPicked
            Button {
                page = .calendar
            } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: Self.controlButtonSize, height: Self.controlButtonSize)
                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(
                picked ? .regular.tint(.accentColor.opacity(Self.heldGlassTint)) : .regular,
                in: .circle
            )
            .disabled(readsTheMoment)
            .help(readsTheMoment ? UsageFormat.periodHelpMoment : UsageFormat.periodHelp(chosen))
            .contextMenu { periodMenu(periods, chosen: chosen) }
            .accessibilityLabel("Period")
            .accessibilityValue(UsageFormat.periodHeading(chosen))
        }
    }

    /// The presets as checked items, a picked window above them while one is
    /// set, and the way into the calendar under them.
    @ViewBuilder
    private func periodMenu(_ periods: [UsagePeriod], chosen: UsageRange) -> some View {
        if chosen.isPicked {
            Toggle(UsageFormat.periodHeading(chosen), isOn: .constant(true))
            Divider()
        }
        ForEach(periods, id: \.self) { preset in
            Toggle(
                UsageFormat.periodLabel(preset),
                isOn: Binding(
                    get: { chosen == .preset(preset) },
                    set: { _ in model.setUsagePeriod(.preset(preset)) }))
        }
        Divider()
        Button("Open Calendar") { page = .calendar }
    }

    private var readsTheMoment: Bool {
        page == .overview && !tab.readsPeriod
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
    ///
    /// One line whatever it says: a second one grows the header and moves
    /// every block under it while the pointer is on the panel. The terse
    /// wording is what keeps it to one; should a wording ever outgrow that
    /// too, the line limit truncates it rather than wrapping. The choice is
    /// made on `UsageFormat.widestReading` drawn hidden under the live
    /// sentence, so it does not change as the age ticks. VoiceOver reads the
    /// whole sentence either way, since the width is not its concern.
    private func readingLine(
        _ live: SissyModel.LiveFrame, holding: Date?, refreshing: Bool
    ) -> some View {
        TimelineView(.periodic(from: .now, by: PanelMetrics.clockTick)) { context in
            let age = context.date.timeIntervalSince(live.at)
            let held = holding.map { context.date.timeIntervalSince($0) }
            let full = UsageFormat.reading(age: age, holding: held, refreshing: refreshing)
            ViewThatFits(in: .horizontal) {
                readingText(UsageFormat.widestReading(holding: held))
                    .hidden()
                    .overlay(alignment: .leading) { readingText(full) }
                readingText(
                    UsageFormat.reading(
                        age: age, holding: held, refreshing: refreshing, terse: true)
                )
                .accessibilityLabel(full)
            }
        }
    }

    private func readingText(_ line: String) -> some View {
        Text(line)
            .font(.system(size: PanelMetrics.headlineMeta))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// The projects page's header: the way back, what the page is, and the
    /// day it is of.
    ///
    /// No age and no refresh. Both belong to a reading a vendor answers for,
    /// and this page is the frame's own arithmetic over logs that are already
    /// on the disk — the page it was opened from dates that, one click away.
    ///
    /// The way back is the page that was left rather than always the Overview,
    /// because both of them have a list that folds and therefore a row that
    /// opens this one.
    private func projectsHeader(_ projects: UsagePanelSnapshot.ProjectsPage) -> some View {
        subpageHeader(
            back: projects.provider.map { .provider($0, account: openAccount) } ?? .overview,
            mark: projects.provider,
            title: "Projects"
        ) {
            Text(projects.subtitle)
                .font(.system(size: PanelMetrics.headlineMeta))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } trailing: {
            EmptyView()
        }
    }

    /// The way back, which every page one level in carries in the same corner
    /// at the same size. One control rather than one per header: a page that
    /// drew its own would be free to draw it a point off, and the chevron is
    /// the only thing on these headers a user has to find without looking.
    private func backButton(to destination: Page) -> some View {
        Button {
            page = destination
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Self.backButtonSize, height: Self.backButtonSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(backHelp(to: destination))
    }

    /// The way back's tooltip, named by where it lands: the vendor's page by
    /// the vendor, and the Overview by the tab it was opened from.
    private func backHelp(to destination: Page) -> String {
        guard case .provider(let id, _) = destination else { return homeHelp }
        return "Back to \(UsageFormat.providerName(id))"
    }

    /// Where the way back from a page one level in goes: the tab it was
    /// opened from, named by what that tab is about. Not `today` for Usage
    /// any more, whose page reads over whatever window the panel is set to.
    private var homeHelp: String {
        "Back to \(tab.title)"
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
    /// dates. Here that puts it under the refresh button that resets it — and
    /// it is why only the vendor's own page carries it. A page one level in is
    /// about a different reading and dates that one itself: the services page
    /// prints when the vendor was last asked, and a usage age beside it would
    /// be two clocks for two subjects with nothing saying which is which.
    ///
    /// `back` is what tells the two apart, because it already does: the page
    /// that returns to the Overview is the vendor's own.
    ///
    /// The plan badge is not here. It is a fact about the account, not about
    /// the page, and it reads as a qualifier on the provider's name when it
    /// sits against one — so it went down to the organisation line, which is
    /// the other half of the same sentence. The Overview's legend keeps its
    /// own badge: that row has no identity block to put one in.
    private func providerHeader(
        _ row: UsagePanelSnapshot.ProviderRow, live: SissyModel.LiveFrame?, back: Page
    ) -> some View {
        subpageHeader(
            back: back,
            mark: row.id,
            title: row.name
        ) {
            if back == .overview, let live {
                readingLine(
                    live, holding: nil,
                    refreshing: model.engine.refreshing.contains(row.id))
            }
        } trailing: {
            refreshButton(help: UsageFormat.refreshHelp(row.id)) {
                model.engine.refreshProvider(row.id)
            }
        }
    }

    /// Styled as a switch rather than a footer glyph: it says what the
    /// machine is doing, and a link's styling made it read as navigation.
    ///
    /// Colour carries the two axes separately. The glass tints while the Mac
    /// is actually being held; a mode that is armed and holding nothing keeps
    /// the tinted glyph without the tinted glass, so "armed" and "holding"
    /// stay legible apart. That second state has two causes — an automatic
    /// hold waiting for the agents to do something, and an assertion power
    /// management refused — and they look alike because they are alike: the
    /// Mac is free to sleep either way. The tooltip is what separates them.
    ///
    /// Blue rather than the amber it started as, for two reasons that agree.
    /// Claude's own mark is coral and renders a few points away in the same
    /// header, so a warm switch beside it read as something to do with that
    /// provider. And on this platform orange is the colour of caution — the
    /// energy-impact column, the recording dot — where blue is the colour of
    /// a control that is engaged, which is what this is. `.blue` rather than
    /// a literal, so it is the system's own and follows the appearance.
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
                .foregroundStyle(state.mode == .off ? Color.secondary : Color.blue)
                .contentShape(.circle)
        } primaryAction: {
            model.setKeepAwake(state.mode == .off ? model.preferredKeepAwakeMode : .off)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(
            state.active ? .regular.tint(.blue.opacity(Self.heldGlassTint)) : .regular,
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
            return UsageFormat.emptyLogTrees(
                model.engine.providers.filter(\.activation.isMetering).map {
                    ($0.dataDir.path as NSString).abbreviatingWithTildeInPath
                })
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
