import SwiftUI

/// Per-provider accent used by the panel's share bars, so a glance at the
/// colour is enough to tell the CLIs apart. Each value is the vendor's own
/// brand colour; anything unrecognised falls back to a neutral so a provider
/// added by a future release still renders.
enum ProviderPalette {
    /// Claude's coral, `#D97757`.
    static let claudeCode = Color(red: 0.851, green: 0.467, blue: 0.341)
    /// OpenAI's monochrome mark. `.primary` rather than a literal white so it
    /// stays the brand's own colour in dark mode and does not vanish into the
    /// popover in light mode.
    static let codex = Color.primary

    static func tint(for id: String) -> Color {
        switch id {
        case ProviderID.claudeCode: return claudeCode
        case ProviderID.codex: return codex
        default: return .secondary
        }
    }

    /// The colour a vendor's own status reads in.
    ///
    /// The system's own greens, oranges and reds rather than literals, so they
    /// follow the appearance and whatever the user has set for colour — a
    /// hand-picked triplet is a traffic light that only works in one of them.
    /// `unknown` is grey and never red: Sissy having no reading is not the
    /// vendor being down.
    static func statusTint(_ indicator: ProviderStatusIndicator) -> Color {
        switch indicator {
        case .operational: return .green
        case .maintenance, .minor: return .orange
        case .major, .critical: return .red
        case .unknown: return .secondary
        }
    }

    /// The vendor's own mark, for the providers Sissy ships one for.
    ///
    /// Template assets, so every surface tints them with `tint(for:)` and one
    /// file serves the panel, the page header and Settings. Nil is the answer
    /// for anything unrecognised, which is what keeps a provider a future
    /// release adds renderable without an asset of its own.
    static func mark(for id: String) -> Image? {
        switch id {
        case ProviderID.claudeCode: return Image("ProviderMarkClaude")
        case ProviderID.codex: return Image("ProviderMarkCodex")
        default: return nil
        }
    }
}

/// Which CLI a row is about, said in the vendor's own mark rather than in a
/// coloured dot.
///
/// A dot carries the colour and nothing else, so it only works once you have
/// learnt which colour is whose — and the two the panel draws are a coral one
/// and a monochrome one, which is a legend to memorise rather than a thing to
/// recognise. The mark is recognised before it is read.
///
/// The colour does not go away with the dot: the mark is tinted with the same
/// `tint(for:)` the provider's bars use, so the legend still ties to the bar
/// beside it. A provider with no mark keeps the dot, at the size a dot should
/// be rather than at the mark's.
struct ProviderMark: View {
    let id: String
    var size: CGFloat = PanelMetrics.markSize
    /// The size of the text this mark sits beside, which is what decides how
    /// far down it has to move to look level with it.
    ///
    /// Nil where the mark labels more than one line. A block of two lines is
    /// already centred on its own middle, and a correction cut for a single
    /// line would push the mark off it.
    var textSize: CGFloat? = PanelMetrics.rowText

    /// A dot reads as a dot at about a third of the width a mark needs, and a
    /// dot blown up to a mark's box reads as a bullet hole.
    private static let dotRatio: CGFloat = 0.44

    /// How far below a line box's centre the capitals actually sit.
    ///
    /// A run like "Claude Code" has no descenders, so its ink fills the band
    /// from the baseline to the cap height while the box it is laid out in
    /// reserves room under the baseline as well. Centring a mark on that box
    /// therefore centres it on empty space, and the mark reads high — measured
    /// at 0.38 pt against 13 pt text, which is small and is exactly the amount
    /// that makes a row look not-quite-level.
    ///
    /// Read off the font rather than fixed, because the amount scales with the
    /// text: the same row at another size would need another number, and a
    /// constant would be right once.
    static func capCentreOffset(forTextSize textSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: textSize)
        return (font.ascender + font.descender - font.capHeight) / 2
    }

    var body: some View {
        if let textSize {
            content
                .alignmentGuide(VerticalAlignment.center) { dimension in
                    dimension[VerticalAlignment.center]
                        - Self.capCentreOffset(forTextSize: textSize)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let mark = ProviderPalette.mark(for: id) {
            mark
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(ProviderPalette.tint(for: id))
        } else {
            Circle()
                .fill(ProviderPalette.tint(for: id))
                .frame(width: size * Self.dotRatio, height: size * Self.dotRatio)
        }
    }
}
