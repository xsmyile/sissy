import AppKit
import SwiftUI

/// Metrics every panel surface shares, so a page cannot drift a point away
/// from the one beside it.
enum PanelMetrics {
    static let width: CGFloat = 340
    static let gutter: CGFloat = 14
    static let barHeight: CGFloat = 5
    /// The one number a headline block is about — the day's cost, and the
    /// headroom left on the window that binds first.
    ///
    /// One size for both, because they are the same rank of answer and a
    /// panel that drew the second larger than the first said otherwise. Bold
    /// rather than semibold: it buys back at 18 pt the presence the old 22
    /// and 26 had, and the points it gives up are the ones the block was
    /// spending on air.
    static let headlineNumber: CGFloat = 18
    /// Everything that qualifies a headline number rather than being one.
    static let headlineMeta: CGFloat = 11
    /// A provider's mark where it labels a row, and the text it sits beside.
    ///
    /// Sized against the text rather than against the dot it replaced: a mark
    /// has to be read as a picture, which takes more room than a disc that
    /// only had to be a colour. A legend row is the narrowest place one
    /// appears — it also carries a plan badge and the day's figures — so it
    /// takes the smaller of the two sizes the panel uses.
    static let markSize: CGFloat = 14
    static let rowText: CGFloat = 12
    /// How far a row's text sits inside the wash drawn behind it, so the band
    /// reads as a band rather than as a highlight clipped to the glyphs.
    static let washInset: CGFloat = 4
    /// The wash's corner, small enough that a share of a few percent still
    /// draws a shape with a straight edge to read its width off.
    static let washRadius: CGFloat = 4

    /// What the popover leaves itself between its content and the screen edge:
    /// the shadow, the corner radius, and enough that a page ending exactly on
    /// the boundary does not read as cut off.
    private static let screenMargin: CGFloat = 16
    /// The ceiling to assume when the screen cannot be named — a panel with no
    /// window yet, or a status item on a display AppKit has not reported.
    /// Deliberately the smallest Mac worth designing for rather than a
    /// generous guess: a page that scrolls when it did not have to is a
    /// nuisance, where one that runs off the bottom is unreachable.
    private static let fallbackMaxHeight: CGFloat = 640

    /// How tall the panel may be on the screen it is opening on.
    ///
    /// `visibleFrame` already excludes the menu bar and the Dock, which is the
    /// whole answer: the popover hangs off the status item and grows down, so
    /// what it has is what the menu bar leaves. Read per opening rather than
    /// cached — the menu bar moves with the display arrangement, and a ceiling
    /// measured on a 5K would follow the panel back onto the laptop screen.
    ///
    /// This replaces a per-section ceiling. Bounding one block meant a page
    /// gave up rows it had room for: measured on the author's own displays,
    /// `visibleFrame` is about 957 pt on the built-in 14" and 1415 pt on the
    /// external 5K, against a tallest-page reading of 690.5 pt — so the
    /// section was hiding projects to fit a screen nobody in front of it had.
    static func maxHeight(on screen: NSScreen?) -> CGFloat {
        guard let screen else { return fallbackMaxHeight }
        return max(screen.visibleFrame.height - screenMargin, 0)
    }
}

/// The panel's one bar, in both the jobs it does: a share of the day, and a
/// rate-limit gauge with the mark that says where even consumption would have
/// put it.
///
/// The mark is punched out of the bar rather than painted over it, because at
/// 5 pt tall a line drawn on top of a fill of similar weight disappears into
/// it, and the gap is what makes two points of colour read. The gap has to
/// reach the popover's material, so it cannot be painted in a background
/// colour — a hole is the only thing that shows vibrancy through.
///
/// That hole is cut with Core Graphics inside a single `Canvas` rather than
/// with SwiftUI's `.blendMode` and `.compositingGroup`. Those two modifiers
/// make RenderBox compile a Metal shader, which on macOS 26.x took the
/// *AppKit* status item icon down with it — measured by CodexBar, whose menu
/// bar icon is an `NSImage` like Sissy's, and whose fix for it was this same
/// rewrite. Sissy has not been seen to hit it; carrying a bar that cannot is
/// cheaper than finding out.
struct ShareBar: View {
    let segments: [BarSegment]
    let pace: UsagePanelSnapshot.Pace?

