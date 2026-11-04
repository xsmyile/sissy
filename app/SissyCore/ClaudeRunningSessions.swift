import Foundation

/// One variable out of the bytes `KERN_PROCARGS2` answers with.
///
/// Those bytes are `argc` as an `Int32`, the executable path, padding NULs,
/// then each argument and each environment entry, NUL-terminated, with an empty
/// entry after the environment. They are another process's own memory, so the
/// parse trusts none of it: every walk stops at the end of the buffer, and a
/// shape that does not hold answers `unreadable` rather than a guess.
///
/// Bytes that end straight after the arguments are one of those: the kernel can
/// withhold the environment of a platform binary. Measured 2026-11-04 on macOS 27,
/// `/bin/sleep` started with the variable set answered with its arguments alone,
/// where a compiled child answered with its environment and the kernel's own
/// strings. The `macos-26` CI runner answered with the environment for both.
///
/// `argc` cannot be trusted either. A process that sets its title overwrites the
/// argument area. Measured 2026-11-04 with node 24 and `process.title`, argc 5: a
/// short title left `claude`, then zeros up to the environment, and a title too
/// long for the area left one entry with the environment straight after it.
enum ProcessEnvironment {
    /// What the bytes say about a variable. `absent` is a reading, that the
    /// process was started without it, where `unreadable` says nothing.
    enum Lookup: Equatable, Sendable {
        case absent
        case value(String)
        case unreadable
    }

    /// The longest value kept: the variable names a directory.
    static let maximumValueBytes = Int(MAXPATHLEN)

    /// The first entry named `name`, as the C library reads it. An empty value
    /// is no value, which is how the CLI itself reads the variable it is used for.
    ///
    /// Zeros in front of the environment are skipped, because they are what a
    /// rewritten title leaves. An entry spelling the variable among the arguments
    /// is either a prompt that happens to, or an environment entry the walk took
    /// for an argument after a long title, and nothing tells those apart, so with
    /// no other answer it is `unreadable`: `absent` would count the session on the
    /// default home.
    static func lookup(_ name: String, in bytes: [UInt8]) -> Lookup {
        guard let walked = arguments(in: bytes), walked.end < bytes.count else { return .unreadable }
        var cursor = walked.end
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        let prefix = Array(name.utf8) + [UInt8(ascii: "=")]
        while cursor < bytes.count, bytes[cursor] != 0 {
            guard let end = bytes[cursor...].firstIndex(of: 0) else { return .unreadable }
            let entry = bytes[cursor..<end]
            cursor = end + 1
            guard entry.starts(with: prefix) else { continue }
            let value = entry.dropFirst(prefix.count)
            guard !value.isEmpty else { return .absent }
            guard value.count <= maximumValueBytes, let text = String(bytes: value, encoding: .utf8)
            else { return .unreadable }
            return .value(text)
        }
        return walked.entries.contains { $0.starts(with: prefix) } ? .unreadable : .absent
    }

    /// The `argc` entries past the count, the executable path and its padding,
    /// and where they end. Nil where the bytes end first.
    private static func arguments(in bytes: [UInt8]) -> (entries: [ArraySlice<UInt8>], end: Int)? {
        let header = MemoryLayout<Int32>.size
        guard bytes.count > header else { return nil }
        let argc = bytes[0..<header].reversed().reduce(Int32(0)) { ($0 << 8) | Int32($1) }
        guard argc >= 0, var cursor = bytes[header...].firstIndex(of: 0) else { return nil }
        cursor += 1
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var entries: [ArraySlice<UInt8>] = []
        for _ in 0..<argc {
            guard let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            entries.append(bytes[cursor..<end])
            cursor = end + 1
        }
        return (entries, cursor)
    }
}

/// The config home a running Claude Code was started with.
enum ClaudeProcessHome: Hashable, Sendable {
    /// Started with no `CLAUDE_CONFIG_DIR`.
    case standard
    case named(String)

