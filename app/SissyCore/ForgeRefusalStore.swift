import CryptoKit
import Foundation

/// HTTP refusals belong to a credential and survive a monitor rebuild or quit.
/// Only a hash of the origin and credential is stored; no token reaches disk.
final class ForgeRefusalStore: @unchecked Sendable {
    static let shared = ForgeRefusalStore(
        url: ServerConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("forge-refusals.json")
    )
    private struct Entry: Codable {
        let unauthorized: Bool
        let until: Date
    }
    private let lock = NSLock()
    private let url: URL?
    private var entries: [String: Entry]

    init(url: URL? = nil) {
        self.url = url
        entries =
            url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    private func key(url: URL?, token: String) -> String {
        let host = url?.host == "github.com" ? "api.github.com" : (url?.host ?? "")
        let origin = "\(url?.scheme ?? "")://\(host):\(url?.port ?? 443)"
        return SHA256.hash(data: Data("\(origin)\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func failure(url: URL?, token: String, now: Date = Date()) -> ForgeReadFailure? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key(url: url, token: token)] else { return nil }
        if entry.unauthorized { return .unauthorized }
        return min(entry.until, now.addingTimeInterval(86400)) > now ? .rateLimited : nil
    }

    func deadline(url: URL?, token: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key(url: url, token: token)], !entry.unauthorized else { return nil }
        return entry.until
    }

    func record(_ failure: ForgeReadFailure?, url: URL?, token: String, until: Date? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let key = key(url: url, token: token)
        if failure == .unauthorized || failure == .rateLimited {
            entries[key] = Entry(
                unauthorized: failure == .unauthorized,
                until: until ?? Date().addingTimeInterval(300))
        } else if failure == nil {
            guard entries.removeValue(forKey: key) != nil else { return }
        } else {
            return
        }
        guard let url = self.url, let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { sissyLog("sissy: could not save forge refusal state") }
    }

    /// Retry-After seconds or an HTTP date, with a one-day ceiling. Constructed
    /// response headers verified 2026-10-03, not measured from a live refusal.
    static func retryDeadline(_ response: HTTPURLResponse, now: Date = Date()) -> Date {
        if let text = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(text) {
                return now.addingTimeInterval(min(max(seconds, 1), 86400))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: text) {
                return min(max(date, now), now.addingTimeInterval(86400))
            }
        }
        if let text = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
            let seconds = TimeInterval(text)
        {
            return min(max(Date(timeIntervalSince1970: seconds), now), now.addingTimeInterval(86400))
        }
        return now.addingTimeInterval(300)
    }
}
