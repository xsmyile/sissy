import SwiftUI

/// What the disks are reading and writing this second, and the last two
/// minutes of it, on the Disk tab under the home volume.
///
/// **Sampled once a second only while the Disk tab is on screen**, on
/// `PanelNetwork`'s terms: `UsagePanelView` asks for `LiveReading.disk` while
/// the tab is selected in an open panel, and with the tab gone the engine
/// reads the counters every five seconds and publishes nothing, so the line
/// opens on the last two minutes and never spans a gap nobody sampled.
///
/// **The one view that reads the sample.** `engine.diskActivityReading` is
/// read in this body and nowhere else, so a sample invalidates this platter
/// and not the page around it, and it does not ride the frame.
///
/// **Fixed in height**: the legend holds a dash where a figure is missing, so
/// nothing under the pointer moves at one sample a second.
struct DiskActivityPlatter: View {
    let engine: UsageEngineHost

    @State private var hovered: Int?

    /// 1 MB/s, under which the plot does not rescale: a disk answering its
    /// own housekeeping stays on the baseline rather than drawing it at full
    /// height.
    static let scaleFloor: Double = 1_000_000
    static let readTint = NetworkSparkline.downTint
    static let writeTint = NetworkSparkline.upTint
    private static let legendSize: CGFloat = 12
    private static let captionSize: CGFloat = 10

    var body: some View {
        let reading = engine.diskActivityReading
        let rates = reading?.rates ?? []
        let current = reading?.current
        return PanelGroup {
            SectionLabel(text: "Activity")
        } content: {
            VStack(alignment: .leading, spacing: PanelMetrics.platterVerticalPadding) {
                HStack(spacing: RateFigure.gap) {
                    RateFigure(text: UsageFormat.diskRead(current?.read), tint: Self.readTint)
                    RateFigure(text: UsageFormat.diskWrite(current?.written), tint: Self.writeTint)
                }
                .font(.system(size: Self.legendSize))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(current == nil ? Color.secondary : .primary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spokenRate(current))
                RateSparkline(
                    points: rates.map {
                        .init(at: $0.at, first: $0.rate.read, second: $0.rate.written)
                    },
                    now: reading?.observedAt ?? Date(), firstTint: Self.readTint,
                    secondTint: Self.writeTint, scaleFloor: Self.scaleFloor,
                    label: "Disk activity over the last two minutes",
                    figures: {
                        UsageFormat.diskRead(rates[$0].rate.read) + " · "
                            + UsageFormat.diskWrite(rates[$0].rate.written)
                    },
                    hovered: $hovered)
                Text("last 2 minutes")
                    .font(.system(size: Self.captionSize))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    static func spokenRate(_ rate: DiskRate?) -> String {
        guard let rate else { return "No rate yet" }
        return UsageFormat.diskRead(rate.read) + ", " + UsageFormat.diskWrite(rate.written)
    }
}