    /// Reads the variable's value off a process. Nil for a value that names no
    /// directory Sissy can resolve: a relative path means something only to
    /// the process that holds it.
    ///
    /// Kept as the exact text, because the CLI hashes that for its keychain item.
    /// Read in the 2.1.318 bundle on 2026-11-04: any value at all takes a scoped
    /// item and `<value>/.claude.json`, so naming `~/.claude` outright is not the
    /// default home, whose unscoped item and `$HOME/.claude.json` belong only to a
    /// process with no variable.
    init?(variable lookup: ProcessEnvironment.Lookup) {
        switch lookup {
        case .unreadable:
            return nil
        case .absent:
            self = .standard
        case .value(let path):
            guard path.hasPrefix("/") else { return nil }
            self = .named(path)
        }
    }

    /// The user's home directory, which is where the default config file sits.
    static var userHome: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    private static func standardDirectory(userHome: URL) -> URL {
        userHome.appendingPathComponent(".claude")
    }

    /// The directory this names.
    func directory(userHome: URL = Self.userHome) -> URL {
        switch self {
        case .standard: return Self.standardDirectory(userHome: userHome)
        case .named(let path): return URL(fileURLWithPath: path)
        }
    }

    /// The names Claude Code files this home's credential under.
    func credentialServices(userHome: URL = Self.userHome) -> [String] {
        switch self {
        case .standard:
            return [
                ClaudeKeychainCLI.claudeService,
                ClaudeKeychainCLI.scopedClaudeService(for: directory(userHome: userHome).path),
            ]
        case .named(let text):
            return [ClaudeKeychainCLI.scopedClaudeService(for: text)]
        }
    }

    /// The config file, by the rule `ProviderHome` applies to the home it reads.
    func configFile(userHome: URL = Self.userHome) -> URL {
        ProviderHome.claudeProfileURL(
            home: directory(userHome: userHome), isDefault: self == .standard, userHome: userHome)
    }
}

/// Which accounts the running Claude Code sessions are on.
///
/// A session's account is what its own config home names, so this reads each
/// running home's config file and never a credential: `oauthAccount.accountUuid`
/// says whose it is, and the usage reply the CLI cached there is the only reading
/// of that account's limits that costs no keychain item. Metering stays one tree
/// per vendor; this is a head count and a name.
///
/// Each file goes through a `ClaudeProfileSource`, so it is parsed at most once a
/// minute and only once its modification date has moved. The path came out of
/// another process's environment, so a file that is not a regular one, or is
/// larger than any config file, is not opened.
final class ClaudeRunningSessions: @unchecked Sendable {
    /// One account, as the homes running on it name it.
    struct Account: Sendable, Equatable {
        let id: String
        var sessions: Int
        var account: ProviderAccount?
        var plan: String?
        var planTier: String?
        var planName: String?
        /// Off the file's cached usage reply, and only where that reply is
        /// stamped with this same account. `observedAt` is the vendor's own
        /// fetch time, so the page dates it for what it is.
        var windows: [UsageWindow] = []
        var credits: ProviderCredits?
        var observedAt: Date?
    }

    /// One running home, its sessions, and what its config file says.
    struct HomeRead: Sendable, Equatable {
        let home: ClaudeProcessHome
        let sessions: Int
        let file: ClaudeProfileSource.Attributed
        /// Whether this is the home whose credential the account registry
        /// identifies, so that the registry outranks this file.
        let isMetered: Bool
    }

    /// What the last sweep found.
    struct Reading: Sendable, Equatable {
        var reads: [HomeRead] = []

        var homes: [ClaudeProcessHome] { reads.map(\.home) }

        /// The homes Sissy names and counts. A home whose file names nobody, or
        /// would not be opened, is running and still unread.
        var namedHomes: [ClaudeProcessHome] {
            reads.filter { $0.file.fileOwner != nil }.map(\.home)
        }

        /// The accounts these homes are on, sessions summed. `signedIn` is who
        /// the registry says the metered home is on.
        func accounts(signedIn: String? = nil) -> [String: Account] {
            ClaudeRunningSessions.accounts(reads, signedIn: signedIn)
        }
    }

    /// Far beyond any config file measured: 320 KB is the ordinary size.
    static let maximumConfigBytes = 64 * 1024 * 1024

    /// Reads nothing and counts nothing. What every monitor and adapter gets
    /// unless it is built for the real machine, so a test never reads the
    /// developer's own files.
    static let inert = ClaudeRunningSessions(isEnabled: false)

