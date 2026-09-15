import Foundation

/// Where one CLI's files are, resolved from its config home.
///
/// A config home is a place a CLI writes, not an account. Both CLIs relocate
/// their whole state under one environment variable (`CLAUDE_CONFIG_DIR`,
/// `CODEX_HOME`), and Sissy reads whichever home that resolves to — one per
/// vendor. Which *account* is signed in there is a property of the credential,
/// not of the directory: a log line carries no account id, so two accounts used
/// under one home are one reading, and Sissy reports what was spent rather than
/// who paid for it. `ClaudeAccountRegistry` is what answers the account
/// question, on the credential where it belongs.
struct ProviderHome: Sendable, Equatable {
    /// The CLI: `claude-code`, `codex`. What the app words, colours and draws
    /// a mark for, and what names this provider's snapshot and archive.
    let id: String
    /// Config home this CLI was pointed at.
    let home: URL
    /// Root of the session-log tree the tail reads.
    let dataDir: URL

    /// Claude Code's config file.
    ///
    /// Three places in one order: the home's own `.config.json` where the CLI
    /// has migrated to it, then `<home>/.claude.json` for a home
    /// `CLAUDE_CONFIG_DIR` names, and `$HOME/.claude.json` for the default
    /// home — where the CLI keeps the profile *beside* the config directory
    /// rather than inside it. Measured against 2.1.272, which creates
    /// `<home>/.claude.json` on first run under a home it was given.
    var claudeProfileURL: URL {
        let profile = home.appendingPathComponent(AccountDefaults.claudeProfileName)
        if FileManager.default.fileExists(atPath: profile.path) { return profile }
        guard home == AccountDefaults.claudeHome else {
            return home.appendingPathComponent(AccountDefaults.claudeLegacyProfileName)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(AccountDefaults.claudeLegacyProfileName)
    }

    /// Claude Code's own OAuth credential, which reads the usage endpoint with
    /// no keychain dialog and no grant to lapse. It is the credential of
    /// whoever is signed in, which is the account the limits belong to.
    var claudeCredentialsURL: URL {
        home.appendingPathComponent(AccountDefaults.claudeCredentialsName)
    }

    /// Codex's own credential and plan claim.
    var codexAuthURL: URL {
        home.appendingPathComponent(AccountDefaults.codexAuthName)
    }
}

/// The paths a vendor uses when nobody has said otherwise.
enum AccountDefaults {
    static let claudeConfigDirEnvVar = "CLAUDE_CONFIG_DIR"
    static let codexHomeEnvVar = "CODEX_HOME"
    /// Newer layout: a config home the CLI has migrated keeps its profile
    /// here, and it wins where both exist.
    static let claudeProfileName = ".config.json"
    static let claudeLegacyProfileName = ".claude.json"
    static let claudeCredentialsName = ".credentials.json"
    static let codexAuthName = "auth.json"
    static let claudeLogsSubdirectory = "projects"
    static let codexLogsSubdirectory = "sessions"

    /// Claude Code's config home, deferring to the CLI's own environment
    /// variable exactly as `ClaudeProfileSource` already does.
    static var claudeHome: URL {
        let configured = ProcessInfo.processInfo.environment[claudeConfigDirEnvVar]
        if let configured, !configured.isEmpty { return URL(fileURLWithPath: configured) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// Codex's home, deferring to `CODEX_HOME` on the same grounds.
    static var codexHome: URL {
        let configured = ProcessInfo.processInfo.environment[codexHomeEnvVar]
        if let configured, !configured.isEmpty { return URL(fileURLWithPath: configured) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    /// The home a vendor uses when nobody has said otherwise.
    static func home(vendor: String) -> URL {
        vendor == ProviderID.codex ? codexHome : claudeHome
    }

    /// Log tree of a home, per vendor.
    static func dataDir(vendor: String, home: URL) -> URL {
        switch vendor {
        case ProviderID.codex: return home.appendingPathComponent(codexLogsSubdirectory)
        default: return home.appendingPathComponent(claudeLogsSubdirectory)
        }
    }

    /// The home a log tree belongs to, for the configuration that names the
    /// tree rather than the home: `claudeDataDir` / `codexDataDir` are what
    /// every install carries.
    static func home(ofDataDir dataDir: URL) -> URL {
        dataDir.deletingLastPathComponent()
    }
}

extension ServerConfig {
    /// The one home Sissy reads for a vendor.
    ///
    /// Taken from the configured log tree rather than the environment, because
    /// a user who pointed `claudeDataDir` somewhere else meant it.
    func providerHome(vendor: String) -> ProviderHome {
        let dataDir = vendor == ProviderID.codex ? resolvedCodexDataDir : resolvedClaudeDataDir
        return ProviderHome(
            id: vendor,
            home: AccountDefaults.home(ofDataDir: dataDir),
            dataDir: dataDir
        )
    }
}