    init(share: Double, tint: Color, pace: UsagePanelSnapshot.Pace? = nil) {
        self.init(segments: [BarSegment(share: share, tint: tint)], pace: pace)
    }

    init(segments: [BarSegment], pace: UsagePanelSnapshot.Pace? = nil) {
        self.segments = segments
        self.pace = pace
    }

    private var share: Double { segments.reduce(0) { $0 + $1.share } }

    var body: some View {
        BarCanvas(share: share, segments: segments, pace: pace)
            .frame(height: PanelMetrics.barHeight)
            .animation(.default, value: share)
    }
}

/// One part of a bar that more than one thing contributed to.
///
/// Only the projects page draws more than one: a repository worked on through
/// both CLIs is a single row by design — `FrameBuilder.combinedProjects` sums
/// them — and the split is what says which of the two the money went to,
/// without costing the row a line or a legend. Every other bar on the panel is
/// one segment, which is what the share-and-tint initialiser makes.
struct BarSegment: Equatable {
    let share: Double
    let tint: Color
}

/// The bar's geometry, apart from its drawing, so the two placements it has to
/// get right can be asserted without rendering anything.
enum BarGeometry {
    static let markWidth: CGFloat = 2
    static let markGap: CGFloat = 5

    /// A share of nothing draws nothing; any share at all draws at least a
    /// stub, because a bar that rounds down to invisible reads as zero.
    static func fillWidth(_ share: Double, in width: CGFloat) -> CGFloat {
        min(max(width * share, share > 0 ? 3 : 0), width)
    }

    /// How wide each segment draws inside a fill `width` wide.
    ///
    /// Proportional to the shares rather than to the bar, so segments follow a
    /// total that is still animating instead of overrunning it. The last one
    /// takes whatever is left: three segments rounded independently leave a
    /// hairline of track showing inside a fill that is meant to be solid.
    ///
    /// A share of nothing keeps its place in the answer — the caller zips
    /// these against its own segments, so a dropped element would tint the
    /// wrong one.
    static func segmentWidths(_ shares: [Double], in width: CGFloat) -> [CGFloat] {
        let total = shares.reduce(0, +)
        guard total > 0, width > 0 else { return Array(repeating: 0, count: shares.count) }
        var widths: [CGFloat] = []
        var taken: CGFloat = 0
        for (index, share) in shares.enumerated() {
            guard index < shares.count - 1 else {
                widths.append(max(width - taken, 0))
                continue
            }
            let segment = max(width * CGFloat(share / total), 0)
            widths.append(segment)
            taken += segment
        }
        return widths
    }

    /// Where the mark's centre lands, kept a half-gap inside the bar so a
    /// window in its last minutes draws a whole mark instead of half of one.
    static func markCentre(_ expectedFraction: Double, in width: CGFloat) -> CGFloat {
        let inset = markGap / 2
        guard width > markGap else { return width / 2 }
        return min(max(width * expectedFraction, inset), width - inset)
    }
}

/// The whole bar in one `Canvas`: track, fill, the hole, and the mark in it.
///
/// `Animatable` on the view is what keeps the fill sliding rather than
/// snapping — a `Canvas` closure is not interpolated the way a shape's frame
/// is, so the view itself has to name the value SwiftUI should walk.
private struct BarCanvas: View, Animatable {
    var share: Double
    var segments: [BarSegment]
    var pace: UsagePanelSnapshot.Pace?

    nonisolated var animatableData: Double {
        get { share }
        set { share = newValue }
    }

    /// Green under the mark and red over it, which is the whole reading: the
    /// bar says where you are, the mark says where even consumption would
    /// have put you, and the colour says which of the two is ahead.
    var body: some View {
        Canvas { context, size in
            context.fill(
                Self.capsule(CGRect(origin: .zero, size: size)), with: .style(.quaternary))

            let fill = BarGeometry.fillWidth(share, in: size.width)
            if fill > 0 {
                Self.drawFill(
                    segments, in: CGRect(x: 0, y: 0, width: fill, height: size.height),
                    into: &context)
            }

            guard let pace else { return }
            let centre = BarGeometry.markCentre(pace.expectedFraction, in: size.width)

            context.blendMode = .destinationOut
            context.fill(
                Self.capsule(
                    Self.markRect(
                        centre: centre, width: BarGeometry.markGap, height: size.height)),
                with: .color(.white))

            context.blendMode = .normal
            context.fill(
                Self.capsule(
                    Self.markRect(
                        centre: centre, width: BarGeometry.markWidth, height: size.height)),
                with: .color(pace.isOverPace ? .red : .green))
        }
    }

