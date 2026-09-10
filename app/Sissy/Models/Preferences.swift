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
    var claudeLimits: Bool = false
    var deviceSupport: Bool = false
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

        /// Whole-dollar spacing between milestone celebrations. Mirrors
        /// `MilestoneFrequency.presets` in the daemon.
        var costStep: Int {
            switch self {
            case .veryFrequent: return 5
            case .frequent: return 10
            case .normal: return 25
            case .sparse: return 50
            case .rare: return 100
            }
        }

        /// Trailing parenthetical shown next to the label, e.g. "($25)".
        var detail: String { "$\(costStep)" }
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
        claudeLimits: Bool = false,
        deviceSupport: Bool = false,
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
        self.claudeLimits = claudeLimits
        self.deviceSupport = deviceSupport
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
        claudeLimits = (try? c.decode(Bool.self, forKey: .claudeLimits)) ?? false
        deviceSupport = (try? c.decode(Bool.self, forKey: .deviceSupport)) ?? false
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

    static func load() -> Self {
        let url = appSupportDir().appendingPathComponent(fileName)
        var prefs: Self
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Self.self, from: data)
        {
            prefs = decoded
        } else {
            prefs = Self()
        }
        // `server.json` is the source of truth for the bearer token. When it
        // has one it wins; when it doesn't, a legacy plaintext value here is
        // kept and lands there on the next `writeServerConfig()`.
        if let token = Self.serverConfigToken(), !token.isEmpty {
            prefs.authToken = token
        }
        return prefs
    }

    /// The bearer token as the daemon sees it.
    ///
    /// `sissy-serverd` reads `server.json` unattended at boot, so the token
    /// has to be readable from disk by a background agent with nobody there
    /// to answer a prompt — which is why that file is written 0600 and is the
    /// only copy. A duplicate in the login keychain used to exist and bought
    /// nothing: whoever can read a 0600 file owned by this user is the same
    /// principal whose keychain is already unlocked, and the per-item ACL it
    /// needed made macOS re-prompt whenever the app's code signature changed.
    private static func serverConfigToken() -> String? {
        let url = appSupportDir().appendingPathComponent(serverConfigFileName)
        guard let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["authToken"] as? String
    }

    func save() {
        // This file is 0644; `server.json` is 0600. Keep the token out of
        // here, but only once the 0600 file actually holds it — a `save()`
        // that runs before its paired `writeServerConfig()` would otherwise
        // drop a freshly generated token on the floor.
        var copy = self
        if !authToken.isEmpty, Self.serverConfigToken() == authToken {
            copy.authToken = ""
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
    /// `pricingOverride`, `remotePricing`, and any hand-edited entries — by reading the
    /// existing file first and merging our values over it. Without that
    /// merge, a metric switch or a pairing run would silently drop a
    /// user's `providers.codex = false` override.
    ///
    /// `claudeLimits` lands here as well as on the WS message that applies it
    /// live, because the daemon reads this file unattended at boot and starts
    /// the keychain probe from it. Flipping the switch while the socket is
    /// down otherwise leaves the old value on disk, and the next daemon start
    /// prompts for a keychain the user had just opted out of — the app's
    /// `hello` only corrects it once the probe is already running.
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
        dict["host"] = Self.serverBindHost
        dict["port"] = serverPort
        dict["authToken"] = authToken
        dict["claudeDataDir"] = Self.claudeDataDirDefault
        // 60 s is a safety-net only — FSEvents drives ingest in the
        // common path. Keep this in sync with `ServerConfig.defaults`.
        dict["pollIntervalSeconds"] = Self.pollIntervalSecondsDefault
        dict["primaryMetric"] = primaryMetric.rawValue
        dict["milestoneFrequency"] = milestoneFrequency.rawValue
        dict["claudeLimits"] = claudeLimits
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

    /// Wire-config defaults written into `server.json`. These mirror the
    /// daemon's `ServerConfig.defaults`; the app and daemon don't share a
    /// module, so they're kept in sync by hand.
    private static let serverBindHost = "0.0.0.0"
    private static let claudeDataDirDefault = "~/.claude/projects"
    private static let pollIntervalSecondsDefault = 60.0
}
