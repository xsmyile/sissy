import SwiftUI

/// What the disks are reading and writing this second, and the last two
/// minutes of it, on the Disk tab under the home volume.
///
/// **Sampled only while the Disk tab is on screen**, on `PanelNetwork`'s
/// terms: `UsagePanelView` asks for `LiveReading.disk` while the tab is
/// selected in an open panel, and the engine samples once a second until the
/// tab switches or the panel closes, so the line starts empty on every
/// opening and never spans minutes nobody watched.
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
    private static let swatchWidth: CGFloat = 10
    private static let swatchHeight: CGFloat = 3
    private static let figureGap: CGFloat = 14

    var body: some View {
        let rates = engine.diskActivityReading?.rates ?? []
        let current = rates.last
        return PanelGroup {
            SectionLabel(text: "Activity")
        } content: {
            VStack(alignment: .leading, spacing: PanelMetrics.platterVerticalPadding) {
                HStack(spacing: Self.figureGap) {
                    figure(UsageFormat.diskRead(current?.read), tint: Self.readTint)
                    figure(UsageFormat.diskWrite(current?.written), tint: Self.writeTint)
                }
                .font(.system(size: Self.legendSize))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(current == nil ? Color.secondary : .primary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spokenRate(current))
                RateSparkline(
                    points: rates.map { ($0.read, $0.written) }, firstTint: Self.readTint,
                    secondTint: Self.writeTint, scaleFloor: Self.scaleFloor,
                    label: "Disk activity over the last two minutes",
                    figures: {
                        UsageFormat.diskRead(rates[$0].read) + " · "
                            + UsageFormat.diskWrite(rates[$0].written)
                    },
                    hovered: $hovered)
                Text("last 2 minutes, only while this tab is open")
                    .font(.system(size: Self.captionSize))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func figure(_ text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(tint)
                .frame(width: Self.swatchWidth, height: Self.swatchHeight)
            Text(text)
                .contentTransition(.numericText())
        }
    }

    static func spokenRate(_ rate: DiskRate?) -> String {
        guard let rate else { return "No rate yet" }
        return UsageFormat.diskRead(rate.read) + ", " + UsageFormat.diskWrite(rate.written)
    }
}
