import Foundation

/// When each limits reader may ask its vendor again, across runs.
///
/// A refusal is published as `ProviderLimitsState.rateLimited(until:)`, which
/// lived in memory alone — so a relaunch inside a block spent a request the
/// vendor had already said no to, and that request is not free: measured
/// 2026-09-17 against `api/oauth/usage`, three refusals between 08:26 and
/// 08:30 moved the deadline from 08:26:44 to 09:30:24, which is the ceiling.
/// A rebuild is not a rare event either — a login item, a provider switched
/// off and on, and every build of a dev loop each construct a fresh reader.
///
/// Its own file rather than `server.json`, for the reason the archive's
/// backfill record is: these writes come off reader actors and would race the
/// ones Settings makes, where last writer wins and one change is lost.
struct LimitsBackoffLedger: Codable, Equatable, Sendable {
    /// Bump only when the meaning of an entry changes. A file this build
    /// cannot read is answered as "nothing is blocked", which costs one
    /// request against a vendor that may refuse it.
    static let currentSchemaVersion = 1
    static let fileName = "limits-backoff.json"

    var schemaVersion: Int = Self.currentSchemaVersion
    /// The deadline each reader is refused until. A reader with no entry is
    /// not blocked, which is the ordinary state.
    var blockedUntil: [String: Date] = [:]

    /// The CLI's own credential against `api.anthropic.com`. One key rather
    /// than one per account: which account that credential holds is the CLI's
    /// to change, so a switch drops the entry rather than keying it.
    static let claudeCLIKey = "claude-cli"

    static func claudeWebKey(account: String) -> String { "claude-web:\(account)" }

    /// The CLI's own `auth.json` has no account of its own, for the reason it
    /// has no key of its own: that file answers for whichever account `codex`
    /// is signed in as. Its key takes a different separator rather than a
    /// reserved name, so no account id can ever be spelt the same way.
    static func codexKey(account: String?) -> String {
        account.map { "codex:\($0)" } ?? "codex-cli"
    }

    static func defaultURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// The record on disk, or an empty one. A file that will not decode is
    /// answered as empty rather than quarantined: it holds no reading, and
    /// the worst it costs is one refused request.
    static func load(from url: URL) -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
            let decoded = try? decoder.decode(Self.self, from: data),
            decoded.schemaVersion == currentSchemaVersion
        else { return Self() }
        return decoded
    }

    static func save(_ ledger: Self, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ledger).write(to: url, options: [.atomic])
    }
}

/// The one writer of `limits-backoff.json`.
///
/// An actor because the readers that record a refusal are three actors of
/// their own and every account adds another: serialising here is what keeps
/// one credential's entry from being written away by another's, where a file
/// each would be a file per credential.
///
/// Every answer is read off the file rather than from a copy held here. A
/// provider switched off and on builds a second engine with a second store
/// over the same file, and a reader of the first that has not finished
/// stopping would otherwise write a remembered ledger back over it. The file
/// is a few hundred bytes and it is read once per poll, against a network
/// request that follows it.
actor LimitsBackoffStore {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    /// How long this key is still refused for, or nil when it is not.
    ///
    /// Clamped to the longest block a live refusal could have earned, because
    /// the file is input like any other: a date beyond that is not something
    /// this build wrote, and honouring it would silence a reader for as long
    /// as it said.
    func deadline(for key: String) -> Date? {
        let now = Date()
        let ledger = LimitsBackoffLedger.load(from: url)
        guard let until = ledger.blockedUntil[key], until > now else { return nil }
        return min(until, now.addingTimeInterval(UsageRequestError.retryAfterCeiling))
    }

    /// Writes one reader's deadline down, or takes its entry out once the
    /// vendor has answered again.
    ///
    /// A write that fails is logged and nothing else: the block is already
    /// published and already being waited out, and all the record buys is the
    /// next launch.
    func record(_ until: Date?, for key: String) {
        var updated = LimitsBackoffLedger.load(from: url)
        if let until {
            guard updated.blockedUntil[key] != until else { return }
            updated.blockedUntil[key] = until
        } else {
            guard updated.blockedUntil.removeValue(forKey: key) != nil else { return }
        }
        do {
            try LimitsBackoffLedger.save(updated, to: url)
        } catch {
            sissyLog("sissy: could not record the limits backoff for \(key): \(error)")
        }
    }

    /// This store addressed for one reader, which is all a reader is handed:
    /// it reads and writes its own deadline and cannot reach another
    /// credential's.
    nonisolated func slot(for key: String) -> LimitsBackoffSlot {
        LimitsBackoffSlot(
            deadline: { await self.deadline(for: key) },
            record: { await self.record($0, for: key) })
    }
}

/// One reader's half of the store.
///
/// Two closures rather than the store itself, for the reason every other seam
/// in these readers is a closure: a test of the backoff contract answers for
/// the deadline without a file, and the key a reader was built with is the
/// only one it can reach.
struct LimitsBackoffSlot: Sendable {
    let deadline: @Sendable () async -> Date?
    let record: @Sendable (Date?) async -> Void
}
