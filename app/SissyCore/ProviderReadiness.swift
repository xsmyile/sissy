import Foundation

/// The provider ids that cross from the engine to the app — on the frame's
/// slices, and on the readiness list the Providers tab renders. The app words
/// them; nothing here is a display string.
enum ProviderID {
    static let claudeCode = "claude-code"
    static let codex = "codex"
}

/// Why a provider is or is not metering.
///
/// The distinction between the two "not metering" cases is the whole reason
/// the Providers tab exists: someone who sees no row for a CLI in the panel
/// needs to know whether Sissy was told to leave it alone or simply found
/// nothing where it looked.
enum ProviderActivation: Sendable, Equatable {
    /// Switched on — explicitly, or because it is the baseline that has no
    /// detection step to run.
    case on
    /// Switched off explicitly. Nothing was built for it.
    case off
    /// Unset, and its data dir is there.
    case autoDetected
    /// Unset, and its data dir is not.
    case autoNotFound

    /// Whether a reader was built for this provider.
    var isMetering: Bool {
        switch self {
        case .on, .autoDetected: return true
        case .off, .autoNotFound: return false
        }
    }

    /// How the boot log names this resolution.
    var logToken: String {
        switch self {
        case .on: return "on"
        case .off: return "off"
        case .autoDetected: return "on (auto)"
        case .autoNotFound: return "off (auto, not found)"
        }
    }

    /// Resolves a toggle whose unset state means "let Sissy decide". An
    /// explicit value always wins over what is on disk, in both directions:
    /// `false` keeps a provider off with its logs sitting right there, and
    /// `true` keeps it on so a CLI that has not written yet still gets a
    /// reader waiting for it.
    static func resolve(toggle: Bool?, autoDetected: @autoclosure () -> Bool) -> Self {
        switch toggle {
        case .some(true): return .on
        case .some(false): return .off
        case .none: return autoDetected() ? .autoDetected : .autoNotFound
        }
    }
}

/// What one provider is doing, for the surface that lists them.
struct ProviderReadiness: Sendable, Equatable {
    /// How far a running provider has got through its log tree.
    struct ScanProgress: Sendable, Equatable {
        let filesWatched: Int
        /// False while the cold backfill is still running, during which
        /// "no files" and "not looked yet" are the same zero.
        let isWarm: Bool
    }

    /// Stable provider id, as the frame carries it. The app words it.
    let id: String
    let activation: ProviderActivation
    /// Where this provider's logs are read from, for the row that has to say
    /// where Sissy looked and found nothing.
    let dataDir: URL
    /// Nil for a provider that is not metering: there is no reader, so there
    /// is no scan to report on.
    let scan: ScanProgress?
}
