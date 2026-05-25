import Foundation

/// Mirror of the app's `SissyPaths` helper for the daemon target. Same
/// resolution rule (bundle id `.dev` suffix → dev tree) so a Debug
/// `sissy-serverd` reads what the dev `Sissy.app` wrote. Two copies because
/// the targets don't share a Swift module; keep them in lockstep.
enum SissyPaths {
    static let isDev: Bool = {
        // Daemon Info.plist lives in the binary's `__TEXT,__info_plist`
        // section via `CREATE_INFOPLIST_SECTION_IN_BINARY: YES`, so
        // `Bundle.main.bundleIdentifier` resolves even though `sissy-serverd`
        // is a CLI tool, not a `.app`.
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return id.hasSuffix(".dev")
    }()

    static var supportDirName: String { isDev ? "Sissy-Dev" : "Sissy" }

    static var defaultServerPort: Int { isDev ? 8788 : 8787 }

    static var appSupportDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/\(supportDirName)")
    }

    static var logsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/\(supportDirName)")
    }
}
