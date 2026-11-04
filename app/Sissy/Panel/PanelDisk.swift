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
/// bar it captions, what macOS can free sits under a divider, and the volumes
/// stand on a platter of their own. Swap is the Mac tab's, which samples it
/// with the memory. The host goes with the popover when it closes, so
/// the caption's clock costs nothing while nobody is looking.
struct PanelDisk: View {
    let block: UsagePanelSnapshot.DiskBlock
    let engine: UsageEngineHost

    private static let rowSpacing: CGFloat = 7
    private static let volumeSpacing: CGFloat = 4
    private static let legendSize: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.platterGap) {
            PanelGroup {
                VStack(alignment: .leading, spacing: PanelMetrics.platterVerticalPadding) {
                    headline
                    VStack(alignment: .leading, spacing: 4) {
                        BarCanvas(
                            share: block.used,
                            segments: [
                                BarSegment(share: block.used, tint: MacLevelStyle.tint(block.free.level))
                            ],
                            marks: marks
                        )
                        .frame(height: PanelMetrics.barHeight)
                        Text(block.thresholds)
                            .font(.system(size: Self.legendSize))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(block.free.text)
                    .accessibilityValue(block.thresholds)
                    Divider()
                    PanelFigureRow(label: "macOS can free", value: block.purgeable)
                        .help(UsageFormat.diskPurgeableHelp)
                }
            }
            DiskActivityPlatter(engine: engine)
            if !block.volumes.isEmpty {
                volumesSection
            }
        }
        .padding(PanelMetrics.platterInset)
    }

    // MARK: Home volume

    /// A mark where each step begins, in the colour of the step it opens, so a
    /// fill that has passed the orange one is a disk at warn without reading
    /// the legend.
    private var marks: [BarMark] {
        [
            block.warnMark.map { BarMark(share: $0, tint: MacLevelStyle.tint(.warn)) },
            block.criticalMark.map { BarMark(share: $0, tint: MacLevelStyle.tint(.critical)) },
        ].compactMap { $0 }
    }

    /// The free space as the tab's one number, in the level's colour, with
    /// what it is out of and the read's age under it.
    private var headline: some View {
        LevelHeadline(
            figure: block.free.text, level: block.free.level, captionLineLimit: 1,
            caption: caption(now:))
    }

    private func caption(now: Date) -> String {
        let age = UsageFormat.diskReading(observedAt: block.observedAt, now: now)
        guard let volume = block.volume else { return age }
        return volume + " · " + age
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
                        PanelFigureRow(label: volume.name, value: volume.free, emphasizesLabel: true)
                        ShareBar(share: volume.used, tint: .secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