    private let isEnabled: Bool
    private let userHome: URL
    /// The config file of the home the account registry reads, nil for none.
    private let meteredConfig: @Sendable () -> URL?
    private let lock = NSLock()
    private var sources: [URL: ClaudeProfileSource] = [:]
    private let published = LockedValue(Reading())

    init(
        isEnabled: Bool = true, userHome: URL = ClaudeProcessHome.userHome,
        meteredConfig: @escaping @Sendable () -> URL? = { nil }
    ) {
        self.isEnabled = isEnabled
        self.userHome = userHome
        self.meteredConfig = meteredConfig
    }

    func current() -> Reading { published.load() }

    /// Counts these processes by the account their home names.
    func update(_ agents: [AgentProcess]) {
        guard isEnabled else { return }
        var counts: [ClaudeProcessHome: Int] = [:]
        for agent in agents {
            if let home = agent.claudeHome { counts[home, default: 0] += 1 }
        }
        let homes = counts.keys.sorted {
            $0.directory(userHome: userHome).path < $1.directory(userHome: userHome).path
        }
        let metered = meteredConfig()?.standardizedFileURL.path
        let reads = homes.map { home in
            HomeRead(
                home: home, sessions: counts[home] ?? 0, file: read(home),
                isMetered: home.configFile(userHome: userHome).standardizedFileURL.path == metered)
        }
        lock.withLock {
            let wanted = Set(homes.map { $0.configFile(userHome: userHome) })
            sources = sources.filter { wanted.contains($0.key) }
        }
        published.store(Reading(reads: reads))
    }

    /// Forgets everything, for a monitor that stopped.
    func clear() {
        lock.withLock { sources = [:] }
        published.store(Reading())
    }

    /// One home's file through its own source, or nothing where the path does
    /// not lead to a file that could be one.
    private func read(_ home: ClaudeProcessHome) -> ClaudeProfileSource.Attributed {
        let url = home.configFile(userHome: userHome)
        guard Self.isReadableConfig(url) else { return ClaudeProfileSource.Attributed() }
        let source = lock.withLock {
            if let known = sources[url] { return known }
            let made = ClaudeProfileSource(url: url)
            sources[url] = made
            return made
        }
        source.refresh()
        return source.currentAttributed()
    }

    /// Follows a link, because a dotfile manager keeps this file as one, and
    /// answers for what it lands on.
    private static func isReadableConfig(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? Int
        else { return false }
        return size <= maximumConfigBytes
    }

    /// The accounts these files name, sessions summed. A file that names
    /// nobody adds no one. Where two homes are on one account, the freshest
    /// reading stands for it.
    ///
    /// The metered home takes the judgement `ClaudeCodeSignals.attributed` gives
    /// its file: the file can name an account the credential has moved off, so
    /// where the registry names someone the sessions are theirs, and nothing else
    /// that file says is laid under that name.
    static func accounts(_ reads: [HomeRead], signedIn: String? = nil) -> [String: Account] {
        var byAccount: [String: Account] = [:]
        for read in reads {
            let registered = read.isMetered ? signedIn : nil
            guard let owner = registered ?? read.file.fileOwner else { continue }
            let trusted = read.file.fileOwner == owner
            var candidate = Account(
                id: owner, sessions: read.sessions,
                account: trusted ? read.file.signals.account : nil,
                plan: trusted ? read.file.signals.plan : nil,
                planTier: trusted ? read.file.signals.planTier : nil,
                planName: trusted ? read.file.signals.planName : nil)
            if trusted, read.file.creditsOwner == owner {
                candidate.windows = read.file.cachedWindows
                candidate.credits = read.file.signals.credits
                candidate.observedAt = read.file.cachedAt
            }
            guard let held = byAccount[owner] else {
                byAccount[owner] = candidate
                continue
            }
            candidate.sessions += held.sessions
            if (candidate.observedAt ?? .distantPast) > (held.observedAt ?? .distantPast)
                || held.account == nil
            {
                byAccount[owner] = candidate
            } else {
                byAccount[owner]?.sessions = candidate.sessions
            }
        }
        return byAccount
    }
}
