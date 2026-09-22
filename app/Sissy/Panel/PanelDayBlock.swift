import SwiftUI

/// Today's figure, the days behind it for scale, and the split by model of
/// whichever of them the pointer is on.
///
/// **A view of its own, because the hover belongs inside it.** The pointed day
/// is read by two blocks — the strip swaps its caption for that day's figures,
/// the pills swap for that day's split — so the state has to sit above both or
/// they can word different days. Above both was briefly the provider page, and
/// that made every pointer transition re-evaluate the whole page: the account
/// menu, the limit gauges, the credits bar and the project list, none of which
/// a hover changes. One sweep of the strip is up to fourteen transitions. Here
/// the state is above both readers and below everything else, which is the
/// scope the strip's own `@State` had before the pills needed to see it.
///
/// `strip` arrives built rather than derived here for the same reason: it is a
/// function of the archive and the frame, neither of which a hover moves, and
/// rebuilding it per transition folded seven days of models to use one.
struct PanelDayBlock: View {
    let today: String
    let todayCost: String
    let todayModels: [UsagePanelSnapshot.ModelRow]
    let strip: UsagePanelSnapshot.DayStrip?
    let tint: Color

    /// The day the pointer is on in the strip, by day key, or nil for none.
    @State private var pointedDay: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Self.headlineGap) {
            headline
            if let strip {
                PanelDayBars(strip: strip, tint: tint, hovered: $pointedDay)
            }
            let models = pointedModels
            if !models.isEmpty {
                HStack(spacing: Self.pillGap) {
                    ForEach(models) { model in
                        ModelPill(row: model)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, PanelMetrics.blockGap - Self.headlineGap)
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    /// The day's own figure, which the pointer never moves: a figure a reader
    /// came for should not change out from under them on the way to the bars.
    private var headline: some View {
        HStack(spacing: 6) {
            SectionLabel(text: "Today")
            Spacer(minLength: 0)
            Text("\(today) · \(todayCost)")
                .font(.system(size: 12))
                .monospacedDigit()
        }
    }

    /// The split the pills draw: the pointed day's, or today's when the
    /// pointer is on no bar.
    ///
    /// Today is the resting answer rather than an empty block, because the
    /// pills are the caption of a strip whose last bar is today and the block
    /// has to say something before the pointer arrives. A pointed day the
    /// archive has no file for answers with nothing, which is the one case
    /// where the pills go away under the pointer — an absent reading is not a
    /// reading of zero, and holding the previous day's split there would break
    /// the strip's own rule in the block beneath it.
    private var pointedModels: [UsagePanelSnapshot.ModelRow] {
        guard let pointedDay, let strip,
            let pointed = strip.rows.first(where: { $0.id == pointedDay })
        else { return todayModels }
        return pointed.models
    }

    /// What the headline is separated from the strip by. The pills pay for
    /// their own separation with `PanelMetrics.blockGap` instead, so a day
    /// with no split is unchanged to the point.
    private static let headlineGap: CGFloat = 3
    /// What two pills leave between them, narrow because the shape already
    /// separates them and the width is what the block is short of.
    private static let pillGap: CGFloat = 4
}
