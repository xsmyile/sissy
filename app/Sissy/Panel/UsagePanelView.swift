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
/// bottom of the screen, so the page below the divider sits in a scroll view
/// bounded by what the screen leaves. A page that fits is untouched — the
/// scroll view is set to the page's own measured height and scrolling is
/// disabled — so the popover is the size it has always been on every Mac big
/// enough for it, which is every Mac the author owns.
///
/// Scrolling the header away instead would take the back chevron and the
/// controls with it, which is the one row that has to be reachable from
/// anywhere on the page.
struct UsagePanelView: View {
    let model: SissyModel
    /// How tall the panel may be on the screen it is opening on, which the
    /// controller resolves per showing. The panel sizes to its content under
    /// this and scrolls at it — a ceiling rather than a height, so a short
    /// page is exactly as tall as it was before there was one.
    let maxHeight: CGFloat

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

    enum Page: Equatable {
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
        /// How many agents have run and what the ones running now hold, one
        /// level in from the Overview's live line — which is the only door to
        /// it, and is therefore drawn whether or not anything is running.
        case stats
    }

    /// Cadence for both readouts the panel keeps on its own clock: the
    /// header's age and the keep-awake control's duration. A second is finer
    /// than the duration needs — it changes by the minute — but the tick is
    /// what decides how late a change lands, and a minute-long one would show
    /// the wrong minute for most of it.
    private static let clockTick: TimeInterval = 1
    private static let controlButtonSize: CGFloat = 26
    /// The back chevron's target, smaller than the round controls opposite it:
    /// it is a glyph on the text line rather than a button on glass, and a
    /// 26 pt box around it would make the header's left edge read as heavier
    /// than its right.
    private static let backButtonSize: CGFloat = 20
    /// Larger than the legend's, because the header's title is 13 pt semibold
    /// against the legend's 12 pt medium and it sits between a back chevron
    /// and a 26 pt button. A mark sized for the quieter row reads as an
    /// afterthought here.
    /// How far the glass under the keep-awake switch is tinted while a hold
    /// is in force. Enough to read as lit next to an untinted circle, short of
    /// a filled button — it is a state, not a selection.
    private static let heldGlassTint: Double = 0.22
    private static let headerMarkSize: CGFloat = 18
    private static let headerTitleSize: CGFloat = 13
    private static let sissySize: CGFloat = 24

    /// The provider the current page is about, when there is one and the frame
    /// still carries it.
    ///
    /// Which account the open page was aimed at, or nil on the Overview and
    /// for a vendor whose Overview row is not per account.
    private var openAccount: String? {
        switch page {
        case .overview, .identities, .stats: nil
        case .provider(_, let account), .services(_, let account),
            .projects(_, let account):
            account
        }
    }

    /// A provider can leave the frame while its page is open — the slices are
    /// today's spenders, and a day rolls over — so the page falls back home
    /// rather than rendering a row that no longer exists.
    static func openRow(_ page: Page, in providers: [UsagePanelSnapshot.ProviderRow])
        -> UsagePanelSnapshot.ProviderRow?
    {
        switch page {
        case .overview, .identities, .stats: return nil
        case .provider(let id, _), .services(let id, _):
            return providers.first { $0.id == id }
        case .projects(let id, _):
            guard let id else { return nil }
            return providers.first { $0.id == id }
        }
    }

