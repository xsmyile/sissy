import SwiftUI

/// Per-provider accent used by the panel's share bars, so a glance at the
/// colour is enough to tell the CLIs apart. Each value is the vendor's own
/// brand colour; anything unrecognised falls back to a neutral so a provider
/// added by a future daemon still renders.
enum ProviderPalette {
    /// Claude's coral, `#D97757`.
    static let claudeCode = Color(red: 0.851, green: 0.467, blue: 0.341)
    /// OpenAI's green, `#10A37F`.
    static let codex = Color(red: 0.063, green: 0.639, blue: 0.498)

    static func tint(for id: String) -> Color {
        switch id {
        case "claude-code": return claudeCode
        case "codex": return codex
        default: return .secondary
        }
    }
}
