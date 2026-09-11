import Foundation

/// Mirror of the app's `SissyPaths` helper for the command-line target. Same
/// resolution rule (bundle id `.dev` suffix → dev tree) so a Debug `sissy-cli`
/// reads what the dev `Sissy.app` wrote. Two copies because the targets don't
/// share a Swift module; keep them in lockstep.
enum SissyPaths {
    static let isDev: Bool = {
        // The tool's Info.plist lives in the binary's `__TEXT,__info_plist`
        // section via `CREATE_INFOPLIST_SECTION_IN_BINARY: YES`, so
        // `Bundle.main.bundleIdentifier` resolves even though `sissy-cli` is
        // a command-line tool, not a `.app`.
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return id.hasSuffix(".dev")
    }()

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
