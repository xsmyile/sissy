import Foundation
import Security

/// User-tunable preferences. Persisted to ~/Library/Application Support/Sissy/preferences.json.
/// JSON (vs UserDefaults) keeps the file diffable for debugging and survives sandboxing changes
/// without a migration step.
struct Preferences: Codable, Equatable {
    var primaryMetric: PrimaryMetric = .tokens
    var serverHost: String = "127.0.0.1"
    var serverPort: Int = SissyPaths.defaultServerPort
    var authToken: String = ""
    var costThresholdCode: Double = 20
    var costThresholdGlow: Double = 100
    var costThresholdAngry: Double = 200
    var costThresholdTrendRatio: Double = 1.3
    var notifyOnMascotChange: Bool = true
    var milestoneFrequency: MilestoneFrequency = .normal

    enum PrimaryMetric: String, Codable, CaseIterable, Identifiable {
        case tokens
        case burnRate

        var id: String { rawValue }

        var label: String {
            switch self {
            case .tokens: return "Total tokens"
            case .burnRate: return "Burn rate"
            }
        }
    }

    /// User-selectable milestone notification cadence. Wire values must
    /// match `MilestoneFrequency.presets` in `app/SissyServer/SissyServer.swift`
    /// — that table is the source of truth; this enum is a UI mirror.
    enum MilestoneFrequency: String, Codable, CaseIterable, Identifiable {
        case veryFrequent = "very_frequent"
        case frequent
        case normal
        case sparse
        case rare

        var id: String { rawValue }

        /// Menubar label.
        var label: String {
            switch self {
            case .veryFrequent: return "Very frequent"
            case .frequent: return "Frequent"
            case .normal: return "Normal"
            case .sparse: return "Sparse"
            case .rare: return "Rare"
            }
        }

        /// Trailing parenthetical shown next to the label, e.g. "($25)".
        var detail: String {
            switch self {
            case .veryFrequent: return "$5"
            case .frequent: return "$10"
            case .normal: return "$25"
            case .sparse: return "$50"
            case .rare: return "$100"
            }
        }
    }

    init(
        primaryMetric: PrimaryMetric = .tokens,
        serverHost: String = "127.0.0.1",
        serverPort: Int = SissyPaths.defaultServerPort,
        authToken: String = "",
        costThresholdCode: Double = 20,
        costThresholdGlow: Double = 100,
        costThresholdAngry: Double = 200,
        costThresholdTrendRatio: Double = 1.3,
        notifyOnMascotChange: Bool = true,
        milestoneFrequency: MilestoneFrequency = .normal
    ) {
        self.primaryMetric = primaryMetric
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.authToken = authToken
        self.costThresholdCode = costThresholdCode
        self.costThresholdGlow = costThresholdGlow
        self.costThresholdAngry = costThresholdAngry
        self.costThresholdTrendRatio = costThresholdTrendRatio
        self.notifyOnMascotChange = notifyOnMascotChange
        self.milestoneFrequency = milestoneFrequency
    }

