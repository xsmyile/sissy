import Foundation

/// Resolves the on-disk locations that differ between a release and a Debug
/// build so two installs can coexist. Detection is bundle-id based:
/// `project.yml` gives Debug a `.dev` suffix while Release keeps the canonical
/// id, so a Debug `sissy-cli` reads what a dev `Sissy.app` wrote.
enum SissyPaths {
    /// True when the running bundle id ends in `.dev`. False for a bundle with
    /// no identifier at all, so a test harness cannot pollute a `Sissy-Dev/`
    /// tree nothing else reads.
    static let isDev: Bool = {
        // `sissy-cli` is a command-line tool, not a `.app`, but its Info.plist
        // lives in the binary's `__TEXT,__info_plist` section via
        // `CREATE_INFOPLIST_SECTION_IN_BINARY: YES`, so this resolves there too.
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return id.hasSuffix(".dev")
    }()

    /// `Sissy` (release) or `Sissy-Dev` (Debug). Used as both the
    /// `Application Support` and the `Library/Logs` subdirectory, so one
    /// install's `preferences.json`, `server.json`, usage state and log file
    /// all live under a single isolated tree.
    static var supportDirName: String { isDev ? "Sissy-Dev" : "Sissy" }

    static var appSupportDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/\(supportDirName)")
    }

    static var logsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/\(supportDirName)")
    }
}
