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
    let share: Double
    let tint: Color
    var pace: UsagePanelSnapshot.Pace?

    var body: some View {
        BarCanvas(share: share, tint: tint, pace: pace)
            .frame(height: PanelMetrics.barHeight)
            .animation(.default, value: share)
    }
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
    var tint: Color
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
                context.fill(
                    Self.capsule(CGRect(x: 0, y: 0, width: fill, height: size.height)),
                    with: .style(tint.gradient))
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

    var body: some View {
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

            if let caption = UsageFormat.windowCaption(window) {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
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

/// One project's share of a day: the repository's own name, what it cost, and
/// a bar for its share. The path stays in the tooltip — a client's name is a
/// directory's name — and the remainder row puts its reason there instead.
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
    let row: UsagePanelSnapshot.ProjectRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
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
                Spacer(minLength: 0)
                Text("\(row.tokens) · \(row.cost)")
                    .font(.system(size: 12))
                    .monospacedDigit()
            }
            ShareBar(share: row.share, tint: .secondary)
        }
        .contentShape(.rect)
        .help(row.tooltip ?? "")
        .contextMenu { actions }
    }

    /// The mark only where there is a page behind it: a remote that names a
    /// port is pointing at a transport rather than at a site, and that row
    /// keeps its repository with no way out to it.
    @ViewBuilder
    private var forgeLink: some View {
        if let repository = row.repository, let page = repository.page {
            Link(destination: page) {
                ForgeMark(host: repository.host)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .pointerStyle(.link)
            .help("Open \(repository.label) on \(repository.host)")
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
        }
    }
}

/// The forge's own mark, where Sissy ships one.
///
/// Matched on the host *containing* the name rather than on an exact domain,
/// because a self-hosted GitLab is the ordinary case at work and
/// `gitlab.sermix.com` is as much GitLab as `gitlab.com` is. A forge that says
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