    /// The fill, in one colour or in several.
    ///
    /// One segment is drawn as the capsule itself, which is what every bar but
    /// the projects page's is and what this drew before there were segments.
    /// Several need the capsule as a clip instead, because the rounded right
    /// end belongs to the fill rather than to the segment that happens to
    /// reach it — and the clip goes in a layer of its own so it cannot reach
    /// the pace mark, which is punched out of the whole bar afterwards.
    private static func drawFill(
        _ segments: [BarSegment], in rect: CGRect, into context: inout GraphicsContext
    ) {
        guard segments.count > 1 else {
            context.fill(
                Self.capsule(rect), with: .style((segments.first?.tint ?? .clear).gradient))
            return
        }
        context.drawLayer { layer in
            layer.clip(to: Self.capsule(rect))
            var x = rect.minX
            let widths = BarGeometry.segmentWidths(segments.map(\.share), in: rect.width)
            for (segment, width) in zip(segments, widths) {
                layer.fill(
                    Path(CGRect(x: x, y: rect.minY, width: width, height: rect.height)),
                    with: .style(segment.tint.gradient))
                x += width
            }
        }
    }

    private static func markRect(centre: CGFloat, width: CGFloat, height: CGFloat)
        -> CGRect
    {
        CGRect(x: centre - width / 2, y: 0, width: width, height: height)
    }

    private static func capsule(_ rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        return Path { $0.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius)) }
    }
}

/// The bar, its reading, and — once the window is old enough to project from
/// — the line that says whether that reading is ahead or behind.
///
/// `isBinding` lifts the one window the block leads on rather than sinking the
/// others: the label and the number go up a step, and nothing on any row goes
/// down one. Dimming the rest to 55% is what this replaced, and measured in
/// dark mode it put their label and caption at 0.30 alpha against the 0.25 macOS
/// draws disabled text at — so every window but one read as a control switched
/// off. The bar and its pace mark keep full strength on every row for the same
/// reason: the mark is the reading, and a reading nobody can see is worse than
/// no emphasis at all.
struct WindowRowView: View {
    let window: UsagePanelSnapshot.WindowRow
    let tint: Color
    let isBinding: Bool

    private var emphasis: Color { isBinding ? .primary : .secondary }
    private var weight: Font.Weight { isBinding ? .medium : .regular }
    /// The dash a rolled-over window prints, styled like the Overview's own:
    /// the absence of a reading is drawn a step quieter than a reading of any
    /// value, which is what keeps it from being read as one.
    private var readingStyle: AnyShapeStyle {
        window.hasRolledOver ? AnyShapeStyle(.tertiary) : AnyShapeStyle(emphasis)
    }

    /// The whole row ticks, rather than the caption inside it.
    ///
    /// The caption needs a clock: both its halves are durations now, and one
    /// built with the body is true only for as long as the body is — the
    /// engine coalesces emits, so a Mac nobody is typing on leaves the line
    /// sitting at "resets in 2h 27m" for as long as the panel is open. It is
    /// what `ForgeRowView.notice` does with its own age, for the same reason.
    ///
    /// Wrapping the caption alone is what that row can afford and this one
    /// cannot: a `TimelineView` is a child the stack spaces whether or not its
    /// content renders, and this caption is nil on a window the vendor has not
    /// started. Measured 2026-09-19 on this stack's shape at 312 pt, the two
    /// agree at 38.00 pt with a caption and read 22.00 against 25.00 without
    /// one — three points of gap under a bar with nothing to say. Around the
    /// body the conditional is a direct child again and both match the bare
    /// stack.
    ///
    /// A minute rather than `ForgeRowView`'s second, because `countdown`
    /// resolves to minutes and a tick nothing can see still costs a layout and
    /// a rasterization — the cost `UsagePanelController` drops the whole host
    /// to avoid paying while the panel is shut.
    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.captionTick)) { context in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(window.label)
                        .font(.system(size: 11, weight: weight))
                        .foregroundStyle(emphasis)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    Text(window.hasRolledOver ? "—" : window.reading)
                        .font(.system(size: 11, weight: weight))
                        .monospacedDigit()
                        .foregroundStyle(readingStyle)
                        .layoutPriority(1)
                }

                if !window.hasRolledOver {
                    ShareBar(share: window.fraction, tint: tint, pace: window.pace)
                }

                if let caption = UsageFormat.windowCaption(window, now: context.date) {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private static let captionTick: TimeInterval = 60
}