    /// Backwards-compatible decoder so a `preferences.json` that pre-dates a
    /// newer field (e.g. `milestoneFrequency`) still loads with that field
    /// defaulted, instead of forcing a wipe-and-restart on first launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primaryMetric = (try? c.decode(PrimaryMetric.self, forKey: .primaryMetric)) ?? .tokens
        serverHost = (try? c.decode(String.self, forKey: .serverHost)) ?? "127.0.0.1"
        serverPort = (try? c.decode(Int.self, forKey: .serverPort)) ?? SissyPaths.defaultServerPort
        authToken = (try? c.decode(String.self, forKey: .authToken)) ?? ""
        costThresholdCode = (try? c.decode(Double.self, forKey: .costThresholdCode)) ?? 20
        costThresholdGlow = (try? c.decode(Double.self, forKey: .costThresholdGlow)) ?? 100
        costThresholdAngry = (try? c.decode(Double.self, forKey: .costThresholdAngry)) ?? 200
        costThresholdTrendRatio = (try? c.decode(Double.self, forKey: .costThresholdTrendRatio)) ?? 1.3
        notifyOnMascotChange = (try? c.decode(Bool.self, forKey: .notifyOnMascotChange)) ?? true
        milestoneFrequency = (try? c.decode(MilestoneFrequency.self, forKey: .milestoneFrequency)) ?? .normal
    }

    // MARK: persistence

    static let fileName = "preferences.json"
    static let minimumSecretLength = 12

    static func makeSecret(length: Int = 32) -> String {
        guard length > 0 else { return "" }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let count = alphabet.count
        // Rejection sampling: discard bytes in the unevenly-mapped tail so each
        // symbol is equiprobable. `256 % 62 == 8`, so a plain `byte % count`
        // would over-represent the first 8 symbols and shave entropy.
        let limit = (256 / count) * count

        func randomByte(_ rng: inout SystemRandomNumberGenerator) -> Int {
            var byte: UInt8 = 0
            let status = withUnsafeMutablePointer(to: &byte) {
                SecRandomCopyBytes(kSecRandomDefault, 1, $0)
            }
            return status == errSecSuccess ? Int(byte) : Int(UInt8.random(in: 0...255, using: &rng))
        }

        var rng = SystemRandomNumberGenerator()
        var out = String()
        out.reserveCapacity(length)
        while out.count < length {
            let value = randomByte(&rng)
            if value >= limit { continue }
            out.append(alphabet[value % count])
        }
        return out
    }

    static func appSupportDir() -> URL {
        let base = SissyPaths.appSupportDir
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func load() -> Preferences {
        let url = appSupportDir().appendingPathComponent(fileName)
        var prefs: Preferences
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        {
            prefs = decoded
        } else {
            prefs = Preferences()
        }
        // Keychain is the source of truth for the bearer token. If it's
        // populated, it overrides whatever's on disk; if it's empty and
        // disk holds a legacy plaintext value, migrate up to Keychain on
        // the next `save()`.
        if let kc = KeychainStore.bearerToken, !kc.isEmpty {
            prefs.authToken = kc
        }
        return prefs
    }

    func save() {
        // Move the bearer token to Keychain so plaintext disk never
        // outlives the migration boundary. Daemon still reads from
        // server.json (see `writeServerConfig`), which is written with
        // 0600 perms so a same-user process is still the only thing that
        // can read it.
        var copy = self
        if !authToken.isEmpty {
            // Only drop the plaintext disk copy once the Keychain actually holds
            // the token. If the Keychain is locked/unavailable, keep the disk
            // fallback (KeychainStore documents this) so the app can still load
            // its own token next launch instead of silently losing it.
            if KeychainStore.setBearerToken(authToken) {
                copy.authToken = ""
            } else {
                NSLog("sissy: keychain write failed; retaining token in preferences.json as fallback")
            }
        }
        let url = Self.appSupportDir().appendingPathComponent(Self.fileName)
        guard let data = try? JSONEncoder().encode(copy) else {
            NSLog("sissy: failed to encode %@", Self.fileName)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("sissy: failed to write %@: %@", Self.fileName, error.localizedDescription)
        }
    }

    /// Write the daemon-facing `server.json` next to `preferences.json`.
    /// `sissy-serverd` reads this file at boot (and on kickstart) to
    /// configure its bind address, token, pricing, and state thresholds.
    ///
    /// Preserves any keys we don't manage here — `providers`, `codexDataDir`,
    /// `pricingOverride`, and any hand-edited entries — by reading the
    /// existing file first and merging our values over it. Without that
    /// merge, a metric switch or a pairing run would silently drop a
    /// user's `providers.codex = false` override.
    func writeServerConfig() {
        let url = Self.appSupportDir().appendingPathComponent(Self.serverConfigFileName)
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
            let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            dict = existing
        }
        // 0.0.0.0 so the ESP32 on the LAN can reach the daemon. The app
        // itself connects via 127.0.0.1 (serverHost above) so we don't
        // need to expose anything beyond the local subnet.
        dict["host"] = "0.0.0.0"
        dict["port"] = serverPort
        dict["authToken"] = authToken
        dict["claudeDataDir"] = "~/.claude/projects"
        // 60 s is a safety-net only — FSEvents drives ingest in the
        // common path. Keep this in sync with `ServerConfig.defaults`.
        dict["pollIntervalSeconds"] = 60.0
        dict["primaryMetric"] = primaryMetric.rawValue
        dict["milestoneFrequency"] = milestoneFrequency.rawValue
        dict["stateThresholds"] =
            [
                "code": costThresholdCode,
                "glow": costThresholdGlow,
                "angry": costThresholdAngry,
                "trendRatio": costThresholdTrendRatio,
            ] as [String: Any]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            NSLog("sissy: failed to encode %@", Self.serverConfigFileName)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // A dropped write leaves the daemon on stale config (old port/token)
            // after a metric switch or pairing save — surface it instead of
            // failing silently.
            NSLog("sissy: failed to write %@: %@", Self.serverConfigFileName, error.localizedDescription)
            return
        }
        // server.json carries the bearer token in plaintext for the daemon
        // to read. Lock it down to owner-read/write so a same-user
        // unprivileged process is the only thing that can see it; cross-
        // user access on multi-user macs still requires admin escalation.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    static let serverConfigFileName = "server.json"
}
