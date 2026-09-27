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
/// It keeps no clock and observes nothing of its own: the header's age is the
/// panel's `TimelineView`, and the host goes with the popover when it closes.
struct PanelMac: View {
    let block: UsagePanelSnapshot.MacBlock

    private static let sectionSpacing: CGFloat = 16
    private static let labelSpacing: CGFloat = 10
    private static let rowSpacing: CGFloat = 7
    private static let headlineSize: CGFloat = 18
    private static let captionSize: CGFloat = 11
    private static let rowSize: CGFloat = 12
    private static let stepSize: CGFloat = 10
    private static let stepGap: CGFloat = 3
    private static let trackOpacity: Double = 0.15

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            memory
            if !block.heaviest.isEmpty {
                Divider()
                heaviestSection(block.heaviest)
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    // MARK: Memory

    private var memory: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            SectionLabel(text: "Memory")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(block.memory.text)
                    .font(.system(size: Self.headlineSize, weight: .bold, design: .rounded))
                    .foregroundStyle(headlineTint)
                if let free = block.freeMemory {
                    Text(free)
                        .font(.system(size: Self.captionSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            track
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                row("Swap and disk", value: MacLevelStyle.text(block.storage, resting: .primary))
                row("Load", value: Text(block.load))
                row("Up", value: Text(block.uptime))
            }
            .padding(.top, 2)
        }
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
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            SectionLabel(text: "Heaviest besides the agents")
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
