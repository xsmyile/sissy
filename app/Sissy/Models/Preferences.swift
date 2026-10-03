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
    /// Which window the panel's headline is over.
    ///
    /// A preference rather than view state: `UsagePanelView.page` is dropped
    /// when the popover closes because it is navigation, where this is a choice
    /// about what the user wants to read and has to survive the close. It lives
    /// here rather than in `server.json` because it changes what is rendered
    /// and nothing about what is metered.
    var usagePeriod: UsagePeriod = .today
    /// Which end of a rate-limit window its gauge prints. Here for the reason
    /// `usagePeriod` is: it changes what is rendered and nothing about what is
    /// metered. `used` is the vendor's own end and the one Sissy has always
    /// shown, so a file written before this key existed keeps its gauges.
    var limitsReading: LimitsReading = .used
    /// Whether the user has read and accepted what keeping the lid closed
    /// costs. Asked once: the warning does not change, and a confirmation in
    /// the way every time would push the switch out of the cup's menu, which
    /// is where it is reached for. Here rather than in `server.json` because
    /// it is about what the app asks, not about what the engine holds.
    var lidClosedConfirmed: Bool = false

    init(
        sissyMotion: Bool = true,
        retiredServerAgent: Bool = false,
        usagePeriod: UsagePeriod = .today,
        limitsReading: LimitsReading = .used,
        lidClosedConfirmed: Bool = false,
    ) {
        self.sissyMotion = sissyMotion
        self.retiredServerAgent = retiredServerAgent
        self.usagePeriod = usagePeriod
        self.limitsReading = limitsReading
        self.lidClosedConfirmed = lidClosedConfirmed
    }

    /// Backwards-compatible decoder so a `preferences.json` written by an
    /// older build still loads, with anything it predates defaulted, instead
    /// of forcing a wipe-and-restart on first launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sissyMotion = Self.decodeSissyMotion(from: decoder)
        retiredServerAgent = (try? c.decode(Bool.self, forKey: .retiredServerAgent)) ?? false
        usagePeriod = (try? c.decode(UsagePeriod.self, forKey: .usagePeriod)) ?? .today
        limitsReading = (try? c.decode(LimitsReading.self, forKey: .limitsReading)) ?? .used
        lidClosedConfirmed = (try? c.decode(Bool.self, forKey: .lidClosedConfirmed)) ?? false
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
