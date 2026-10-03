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
    ///
    /// A preset is stored as the bare string it always was, so a file written
    /// before a window could be picked on the calendar reads the same choice.
    /// Read it through `period(now:)`, which retires a picked window.
    var usagePeriod: UsageRange = .preset(.today)
    /// When the window in `usagePeriod` was picked on the calendar, nil for a
    /// preset. A picked window is a question about some days, asked once,
    /// and it stops being the panel's reading a day after it was asked: a
    /// panel opened the next morning on last Tuesday reads as a stale one.
    var usagePeriodPickedAt: Date?
    /// Which end of a rate-limit window its gauge prints. Here for the reason
    /// `usagePeriod` is: it changes what is rendered and nothing about what is
    /// metered. `used` is the vendor's own end and the one Sissy has always
    /// shown, so a file written before this key existed keeps its gauges.
    var limitsReading: LimitsReading = .used

    init(
        sissyMotion: Bool = true,
        retiredServerAgent: Bool = false,
        usagePeriod: UsageRange = .preset(.today),
        usagePeriodPickedAt: Date? = nil,
        limitsReading: LimitsReading = .used,
    ) {
        self.sissyMotion = sissyMotion
        self.retiredServerAgent = retiredServerAgent
        self.usagePeriod = usagePeriod
        self.usagePeriodPickedAt = usagePeriodPickedAt
        self.limitsReading = limitsReading
    }

    /// How long a window picked on the calendar stays the panel's period.
    static let pickedPeriodLifetime: TimeInterval = 24 * 60 * 60

    /// The window the panel reads over at `now`: the stored one, or today once
    /// a picked window has outlived `pickedPeriodLifetime`. A picked window
    /// with no instant beside it is one this build cannot age, and is retired
    /// the same way rather than kept for ever.
    ///
    /// The age has a floor as well as a ceiling: a `pickedAt` after `now` is a
    /// clock set back since the pick, or a file written on another machine,
    /// and an age that cannot be read retires the window rather than keeping
    /// it until the clock catches up. So does a window whose last day has come
    /// to be after today, which a flight west makes of one that ended today.
    func period(now: Date = Date()) -> UsageRange {
        guard case .days(let span) = usagePeriod else { return usagePeriod }
        guard let pickedAt = usagePeriodPickedAt,
            (0..<Self.pickedPeriodLifetime).contains(now.timeIntervalSince(pickedAt)),
            span.to <= Calendar.current.startOfDay(for: now)
        else { return .preset(.today) }
        return usagePeriod
    }

    /// When the window picked on the calendar stops being the panel's period,
    /// nil for a preset and for a window that has stopped already.
    func pickedPeriodExpiry(now: Date = Date()) -> Date? {
        guard period(now: now) != .preset(.today), let pickedAt = usagePeriodPickedAt else {
            return nil
        }
        return pickedAt.addingTimeInterval(Self.pickedPeriodLifetime)
    }

    /// Backwards-compatible decoder so a `preferences.json` written by an
    /// older build still loads, with anything it predates defaulted, instead
    /// of forcing a wipe-and-restart on first launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sissyMotion = Self.decodeSissyMotion(from: decoder)
        retiredServerAgent = (try? c.decode(Bool.self, forKey: .retiredServerAgent)) ?? false
        usagePeriod = (try? c.decode(UsageRange.self, forKey: .usagePeriod)) ?? .preset(.today)
        usagePeriodPickedAt = try? c.decode(Date.self, forKey: .usagePeriodPickedAt)
        limitsReading = (try? c.decode(LimitsReading.self, forKey: .limitsReading)) ?? .used
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
