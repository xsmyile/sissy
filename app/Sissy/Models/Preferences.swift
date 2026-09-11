import Foundation

/// What the app itself remembers, in
/// ~/Library/Application Support/Sissy/preferences.json. JSON rather than
/// UserDefaults keeps the file diffable for debugging.
///
/// Everything about *metering* lives in `server.json` instead, which
/// `UsageEngine` owns and writes — one file, one writer. Two processes used
/// to need two, and `claudeLimits` sat in both.
struct Preferences: Codable, Equatable {
    var sissyMotion: Bool = true
    /// Whether the one-shot retirement of the `sissy-serverd` LaunchAgent has
    /// run. Not a mirror of any login state — `SMAppService` stays the record
    /// for that — only a note that the migration happened, so a user who
    /// later removes Sissy from Login Items does not get it put back.
    var retiredServerAgent: Bool = false

    init(
        sissyMotion: Bool = true,
        retiredServerAgent: Bool = false,
    ) {
        self.sissyMotion = sissyMotion
        self.retiredServerAgent = retiredServerAgent
    }

    /// Backwards-compatible decoder so a `preferences.json` written by an
    /// older build still loads, with anything it predates defaulted, instead
    /// of forcing a wipe-and-restart on first launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sissyMotion = Self.decodeSissyMotion(from: decoder)
        retiredServerAgent = (try? c.decode(Bool.self, forKey: .retiredServerAgent)) ?? false
    }

    /// `sissyMotion` was persisted as `mascotMotion` up to and including
    /// 0.1.8. Reading the old key on upgrade keeps a user who had turned
    /// motion off from silently getting it back; the next `save()` writes
    /// only the current name, so the fallback decays on its own.
    private static func decodeSissyMotion(from decoder: Decoder) -> Bool {
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
            let current = try? c.decode(Bool.self, forKey: .sissyMotion)
        {
            return current
        }
        if let c = try? decoder.container(keyedBy: LegacyCodingKeys.self),
            let legacy = try? c.decode(Bool.self, forKey: .mascotMotion)
        {
            return legacy
        }
        return true
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case mascotMotion
    }

    // MARK: persistence

    static let fileName = "preferences.json"

    static func appSupportDir() -> URL {
        let base = SissyPaths.appSupportDir
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// `directory` is a required argument, not a defaulted one: the app host
    /// `xcodebuild test` launches would otherwise persist onto the machine's
    /// own install whenever a caller forgot it. `SissyModel` holds the only
    /// production value.
    static func load(from directory: URL) -> Self {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return decoded
    }

    func save(to directory: URL) {
        let url = directory.appendingPathComponent(Self.fileName)
        guard let data = try? JSONEncoder().encode(self) else {
            NSLog("sissy: failed to encode %@", Self.fileName)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("sissy: failed to write %@: %@", Self.fileName, error.localizedDescription)
        }
    }
}
