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

    static func label(for state: String?) -> String {
        switch state {
        case "sleep": return "Sleeping"
        case "think": return "Thinking"
        case "code": return "Coding"
        case "trend": return "Trending up"
        case "glow": return "Glowing"
        case "angry": return "Angry coffee"
        default: return state ?? "..."
        }
    }

    static func symbol(for state: String?) -> String {
        switch state {
        case "sleep": return "moon.zzz"
        case "think": return "brain"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "trend": return "chart.line.uptrend.xyaxis"
        case "glow": return "sparkles"
        case "angry": return "flame"
        default: return "circle.dotted"
        }
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
                "thinking...", "warming up", "stretching", "easing in",
                "loading thoughts", "tokenizing vibes", "scratching chin",
                "doing math in head",
            ]
        case "code":
            return [
                "in the zone", "locked in", "deep in it", "hands on keys",
                "shipping bytes", "compiler whispering", "one with the AST",
            ]
        case "trend":
            return [
                "on a roll", "picking up speed", "hot streak", "shipping fast",
                "velocity unlocked", "green lights all the way", "tab key on fire",
            ]
        case "glow":
            return [
                "feeling great", "absolutely cooking", "lit up", "purring",
                "living the dream", "flow state achieved", "radiating productivity",
            ]
        case "angry":
            return [
                "burning hot", "running hot", "needs a break", "redlining",
                "fan screaming", "thermal throttling",
            ]
        default: return ["warming up", "booting brain", "yawning"]
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