/// The account's plan, badged rather than set as plain text beside the name:
/// "Codex Plus" reads as a product OpenAI sells, and the pill is what says the
/// word is an attribute of the account instead. It yields its width first — of
/// the three things on that line, the plan is the one a reader can still infer
/// once it is gone.
///
/// `tier` is present only when the account is metered at some other plan's
/// limits, which is a sentence and not a badge.
struct PlanBadge: View {
    let plan: String
    let tier: String?

    var body: some View {
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
}

/// Why a provider's limits are missing, and the one click that can do
/// something about it.
///
/// On the surface rather than in the log, which is where it used to be: the
/// grant lapses every time Claude Code refreshes its own token, which left the
/// gauges gone and the only cure buried in Settings behind a switch the user
/// had to know to flip twice. A state nothing can be done about renders
/// without a button rather than with a dead one.
struct LimitsNoticeView: View {
    let notice: UsagePanelSnapshot.LimitsNotice
    let act: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(notice.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let action = notice.action {
                Spacer(minLength: 0)
                Button(action, action: act)
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .layoutPriority(1)
            }
        }
    }
}

/// The quiet label over a group of rows. One weight for every section, so the
/// eye can tell a heading from a row without reading it.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

/// A section label that is also the way into the page behind its list: how
/// long the list is, and the chevron every other row that navigates carries.
///
/// The count is the whole affordance. A chevron alone says there is somewhere
/// to go and not what is there, and the one thing a folded list cannot say
/// about itself is how much of it is missing.
struct ProjectsSectionLabel: View {
    let text: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            SectionLabel(text: text)
            Spacer(minLength: 8)
            Text(UsageFormat.projectsCount(count))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }
}

/// One project's share of a day: the repository's own name, what it cost, and
/// its share of the day, drawn wherever the surface puts it. The path stays in
/// the tooltip — a client's name is a directory's name — and the folded row,
/// standing for several, hovers nothing.
///
/// **The forge's mark sits after the name and is the way to the page.** It is
/// the one control on the row, it costs the row no height, and a row that has
/// no mark is saying something true — there is nothing to open — where a mark
/// placed *before* the name would push the names of repositories one step
/// right and leave every other row's starting at the gutter, which is the rule
/// the bars were given a line of their own to keep.
///
/// It replaced a `.popover` card and then a pull-down `Menu`, in two steps for
/// two reasons. The card because Apple's guidance forbids a popover inside a
/// popover — *"Never show a cascade or hierarchy of popovers, in which one
/// emerges from another"* (Human Interface Guidelines, Popovers) — and
/// `PanelProviderStatus` records what ignoring it cost the panel. The menu
/// because a pull-down opened over the rows below it, which is a lot of a
/// 340 pt panel spent on two items, and because macOS draws no icon in a
/// SwiftUI menu item, so the mark had nowhere to be there.
///
/// The two actions live on the **right-click**, which is where macOS puts a
/// row's own commands — *"a context menu lets people access a small number of
/// frequently used actions relevant to their current view or task"* (Human
/// Interface Guidelines, Menus) — and neither is the only way to anything: the
/// repository's name is on the row and its path is on the hover.
struct ProjectRowView: View {
    /// Under the row, or behind it.
    enum BarPlacement {
        case under
        case behind
    }

    let row: UsagePanelSnapshot.ProjectRow
    /// Whether the row says which CLIs its money went through.
    ///
    /// Only the projects page does, and only when it is about every provider:
    /// a vendor's own page has the answer in its title, and the Overview's
    /// list sits under a block of gauges whose bars are about rate-limit
    /// pressure — a second set of provider tints on the same screen, measuring
    /// money instead, is two readings in one colour.
    var showsProviders: Bool = false

