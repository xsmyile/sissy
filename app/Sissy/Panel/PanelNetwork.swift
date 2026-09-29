import SwiftUI

/// What the Mac's links are carrying this second, the last two minutes of it,
/// and what they have carried since boot, or since the latest moment the
/// counters can be vouched for, see `NetworkTotals`.
///
/// **Sampled once a second only while this page is on screen.**
/// `UsagePanelView` asks for `LiveReading.network` while the tab is selected
/// in an open panel, and the engine samples once a second until the tab
/// switches or the panel closes; with the page gone the engine reads only the
/// byte counters, every five seconds, and publishes nothing, see
/// `LiveCadence`. So the page opens on the last two minutes, and the link and
/// the signal are read only while it is drawn.
///
/// **The one view that reads the sample.** `engine.networkReading` is read in
/// this body and nowhere else, so a sample invalidates this page and not the
/// panel around it: the frame, its snapshot and every other page are left
/// alone. Measured 2026-09-28 on a Mac16,8 running macOS 27.0, Debug build,
/// CPU clocks in an XCTest host: this page's update costs 1.4 to 2.4 ms of the
/// main thread a sample, the sparkline about 0.5 ms of it, where a frame
/// re-renders the panel around it for 1.9 to 2.0 ms and wakes the menu bar's
/// icon besides. Building `UsagePanelSnapshot` is not what a frame costs: it
/// takes 0.06 ms. End to end at one sample a second, the page on screen adds
/// 7.5 to 9.5 ms of process CPU a second, under 1% of a core, and after the
/// demand goes the process is back at its baseline.
///
/// **The headline does not shrink to fit.** `minimumScaleFactor` cost 0.9 ms
/// of that update, measured the same day, for a line that fits anyway:
/// `UsageFormat.networkRate` keeps every figure to three digits and a unit,
/// and the widest pair, `↓ 999 MB/s` and `↑ 999 MB/s`, measures 295 pt with
/// its swatches against the 312 pt a page has.
///
/// **Fixed in height** for `PanelMac`'s reason: the Signal row comes and goes
/// with the link, never with a sample, so nothing moves under the pointer at
/// one frame a second.
struct PanelNetwork: View {
    let engine: UsageEngineHost

    @State private var hovered: Int?

    private static let rowSpacing: CGFloat = 7
    private static let captionSize: CGFloat = 11

    var body: some View {
        let reading = engine.networkReading
        return PanelGroup {
            VStack(alignment: .leading, spacing: PanelMetrics.platterVerticalPadding) {
                headline(reading)
                NetworkSparkline(
                    rates: reading?.rates ?? [], now: reading?.observedAt ?? Date(), hovered: $hovered)
                Divider()
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    PanelFigureRow(
                        label: "Interface", value: UsageFormat.networkInterface(reading?.interface),
                        truncation: .middle)
                    if let wifi = reading?.wifi {
                        PanelFigureRow(
                            label: "Signal", value: UsageFormat.networkSignal(wifi), truncation: .middle)
                    }
                    PanelFigureRow(
                        label: UsageFormat.networkTotalsLabel(
                            reading?.totals, now: reading?.observedAt ?? Date()),
                        value: UsageFormat.networkTotals(reading?.totals), truncation: .middle)
                }
            }
        }
        .padding(PanelMetrics.platterInset)
    }

    /// Both directions as the tab's one reading, each beside the stroke its
    /// line is drawn in, which is the sparkline's legend: the figures keep the
    /// text's own colour and the swatch carries which series is which.
    private func headline(_ reading: NetworkReading?) -> some View {
        let current = reading?.current
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: RateFigure.gap) {
                RateFigure(text: UsageFormat.networkDown(current?.received), tint: NetworkSparkline.downTint)
                RateFigure(text: UsageFormat.networkUp(current?.sent), tint: NetworkSparkline.upTint)
            }
            .font(.system(size: PanelMetrics.headlineNumber, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(current == nil ? Color.secondary : .primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityRate(current))
            Text(UsageFormat.networkCaption(reading?.interface))
                .font(.system(size: Self.captionSize))
                .foregroundStyle(.secondary)
        }
    }

    private func accessibilityRate(_ rate: NetworkRate?) -> String {
        guard let rate else { return "No rate yet" }
        return "Receiving " + UsageFormat.networkRate(rate.received) + ", sending "
            + UsageFormat.networkRate(rate.sent)
    }

}

/// The last two minutes of both directions, drawn by `RateSparkline`.
///
/// Blue for down and cyan for up, checked 2026-09-28 against the dataviz
/// validator: adjacent colour-blind separation at ΔE 19.1 in light and 19.6 in
/// dark. Neither is a colour this panel warns in. The Disk tab draws its read
/// and write in the same pair, so the two tabs colour the same two ideas the
/// same way.
struct NetworkSparkline: View {
    let rates: [RatePoint<NetworkRate>]
    let now: Date
    @Binding var hovered: Int?

    static let downTint = Color.blue
    static let upTint = Color.cyan
    /// 100 KB/s, under which the plot does not rescale.
    static let scaleFloor: Double = 100_000

    var body: some View {
        RateSparkline(
            points: rates.map { .init(at: $0.at, first: $0.rate.received, second: $0.rate.sent) },
            now: now,
            firstTint: Self.downTint,
            secondTint: Self.upTint, scaleFloor: Self.scaleFloor,
            label: "Network rate over the last two minutes",
            figures: {
                UsageFormat.networkDown(rates[$0].rate.received) + " · "
                    + UsageFormat.networkUp(rates[$0].rate.sent)
            },
            hovered: $hovered)
    }
}
