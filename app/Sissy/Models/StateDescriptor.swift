import Foundation

/// Human-readable label + SF Symbol for each server-side mascot state. Keeps
/// the UI from showing raw enum strings like "trend" alongside a generic
/// smiley face.
enum StateDescriptor {
    static func mascotImageName(for state: String?) -> String {
        let known: Set<String> = ["think", "code", "sleep", "trend", "glow", "angry"]
        let key = (state.flatMap { known.contains($0) ? $0 : nil }) ?? "sleep"
        return "Mascot" + key.capitalized
    }

    /// Canonical mood line for the menubar header. Deterministic so the header
    /// text doesn't jitter across menu refreshes — returns the first entry of
    /// the per-state pool, which matches the pre-pool behavior 1:1.
    static func voice(for state: String?) -> String {
        pool(for: state).first ?? "warming up"
    }

    /// Prefixed mood headline shared by the menubar header and the mood
    /// pop-up. Single source so wording changes don't drift between
    /// surfaces.
    static func moodHeadline(voice: String) -> String {
        "Sissy is \(voice)"
    }

    /// Random pick from the per-state pool. Used by the mood-change popover so
    /// the same state can surface different lines across the day; the header
    /// stays on `voice(for:)` to avoid flicker.
    static func randomVoice(for state: String?) -> String {
        pool(for: state).randomElement() ?? "warming up"
    }

    private static func pool(for state: String?) -> [String] {
        switch state {
        case "sleep":
            return [
                "taking a nap", "dozing off", "snoozing", "off the clock",
                "snoring quietly", "dreaming of bigger context windows",
                "catching some Zs",
            ]
        case "think":
            return [
                "thinking it over", "warming up", "stretching", "easing in",
                "loading thoughts", "tokenizing vibes", "scratching its chin",
                "doing math in its head",
            ]
        case "code":
            return [
                "in the zone", "locked in", "deep in it", "pounding the keys",
                "shipping bytes", "whispering to the compiler", "one with the AST",
            ]
        case "trend":
            return [
                "on a roll", "picking up speed", "on a hot streak", "shipping fast",
                "at full velocity", "hitting green lights all the way", "setting the tab key on fire",
            ]
        case "glow":
            return [
                "feeling great", "absolutely cooking", "lit up", "purring",
                "living the dream", "in flow state", "radiating productivity",
            ]
        case "angry":
            return [
                "burning hot", "running hot", "ready for a break", "redlining",
                "screaming under load", "throttling hard",
            ]
        default: return ["warming up", "booting up", "yawning"]
        }
    }
}

/// Decoded form of the wire-side `milestone` field. The daemon emits
/// `"cost:<D>"`; the app parses it so the pop-up can pick a matching
/// catchphrase template and interpolate the numeric value. Legacy
/// `"tokens:*"` strings from an older daemon decode to nil — the milestone
/// is dropped silently rather than crashing the client.
enum MilestoneDescriptor: Equatable {
    case cost(dollarsCrossed: Int)

    /// Parse the wire string. Returns nil for unknown kinds or malformed
    /// values so a future server-side schema bump can't crash older clients.
    static func parse(_ raw: String) -> Self? {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let value = Int(parts[1]) else { return nil }
        switch String(parts[0]) {
        case "cost": return .cost(dollarsCrossed: value)
        default: return nil
        }
    }

    /// Catchphrase for the celebration pop-up. The numeric value is
    /// interpolated into the chosen line. The pop-up shows this as its
    /// headline instead of "Sissy is …" so the reader immediately knows
    /// it's a milestone, not a mood change.
    func phrase() -> String {
        switch self {
        case .cost(let d):
            let templates = [
                "${X} lighter, worth every cent",
                "${X} down, hope it's good code",
                "${X} of pure vibes",
                "${X} sacrificed to the LLM gods",
                "${X} spent, regrets pending",
                "crossed ${X}, sissy nods approvingly",
                "${X} torched, productivity unproven",
                "${X} of vibes, zero regrets",
                "another ${X}, claudemoney",
            ]
            return (templates.randomElement() ?? "${X}")
                .replacingOccurrences(of: "{X}", with: "\(d)")
        }
    }
}