    /// Where this surface draws the row's share of the day.
    ///
    /// The bar under the row is the panel's own vocabulary and it says the
    /// most: it is a track every row starts at the same x of, and on the
    /// projects page it carries the split in its segments. It also doubles
    /// the row's height, which is what a folded five-row section can least
    /// afford — so the two sections draw the same share as a wash behind the
    /// text, where it costs the row nothing but its own inset.
    var bar: BarPlacement = .under

    /// Opens this repository's commit identity, where there is a repository to
    /// open one for. On the right-click with the rest, which is where Apple's
    /// own guidance puts a small number of actions relevant to the current
    /// view — and a menu is the system's mechanism rather than a window of
    /// Sissy's, so it cannot resize the panel underneath it.
    var checkIdentity: (() -> Void)?

    var body: some View {
        placed
            .contentShape(.rect)
            .help(row.tooltip ?? "")
            .contextMenu { actions }
    }

    /// The row's line, with its share wherever this surface puts it.
    @ViewBuilder
    private var placed: some View {
        switch bar {
        case .under:
            VStack(alignment: .leading, spacing: 5) {
                line
                ShareBar(segments: segments)
            }
        case .behind:
            line
                .padding(.vertical, PanelMetrics.washInset)
                .background(alignment: .leading) { wash }
        }
    }

