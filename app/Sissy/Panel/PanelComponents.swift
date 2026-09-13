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
/// Width of the pace mark itself, and of the hole cut for it: the mark is
/// punched out of the bar rather than painted over it, because at 5 pt tall a
/// line drawn on top of a fill of similar weight disappears into it, and the
/// gap is what makes two points of colour read.
struct ShareBar: View {
    let share: Double
    let tint: Color
    var pace: UsagePanelSnapshot.Pace?

    private static let markWidth: CGFloat = 2
    private static let markGap: CGFloat = 5

    /// Where the mark's centre lands, kept a half-gap inside the bar so a
    /// window in its last minutes draws a whole mark instead of half of one.
    private func markCentre(_ pace: UsagePanelSnapshot.Pace, in width: CGFloat) -> CGFloat {
        let inset = Self.markGap / 2
        guard width > Self.markGap else { return width / 2 }
        return min(max(width * pace.expectedFraction, inset), width - inset)
    }

    /// Green under the mark and red over it, which is the whole reading: the
    /// bar says where you are, the mark says where even consumption would
    /// have put you, and the colour says which of the two is ahead.
    ///
    /// The two branches exist for the compositing group, not for the mark.
    /// Cutting the gap needs one; a bar without a mark must not pay for one,
    /// and the project rows and the share bars are most of the bars the panel
    /// draws.
    var body: some View {
        GeometryReader { geometry in
            let fill = max(geometry.size.width * share, share > 0 ? 3 : 0)
            if let pace {
                let centre = markCentre(pace, in: geometry.size.width)
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        body(fill: fill)
                        Capsule()
                            .frame(width: Self.markGap)
                            .offset(x: centre - Self.markGap / 2)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()

                    Capsule()
                        .fill(pace.isOverPace ? Color.red : Color.green)
                        .frame(width: Self.markWidth)
                        .offset(x: centre - Self.markWidth / 2)
                }
            } else {
                ZStack(alignment: .leading) {
                    body(fill: fill)
                }
            }
        }
        .frame(height: PanelMetrics.barHeight)
        .animation(.default, value: share)
    }

    @ViewBuilder
    private func body(fill: CGFloat) -> some View {
        Capsule()
            .fill(.quaternary)
        Capsule()
            .fill(tint.gradient)
            .frame(width: fill)
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
/// directory's name.
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
        .help(row.path ?? "")
    }
}