    /// Switches the open page's vendor to another of its accounts, and moves
    /// the page with it: the page is addressed by provider id, so leaving it
    /// pointed at the account that was just switched away from would drop the
    /// user back to the overview on every switch.
    /// Picking an account is picking the account: the next `claude` in a
    /// terminal starts as it, and the identity and limits on the row follow.
    /// Sissy holds its own copy of every account it has seen, so the one being
    /// switched away from stays a click away.
    private func selectAccount(_ uuid: String) {
        model.engine.activateClaudeAccount(uuid: uuid)
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
    /// unfolded list is wanted on one page that usually is not — so this hangs
    /// off the page rather than off `UsagePanelSnapshot.make`.
    private func projectsPage(of frame: FrameData?) -> UsagePanelSnapshot.ProjectsPage? {
        guard case .projects(let provider, _) = page, let frame else { return nil }
        return UsagePanelSnapshot.projectsPage(frame: frame, provider: provider)
    }

    var body: some View {
        let live = model.liveFrame
        let snapshot = live.map {
            UsagePanelSnapshot.make(
                frame: $0.frame,
                period: model.preferences.usagePeriod,
                claudeAccounts: model.engine.claudeAccounts,
                limitsReading: model.preferences.limitsReading)
        }
        let open = Self.openRow(page, in: snapshot?.providers ?? [])
        let services = servicesReading(of: open)
        let projects = projectsPage(of: live?.frame)
        let identityFocus = Self.identityFocus(page)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let projects {
                    projectsHeader(projects)
                } else if let open {
                    providerHeader(
                        open, live: live,
                        back: services == nil
                            ? .overview : .provider(open.id, account: openAccount))
                } else if case .identities = page {
                    identitiesHeader
                } else if case .stats = page {
                    statsHeader
                } else {
                    header(live)
                }
                Divider()
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                headerHeight = $0
            }

            ScrollView(.vertical) {
                Group {
                    if let snapshot {
                        if let projects {
                            PanelProjectsPage(
                                page: projects,
                                openIdentities: { page = .identities(focus: $0) })
                        } else if case .identities = page {
                            PanelIdentities(rows: snapshot.identities, focus: identityFocus)
                        } else if case .stats = page {
                            PanelStats(block: snapshot.agents)
                        } else if let open, let services {
                            PanelProviderStatusPage(provider: open.id, row: services)
                        } else if let open {
                            let slice = live?.frame.providers.first { $0.id == open.id }
                            PanelProviderPage(
                                row: open,
                                openOnAccount: openAccount,
                                onSelectAccount: { selectAccount($0) },
                                onAddAccount: {
                                    // Which vendor's login opens is the page's
                                    // own id: the control sits on that
                                    // provider's account menu, so it can only
                                    // ever mean "another of these".
                                    if open.id == ProviderID.codex {
                                        model.engine.addCodexAccount()
                                    } else {
                                        model.engine.addClaudeAccount()
                                    }
                                },
                                switchFailure: model.engine.accountSwitchFailure,
                                switchingAccount: model.engine.switchingClaudeAccount,
                                refresh: { model.refreshProvider(open.id) },
                                openServices: {
                                    page = .services(open.id, account: $0)
                                },
                                openProjects: {
                                    page = .projects(open.id, account: $0)
                                },
                                openIdentities: { page = .identities(focus: $0) },
                                loadHistory: {
                                    await model.engine.usageHistorySeries(provider: $0)
                                },
                                todayTokens: slice?.tokens ?? 0,
                                todayCost: slice?.cost ?? 0
                            )
                        } else {
                            PanelOverview(
                                snapshot: snapshot,
                                meteringProviders: model.engine.providers.count {
                                    $0.activation.isMetering
                                },
                                openProvider: { page = .provider($0, account: $1) },
                                openProjects: { page = .projects(nil, account: nil) },
                                openIdentities: { page = .identities(focus: $0) },
                                selectPeriod: { model.setUsagePeriod($0) },
                                refreshingForge: model.engine.refreshingForge,
                                refreshForge: { model.refreshForge($0) },
                                openStats: { page = .stats }
                            )
                        }
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

    /// Which repository the identities page was opened about, if any.
    static func identityFocus(_ page: Page) -> String? {
        guard case .identities(let focus) = page else { return nil }
        return focus
    }

    /// The agents page's own header: the way back, the title, and a re-count.
    ///
    /// The button reaches the process sweep and not the counts: those come off
    /// the tail as turns land, where the sweep is on a 15 s clock and a user
    /// who has just closed three sessions is looking at a figure that is right
    /// and reads as wrong.
    private var statsHeader: some View {
        HStack(spacing: 8) {
            Button {
                page = .overview
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: Self.backButtonSize, height: Self.backButtonSize)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to today")

            Text("Agents")
                .font(.system(size: Self.headerTitleSize, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                model.engine.refreshAgentProcesses()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: Self.controlButtonSize, height: Self.controlButtonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .glassEffect(.regular, in: .circle)
            .help("Count the running agents again")
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    /// The identities page's own header: the way back, the title, and a
    /// re-read.
    ///
    /// The refresh is not a nicety here. A user on this page has usually just
    /// corrected a repository in a terminal, and waiting out a sweep interval
    /// to watch the row clear reads as the correction not having worked.
    private var identitiesHeader: some View {
        HStack(spacing: 8) {
            Button {
                page = .overview
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: Self.backButtonSize, height: Self.backButtonSize)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to today")

            Text("Identities")
                .font(.system(size: Self.headerTitleSize, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                model.engine.refreshIdentities()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: Self.controlButtonSize, height: Self.controlButtonSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .glassEffect(.regular, in: .circle)
            .help("Read every repository's commit identity again")
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 10)
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
        HStack(spacing: 8) {
            backButton(
                to: projects.provider.map { .provider($0, account: openAccount) } ?? .overview,
                help: Self.projectsBackHelp(projects.provider))

            if let provider = projects.provider {
                ProviderMark(id: provider, size: Self.headerMarkSize, textSize: nil)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Projects")
                    .font(.system(size: Self.headerTitleSize, weight: .semibold))
                    .lineLimit(1)
                Text(projects.subtitle)
                    .font(.system(size: PanelMetrics.headlineMeta))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    /// The way back, which every page one level in carries in the same corner
    /// at the same size. One control rather than one per header: a page that
    /// drew its own would be free to draw it a point off, and the chevron is
    /// the only thing on these headers a user has to find without looking.
    private func backButton(to destination: Page, help: String) -> some View {
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
        .help(help)
    }

    private static func projectsBackHelp(_ provider: String?) -> String {
        guard let provider else { return "Back to today" }
        return "Back to \(UsageFormat.providerName(provider))"
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
        HStack(spacing: 8) {
            backButton(
                to: back,
                help: back == .overview ? "Back to today" : "Back to \(row.name)")

            ProviderMark(id: row.id, size: Self.headerMarkSize, textSize: nil)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: Self.headerTitleSize, weight: .semibold))
                    .lineLimit(1)

                if back == .overview, let live {
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
    /// the tinted glyph without the tinted glass, so "armed" and "holding"
    /// stay legible apart.
    ///
    /// Blue rather than the amber it started as, for two reasons that agree.
    /// Claude's own mark is coral and renders a few points away in the same
    /// header, so a warm switch beside it read as something to do with that
    /// provider. And on this platform orange is the colour of caution — the
    /// energy-impact column, the recording dot — where blue is the colour of
    /// a control that is engaged, which is what this is. `.blue` rather than
    /// a literal, so it is the system's own and follows the appearance. That second state has two causes — an automatic hold
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
