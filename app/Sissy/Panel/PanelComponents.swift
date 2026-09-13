import SwiftUI

/// Metrics every panel surface shares, so a page cannot drift a point away
/// from the one beside it.
enum PanelMetrics {
    static let width: CGFloat = 340
    static let gutter: CGFloat = 14
    static let barHeight: CGFloat = 5
    static let secondaryWindowOpacity: Double = 0.55
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
struct WindowRowView: View {
    let window: UsagePanelSnapshot.WindowRow
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                ShareBar(share: window.fraction, tint: tint, pace: window.pace)

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
struct ProjectRowView: View {
    let row: UsagePanelSnapshot.ProjectRow

    var body: some View {
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
            ShareBar(share: row.share, tint: .secondary)
        }
        .help(row.tooltip ?? "")
    }
}
