import CryptoKit
import Foundation
import Synchronization

/// HTTP refusals belong to a credential and survive a monitor rebuild or quit.
/// Only a hash of the origin and credential is stored; no token reaches disk.
final class ForgeRefusalStore: Sendable {
    private static let fileName = "forge-refusals.json"
    private static let current = LockedValue(
        ForgeRefusalStore(
            url: ServerConfig.defaultURL.deletingLastPathComponent().appendingPathComponent(fileName)))

    /// The store every forge request reads and files through. A static rather
    /// than a parameter because those requests are a dozen static functions
    /// deep, none of which holds an engine.
    static var shared: ForgeRefusalStore { current.load() }

    /// Moves the store to `directory`, for an engine whose config lives there:
    /// `sissy-cli --config` used to write its refusals into the real install.
    /// A store already on that file is kept, so an engine rebuilt on a provider
    /// toggle does not drop what requests in flight are about to file.
    static func use(directory: URL) {
        let url = directory.appendingPathComponent(fileName)
        current.update { if $0.url != url { $0 = ForgeRefusalStore(url: url) } }
    }

    private struct Entry: Codable {
        let unauthorized: Bool
        let until: Date
    }
    /// The furthest a deadline may reach, whatever the vendor or the file says.
    static let deadlineCeiling: TimeInterval = 86_400
    /// The wait a refusal that names no deadline is held for.
    static let defaultBackoff: TimeInterval = 300
    private let url: URL?
    private let entries: Mutex<[String: Entry]>

    /// Loads the file without the rate limits that have run out by `now`,
    /// which would otherwise be rewritten on every record for as long as the
    /// file lived.
    init(url: URL? = nil, now: Date = Date()) {
        self.url = url
        entries = Mutex(Self.live(url.flatMap { try? Self.file($0).load() } ?? [:], now: now))
    }

    private static func file(_ url: URL) -> VersionedJSONFile<[String: Entry]> {
        VersionedJSONFile(url: url, policy: .replace, formatting: [])
    }

    /// The entries still in force: every token refusal, and a rate limit only
    /// until its deadline, held to `deadlineCeiling` from `now`. A token
    /// refusal is kept until that token is answered: its key is a hash, so
    /// nothing short of the token can name it.
    private static func live(_ entries: [String: Entry], now: Date) -> [String: Entry] {
        let ceiling = now.addingTimeInterval(deadlineCeiling)
        return entries.filter { $0.value.unauthorized || $0.value.until > now }
            .mapValues { $0.unauthorized ? $0 : Entry(unauthorized: false, until: min($0.until, ceiling)) }
    }

    private func key(url: URL?, token: String) -> String {
        let host = url?.host == "github.com" ? "api.github.com" : (url?.host ?? "")
        let origin = "\(url?.scheme ?? "")://\(host):\(url?.port ?? 443)"
        return SHA256.hash(data: Data("\(origin)\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func failure(url: URL?, token: String, now: Date = Date()) -> ForgeReadFailure? {
        let key = key(url: url, token: token)
        return entries.withLock {
            guard let entry = $0[key] else { return nil }
            if entry.unauthorized { return .unauthorized }
            return entry.until > now ? .rateLimited : nil
        }
    }

    func deadline(url: URL?, token: String) -> Date? {
        let key = key(url: url, token: token)
        return entries.withLock {
            guard let entry = $0[key], !entry.unauthorized else { return nil }
            return entry.until
        }
    }

    func record(
        _ failure: ForgeReadFailure?, url: URL?, token: String, until: Date? = nil, now: Date = Date()
    ) {
        let key = key(url: url, token: token)
        entries.withLock {
            if failure == .unauthorized || failure == .rateLimited {
                $0[key] = Entry(
                    unauthorized: failure == .unauthorized,
                    until: until ?? now.addingTimeInterval(Self.defaultBackoff))
            } else if failure == nil {
                guard $0.removeValue(forKey: key) != nil else { return }
            } else {
                return
            }
            $0 = Self.live($0, now: now)
            guard let url = self.url else { return }
            do {
                try Self.file(url).save($0)
            } catch { sissyLog("sissy: could not save forge refusal state") }
        }
    }

    /// Retry-After seconds or an HTTP date, with a one-day ceiling. Constructed
    /// response headers verified 2026-10-03, not measured from a live refusal.
    static func retryDeadline(_ response: HTTPURLResponse, now: Date = Date()) -> Date {
        if let text = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(text) {
                return now.addingTimeInterval(min(max(seconds, 1), deadlineCeiling))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: text) {
                return min(max(date, now), now.addingTimeInterval(deadlineCeiling))
            }
        }
        if let text = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
            let seconds = TimeInterval(text)
        {
            let reset = Date(timeIntervalSince1970: seconds)
            return min(max(reset, now), now.addingTimeInterval(deadlineCeiling))
        }
        return now.addingTimeInterval(defaultBackoff)
    }
}
