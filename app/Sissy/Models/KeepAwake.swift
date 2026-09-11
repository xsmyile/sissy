import Foundation

/// What the user asked the daemon to do about sleep.
///
/// Mirrors `SissyServer/KeepAwake.swift`; the two targets share no module, so
/// the wire token is the contract and this end owns the wording — the same
/// division `plan` follows.
enum KeepAwakeMode: String, Codable {
    case on
    case off
}

/// The mode together with whether the Mac is being held awake right now.
///
/// Two axes rather than one because they come apart: power management can
/// refuse the assertion, and the agent mode will watch without always holding.
/// The panel keeps them separable — the glyph follows the mode, the tinted
/// glass follows the holding.
struct KeepAwakeState: Codable, Equatable {
    let mode: KeepAwakeMode
    let active: Bool

    static let off = Self(mode: .off, active: false)
}
