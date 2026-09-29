import Foundation

@testable import Sissy

extension ClaudeCodeAdapter {
    /// An adapter over `claudeDir` with nothing behind it: no pricing
    /// override, no limits probe, no claude.ai sessions or links, inert
    /// accounts and a ledger of its own. What a suite feeding it lines by hand
    /// needs, and nothing that reaches past the lines.
    static func fixture(claudeDir: URL) -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(
            claudeDir: claudeDir,
            pricingOverride: nil,
            limitsProbe: nil,
            webSources: LockedValue([]),
            webLinks: LockedValue([:]),
            profile: .inert(),
            accounts: .inert(),
            ledger: ProjectLedger())
    }
}

extension CodexAdapter {
    /// An adapter over `codexDir` with no pricing override and a ledger of its
    /// own.
    static func fixture(codexDir: URL) -> CodexAdapter {
        CodexAdapter(codexDir: codexDir, pricingOverride: nil, ledger: ProjectLedger())
    }
}
