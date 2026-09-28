import SwiftUI

/// How a level colours the reading it belongs to, on the Overview's line and
/// on the page behind it alike.
///
/// Orange rather than the system's yellow for a warning, which is the colour
/// the rest of the panel already warns in — the identity mark, a gauge past
/// its threshold — and the one of the two that reads on a light background:
/// yellow text on the popover's light material is the contrast the platform
/// itself avoids. Red is the kernel's critical, and it takes the weight up a
/// step as well, so the one state worth stopping for is not colour alone.
enum MacLevelStyle {
    static func tint(_ level: MacHealthLevel?, resting: Color = .secondary) -> Color {
        switch level {
        case .warn: .orange
        case .critical: .red
        case .normal, nil: resting
        }
    }

    static func weight(_ level: MacHealthLevel?) -> Font.Weight {
        level == .critical ? .semibold : .regular
    }

    /// A figure as one styled run, which the Overview interpolates into its
    /// line and the page sets in a row.
    static func text(_ figure: UsagePanelSnapshot.MacFigure, resting: Color = .secondary) -> Text {
        Text(figure.text)
            .foregroundStyle(tint(figure.level, resting: resting))
            .fontWeight(weight(figure.level))
    }
}

/// What the Mac itself is answering: the kernel's memory pressure and what
/// sits under it, and the apps holding the most besides the agents.
///
/// **A page of its own rather than rows on the agents page**, which answers
/// what the CLIs are holding. This answers whether the Mac can keep up, and a
/// Mac can be struggling with no agent running at all.
///
/// **Fixed in height.** Every section has a fixed number of rows — three
/// figures under the memory, at most three apps — so the page is the same
/// size on the day the Mac froze as on a quiet one, and nothing on it moves
/// under the pointer as the samples land.
///
/// **A tab rather than a page one level in**, as of the panel's tabs: the
/// memory headline leads it on the popover itself, the way the day's cost
/// leads Usage, and the figures under it stand on platters. How old the
/// sample is rides the caption under the headline, since the header above
/// belongs to the whole panel and dates the usage reading.
///
/// The host goes with the popover when it closes, so the caption's clock
/// costs nothing while nobody is looking.
struct PanelMac: View {
    let block: UsagePanelSnapshot.MacBlock

    private static let rowSpacing: CGFloat = 7
    private static let captionSize: CGFloat = 11
    /// Matches the panel header's: the first minute of an age is worded in
    /// seconds.
    private static let clockTick: TimeInterval = 1
    private static let rowSize: CGFloat = 12
    private static let stepSize: CGFloat = 10
    private static let stepGap: CGFloat = 3
    private static let trackOpacity: Double = 0.15

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
            VStack(alignment: .leading, spacing: PanelMetrics.platterGap) {
                PanelGroup {
                    VStack(alignment: .leading, spacing: PanelMetrics.platterVerticalPadding) {
                        track
                        Divider()
                        VStack(alignment: .leading, spacing: Self.rowSpacing) {
                            row(
                                "Swap and disk",
                                value: MacLevelStyle.text(block.storage, resting: .primary))
                            row("Load", value: Text(block.load))
                            row("Up", value: Text(block.uptime))
                        }
                    }
                }
                if !block.heaviest.isEmpty {
                    heaviestSection(block.heaviest)
                }
            }
            .padding(.horizontal, PanelMetrics.platterInset)
            .padding(.bottom, PanelMetrics.platterInset)
        }
    }

    // MARK: Memory

    /// The kernel's word as the tab's one number, with the free share and the
    /// sample's age under it: the same rank and the same place as the day's
    /// cost on Usage.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(block.memory.text)
                .font(.system(size: PanelMetrics.headlineNumber, weight: .bold, design: .rounded))
                .foregroundStyle(headlineTint)
            TimelineView(.periodic(from: .now, by: Self.clockTick)) { context in
                Text(caption(now: context.date))
                    .font(.system(size: Self.captionSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.top, PanelMetrics.headlineTop)
        .padding(.bottom, PanelMetrics.headlineBottom)
    }

    private func caption(now: Date) -> String {
        let age = UsageFormat.macReading(observedAt: block.observedAt, now: now)
        guard let free = block.freeMemory else { return age }
        return free + " · " + age
    }

    /// Primary at normal, where the rest of the panel's headlines are, and
    /// secondary only for the dash: a secondary headline is how this panel
    /// draws a reading that has not happened, which a normal Mac has.
    private var headlineTint: Color {
        guard block.pressure != nil else { return .secondary }
        return MacLevelStyle.tint(block.pressure, resting: .primary)
    }

    /// The kernel's three steps, filled up to the one it is on, with their
    /// names under them so the bar reads without the headline.
    ///
    /// Steps rather than a gauge: the kernel answers a level and not a
    /// fraction, so a continuous fill would draw a precision nobody measured.
    /// An unread pressure fills nothing, which is the dash in the headline
    /// drawn as a bar.
    private var track: some View {
        VStack(spacing: 4) {
            HStack(spacing: Self.stepGap) {
                ForEach(MacHealthLevel.allCases, id: \.self) { step in
                    Capsule()
                        .fill(stepFill(step))
                        .frame(height: PanelMetrics.barHeight)
                }
            }
            HStack(spacing: Self.stepGap) {
                ForEach(MacHealthLevel.allCases, id: \.self) { step in
                    Text(UsageFormat.macLevel(step))
                        .font(.system(size: Self.stepSize))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: Self.stepAlignment(step))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.memory.text)
    }

    private func stepFill(_ step: MacHealthLevel) -> Color {
        guard let level = block.pressure, step <= level else {
            return Color.secondary.opacity(Self.trackOpacity)
        }
        return MacLevelStyle.tint(level)
    }

    private static func stepAlignment(_ step: MacHealthLevel) -> Alignment {
        switch step {
        case .normal: .leading
        case .warn: .center
        case .critical: .trailing
        }
    }

    private func row(_ label: String, value: Text) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: Self.rowSize))
    }

    // MARK: Heaviest

    /// The apps holding the most on this Mac once the agents and everything
    /// they started are taken out, which the agents page already answers for.
    /// Grouped by bundle, so an app's helpers are the app.
    private func heaviestSection(_ apps: [UsagePanelSnapshot.MacApp]) -> some View {
        PanelGroup {
            SectionLabel(text: "Heaviest besides the agents")
        } content: {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(apps) { app in
                    HStack(spacing: 6) {
                        Text(app.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(app.footprint)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.system(size: Self.rowSize))
                    .help(app.id)
                }
            }
        }
    }
}