    private var line: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                if let owner = row.owner {
                    Text(owner + "/")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            forgeLink
            providerMarks
            Spacer(minLength: 0)
            Text("\(row.tokens) · \(row.cost)")
                .font(.system(size: 12))
                .monospacedDigit()
        }
    }

    /// The same share the bar would draw, as a band under the text.
    ///
    /// `BarGeometry.fillWidth` rather than a plain multiplication, so a
    /// repository that cost a fraction of a percent still draws the stub the
    /// bar gives it: a band that rounds down to nothing reads as a row that
    /// spent nothing.
    private var wash: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(
                cornerRadius: PanelMetrics.washRadius, style: .continuous)
            ZStack(alignment: .leading) {
                shape.fill(.quinary)
                shape.fill(.quaternary)
                    .frame(width: BarGeometry.fillWidth(row.share, in: proxy.size.width))
            }
        }
        .padding(.horizontal, -PanelMetrics.washInset)
        .animation(.default, value: row.share)
    }

    /// The CLIs that spent on this row, after its name for the reason the
    /// forge mark is: a glyph in front of the name would start every row's
    /// name one step right of the gutter its bar starts at.
    ///
    /// At `PanelMetrics.markSize`, which is what the Overview labels a
    /// provider's own row with — not at the forge mark's size beside it.
    /// Sizing it to its neighbour was tried and shipped for a build, and it
    /// read as too small to name: the two marks answer different questions,
    /// and a vendor's is one a reader recognises rather than reads. A glyph
    /// that has to be looked at twice has said nothing.
    @ViewBuilder
    private var providerMarks: some View {
        if showsProviders {
            ForEach(row.providers) { provider in
                ProviderMark(id: provider.id)
                    .help(UsageFormat.providerName(provider.id))
            }
        }
    }

    /// The bar, split by provider where the row says who spent. The folded
    /// row stands for no single repository, so it names no provider and keeps
    /// the one quiet bar it has always had.
    private var segments: [BarSegment] {
        guard showsProviders, !row.providers.isEmpty else {
            return [BarSegment(share: row.share, tint: .secondary)]
        }
        return row.providers.map {
            BarSegment(share: $0.share, tint: ProviderPalette.tint(for: $0.id))
        }
    }

    /// The mark only where there is a page behind it: a remote that names a
    /// port is pointing at a transport rather than at a site, and that row
    /// keeps its repository with no way out to it.
    ///
    /// The mark is a picture with no words in it, so the sentence the pointer
    /// gets is the sentence VoiceOver gets: a link whose label is its own
    /// image reads as "link" and nothing else.
    @ViewBuilder
    private var forgeLink: some View {
        if let repository = row.repository, let page = repository.page {
            Link(destination: page) {
                ForgeMark(host: repository.host)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .pointerStyle(.link)
            .help(Self.openHelp(repository))
            .accessibilityLabel(Self.openHelp(repository))
        }
    }

    /// The repository's page and its path — and nothing at all for a row that
    /// names no repository, whose tooltip is a reason rather than a path, so a
    /// menu offering to copy it would be offering the wrong thing. Returning
    /// nothing is also what deactivates the right-click.
    @ViewBuilder
    private var actions: some View {
        if let repository = row.repository {
            if let page = repository.page {
                Link(destination: page) {
                    Text("Open on \(repository.host)")
                }
            }
            if let path = row.tooltip {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
            if let checkIdentity {
                Divider()
                Button("Check Identity…", action: checkIdentity)
            }
        }
    }

    private static func openHelp(_ repository: UsagePanelSnapshot.RepositoryLink) -> String {
        "Open \(repository.label) on \(repository.host)"
    }
}

/// One connected forge's contribution count, with the account that answered.
///
/// The mark and the login rather than the mark alone, because the mark says
/// which forge and only the login says whose figures these are — and that is
/// not a detail a CLI's configuration can be trusted with: measured
/// 2026-09-17, `gh` had one account's name in its own file against a token that
/// answered as another. A row that printed 115 with no name could not have
/// shown that.
///
/// **A reading that is missing gets a dash and a reason, never a zero.** It is
/// the rule the provider gauges are on — an empty gauge is a measurement and
/// this is the absence of one — and here it has a second, measured reason: this
/// user's own GitLab is reached over a tunnel, so a laptop off the VPN would
/// otherwise report a day with no work in it. A reading that arrived and has
/// since gone stale keeps its figures and says so in the caption, because
/// figures that were true an hour ago plus their age is a better answer than an
/// error where a number was.
///
/// **Every row is dated, not only the ones that went wrong.** The poll is on a
/// five- to thirty-minute cadence and these counters move the moment the user
/// pushes, so a figure with no date on it cannot be told from one taken before
/// the merge they are looking for. The right-click re-reads that one
/// connection, which is also the only way back from a token parked on a
/// refusal that has since passed; the tooltip names the gesture, since nothing
/// on the row can.
struct ForgeRowView: View {
    let row: UsagePanelSnapshot.ForgeRow
    let refreshing: Bool
    let refresh: () -> Void

    private static let noticeSize: CGFloat = 11
    /// Matches the panel header's, for the reason that one is a second rather
    /// than a minute: the first minute of an age is worded in seconds.
    private static let clockTick: TimeInterval = 1
    private static let refreshItem = "Refresh now"
    /// Smaller than `PanelMetrics.markSize`, which labels a whole provider: a
    /// mark that qualifies one number on a line has to read as part of that
    /// number rather than as the row's own badge.
    private static let markSize: CGFloat = 10
    /// Semibold rather than the body weight, and chosen per glyph rather than
    /// once for the row.
    ///
    /// The target is the ink the marks beside it already lay down: measured
    /// 2026-09-17, `ForgeMark` at 11 pt covers 11.00 × 10.75 and `ProviderMark`
    /// at 14 pt covers 11.12 × 11.25, which `smallcircle.filled.circle` at
    /// 10 pt semibold hits exactly at 11.00 × 11.00 — three nominal sizes for
    /// one optical one, because a template asset and an SF Symbol do not
    /// measure the same at the same point size. A single weight for every mark
    /// would be wrong in the other direction: the same circle in bold measures
    /// 10.38, since SF redraws it rather than thickening it.
    private static let markWeight: Font.Weight = .semibold
    private static let markGap: CGFloat = 3
    private static let figureGap: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ForgeMark(host: row.host)
                    .foregroundStyle(.secondary)
                Text(row.login ?? row.host)
                    .font(.system(size: PanelMetrics.rowText, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                figures
            }
            notice
        }
        .contentShape(.rect)
        .help(row.tooltip)
        .contextMenu {
            Button(Self.refreshItem, action: refresh)
                .disabled(refreshing)
        }
        .accessibilityElement(children: .combine)
    }

    /// How old the figures are, on the row's own clock.
    ///
    /// `TimelineView` rather than a string the snapshot already built: this
    /// block's frame arrives every five to thirty minutes, so an age taken
    /// from it would sit at "read 2m ago" for half an hour under an open
    /// panel. It is what `PanelProviderStatus` does with `checkedAt`, and the
    /// two lines are the same reading for the same reason.
    private var notice: some View {
        TimelineView(.periodic(from: .now, by: Self.clockTick)) { context in
            if let notice = UsageFormat.forgeNotice(
                row.failure, readAt: row.readAt, refreshing: refreshing, now: context.date)
            {
                Text(notice)
                    .font(.system(size: Self.noticeSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// The contributions bare, the other three behind their own mark.
    ///
    /// Bare because the contribution total is what the section label already
    /// names, so a mark on it would qualify nothing; the three beside it are
    /// different readings on the same line and a glyph is what tells them
    /// apart without spending the row a word each — `merged` alone was seven
    /// characters of a line 340 pt wide has to fit a login into as well.
    ///
    /// Four figures still leave the name most of the row: measured 2026-09-18
    /// against the 312 pt inside the gutters, the widest real reading on this
    /// machine takes 121.6 pt over three figures and 170.3 over four, so the
    /// comment counter costs the line 48.7 pt and leaves 116.7 for the login —
    /// which a 17-character one (`smyile-radonforge`, 106.9 pt) still fits.
    /// Past roughly nineteen characters the login truncates and the figures do
    /// not, which is the right way round — `Spacer(minLength:)` and the name's
    /// own `lineLimit(1)` make the label yield before the reading does.
    @ViewBuilder
    private var figures: some View {
        if row.hasFigures {
            HStack(spacing: Self.figureGap) {
                if let contributions = row.contributions { count(contributions) }
                if let merged = row.merged {
                    marked(
                        merged, symbol: ProviderPalette.forgeSymbol(.merged),
                        tint: ProviderPalette.forgeTint(.merged),
                        help: row.mergedHelp)
                }
                if let issues = row.issues {
                    marked(
                        issues, symbol: ProviderPalette.forgeSymbol(.issues),
                        tint: ProviderPalette.forgeTint(.issues),
                        help: row.issuesHelp)
                }
                if let comments = row.comments {
                    marked(
                        comments, symbol: ProviderPalette.forgeSymbol(.comments),
                        tint: ProviderPalette.forgeTint(.comments), help: row.commentsHelp)
                }
            }
        } else {
            Text("—")
                .font(.system(size: PanelMetrics.rowText))
                .foregroundStyle(.tertiary)
        }
    }

    private func count(_ value: String) -> some View {
        Text(value)
            .font(.system(size: PanelMetrics.rowText))
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    /// One figure and the mark that says what it counts, with the meaning on
    /// the hover: a glyph is recognised before it is read and read by nobody
    /// who has not met it, and this row is where someone meets it.
    private func marked(
        _ value: String, symbol: String, tint: Color, help: String
    ) -> some View {
        HStack(spacing: Self.markGap) {
            Image(systemName: symbol)
                .font(.system(size: Self.markSize, weight: Self.markWeight))
                .foregroundStyle(tint)
                .accessibilityLabel(help)
            count(value)
        }
        .help(help)
    }
}

/// The forge's own mark, where Sissy ships one.
///
/// Matched on the host *containing* the name rather than on an exact domain,
/// because a self-hosted GitLab is the ordinary case at work and
/// `gitlab.example.com` is as much GitLab as `gitlab.com` is. A forge that says
/// neither — a GitHub Enterprise on a company domain, a Gitea — gets the
/// generic branch glyph rather than a guess between the two, which is the same
/// answer `ProviderMark` gives a provider it ships no asset for.
///
/// Template assets, so the mark takes the colour of the line it sits on and
/// one file serves light and dark.
struct ForgeMark: View {
    let host: String

    private static let size: CGFloat = 11

    var body: some View {
        mark
            .resizable()
            .scaledToFit()
            .frame(width: Self.size, height: Self.size)
    }

    private var mark: Image {
        guard let asset = Self.assetName(forHost: host) else {
            return Image(systemName: Self.genericSymbol)
        }
        return Image(asset)
    }

    /// Which mark a host gets, or nil for the generic glyph.
    ///
    /// GitHub is looked for first, so a host naming both — a mirror called
    /// `github.gitlab.example.com` — answers the one it leads with rather than
    /// whichever the compiler reached first.
    static func assetName(forHost host: String) -> String? {
        let host = host.lowercased()
        if host.contains(Self.gitHubName) { return "ForgeMarkGitHub" }
        if host.contains(Self.gitLabName) { return "ForgeMarkGitLab" }
        return nil
    }

    private static let gitHubName = "github"
    private static let gitLabName = "gitlab"
    private static let genericSymbol = "arrow.triangle.branch"
}
