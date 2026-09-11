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
        case "claude-code": return claudeCode
        case "codex": return codex
        default: return .secondary
        }
    }
}
