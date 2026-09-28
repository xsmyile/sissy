import SwiftUI

/// What the disks answer: the home volume against the two steps Sissy grades
/// it by, what the system could hand back from it, and every other volume.
///
/// **A tab of its own rather than a row on the Mac's**, as of 2026-09-28: the
/// Mac tab answers the kernel's memory, and the disk is the one level Sissy
/// grades itself, on figures a row had no room to explain. Its badge is the
/// disk's alone, while the menu bar's dot still wears the worse of the two.
///
/// Laid out like `PanelMac`: the headline leads the first platter above the
/// bar it captions, the rows sit under a divider, and the volumes stand on a
/// platter of their own. The host goes with the popover when it closes, so
/// the caption's clock costs nothing while nobody is looking.
struct PanelDisk: View {
    let block: UsagePanelSnapshot.DiskBlock

    private static let rowSpacing: CGFloat = 7
    private static let volumeSpacing: CGFloat = 4
    private static let captionSize: CGFloat = 11
    private static let legendSize: CGFloat = 10
    /// Matches `PanelMac`'s: the first minute of an age is worded in seconds.
    private static let clockTick: TimeInterval = 1
    private static let rowSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.platterGap) {
            PanelGroup {
                VStack(alignment: .leading, spacing: PanelMetrics.platterVerticalPadding) {
                    headline
                    VStack(alignment: .leading, spacing: 4) {
                        DiskBar(
                            used: block.used,
                            marks: [
                                block.warnMark.map { ($0, MacHealthLevel.warn) },
                                block.criticalMark.map { ($0, MacHealthLevel.critical) },
                            ].compactMap { $0 },
                            tint: MacLevelStyle.tint(block.free.level))
                        Text(block.thresholds)
                            .font(.system(size: Self.legendSize))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(block.free.text)
                    .accessibilityValue(block.thresholds)
                    Divider()
                    VStack(alignment: .leading, spacing: Self.rowSpacing) {
                        row("Purgeable", value: block.purgeable)
                        row("Swap", value: block.swap)
                    }
                }
            }
            if !block.volumes.isEmpty {
                volumesSection
            }
        }
        .padding(PanelMetrics.platterInset)
    }

    // MARK: Home volume

    /// The free space as the tab's one number, in the level's colour, with
    /// what it is out of and the read's age under it.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(block.free.text)
                .font(.system(size: PanelMetrics.headlineNumber, weight: .bold, design: .rounded))
                .foregroundStyle(headlineTint)
            TimelineView(.periodic(from: .now, by: Self.clockTick)) { context in
                Text(caption(now: context.date))
                    .font(.system(size: Self.captionSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func caption(now: Date) -> String {
        let age = UsageFormat.diskReading(observedAt: block.observedAt, now: now)
        guard let volume = block.volume else { return age }
        return volume + " · " + age
    }

    /// Primary at normal and secondary only for the dash, on `PanelMac`'s
    /// rule for its own headline.
    private var headlineTint: Color {
        guard block.free.level != nil else { return .secondary }
        return MacLevelStyle.tint(block.free.level, resting: .primary)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: Self.rowSize))
    }

    // MARK: Volumes

    /// Every other volume, with no level: a multiple of RAM grades the volume
    /// swap grows into and says nothing about an external drive.
    private var volumesSection: some View {
        PanelGroup {
            SectionLabel(text: "Volumes")
        } content: {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(block.volumes) { volume in
                    VStack(alignment: .leading, spacing: Self.volumeSpacing) {
                        HStack(spacing: 6) {
                            Text(volume.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(volume.free)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.system(size: Self.rowSize))
                        ShareBar(share: volume.used, tint: .secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// The home volume's used share, with a mark where each step begins.
///
/// The marks are cut out of the bar the way the usage gauges cut their pace
/// mark, in the colour of the step they open, so a fill that has passed the
/// orange one is a disk at warn without reading the legend.
private struct DiskBar: View {
    let used: Double
    let marks: [(share: Double, level: MacHealthLevel)]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Self.capsule(bounds), with: .style(.quaternary))
            let fill = BarGeometry.fillWidth(used, in: size.width)
            if fill > 0 {
                context.fill(
                    Self.capsule(CGRect(x: 0, y: 0, width: fill, height: size.height)),
                    with: .style(tint.gradient))
            }
            for mark in marks {
                let centre = BarGeometry.markCentre(mark.share, in: size.width)
                context.blendMode = .destinationOut
                context.fill(
                    Self.capsule(Self.markRect(centre, BarGeometry.markGap, size.height)),
                    with: .color(.white))
                context.blendMode = .normal
                context.fill(
                    Self.capsule(Self.markRect(centre, BarGeometry.markWidth, size.height)),
                    with: .color(MacLevelStyle.tint(mark.level)))
            }
        }
        .frame(height: PanelMetrics.barHeight)
    }

    private static func markRect(_ centre: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: centre - width / 2, y: 0, width: width, height: height)
    }

    private static func capsule(_ rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        return Path { $0.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius)) }
    }
}
