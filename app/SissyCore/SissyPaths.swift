import Foundation

/// Resolves the on-disk locations that differ between a release and a Debug
/// build so two installs can coexist. Detection is bundle-id based:
/// `project.yml` gives Debug a `.dev` suffix while Release keeps the canonical
/// id, so a Debug `sissy-cli` reads what a dev `Sissy.app` wrote.
enum SissyPaths {
    /// The id `project.yml` gives the release `Sissy.app`.
    static let releaseBundleIdentifier = "com.radonforge.sissy"

    /// What `project.yml` appends to a target's id for its Debug build, and
    /// what `isDev` looks for.
    static let devBundleSuffix = ".dev"

    /// The id of a Debug `Sissy.app`, which `scripts/dev-build-app.sh` signs.
    static let devBundleIdentifier = releaseBundleIdentifier + devBundleSuffix

    /// The id `project.yml` gives a Release `sissy-cli`, read from the
    /// binary's embedded Info.plist.
    static let cliBundleIdentifier = "com.radonforge.sissy.cli"

    /// The id of a Debug `sissy-cli`.
    static let cliDevBundleIdentifier = cliBundleIdentifier + devBundleSuffix

    /// True when the running bundle id ends in `.dev`. False for a bundle with
    /// no identifier at all, so a `swift test` binary cannot pollute a
    /// `Sissy-Dev/` tree nothing else reads.
    static let isDev: Bool = {
        // `sissy-cli` is a command-line tool, not a `.app`, but its Info.plist
        // lives in the binary's `__TEXT,__info_plist` section via
        // `CREATE_INFOPLIST_SECTION_IN_BINARY: YES`, so this resolves there too.
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return id.hasSuffix(devBundleSuffix)
    }()

    /// `Sissy` (release) or `Sissy-Dev` (Debug). Used as both the
    /// `Application Support` and the `Library/Logs` subdirectory, so one
    /// install's `preferences.json`, `server.json`, usage state and log file
    /// all live under a single isolated tree.
    static var supportDirName: String { isDev ? "Sissy-Dev" : "Sissy" }

    /// Namespace every keychain item Sissy owns is filed under: the release
    /// bundle id, or the Debug one.
    ///
    /// Split for the reason the support directory is. What names a credential
    /// — which account a session belongs to, which organisation it is read
    /// for — lives in that directory, so two builds sharing one set of items
    /// and not the index beside it drew every item the other build linked as
    /// a bare uuid, measured 2026-09-22 on a Mac running both. The other
    /// build's item also answers a scheduled read with
    /// `errSecInteractionNotAllowed`, being another signature's, so the row
    /// carried no reading either.
    private static var keychainNamespace: String {
        isDev ? devBundleIdentifier : releaseBundleIdentifier
    }

    /// The keychain service for one kind of item Sissy owns, in this build's
    /// namespace.
    static func keychainService(_ item: String) -> String {
        "\(keychainNamespace).\(item)"
    }

    /// True when a test runner launched this process.
    ///
    /// The unit tests are hosted inside `Sissy.app`, so the bundle id they run
    /// under is the dev app's own and `isDev` answers for both: every
    /// `xcodebuild test` appended its stderr to the log of the Sissy the
    /// developer was running, which is the one file read after a crash.
    /// Xcode exports the variable before the host process starts, so this
    /// answers the same whenever it is first asked.
    static let isTestHarness: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Where a test harness's own tree goes, keyed by pid so two suites run
    /// from two worktrees never share one. Under `$TMPDIR`, which the system
    /// prunes, because nothing here is meant to be read after the run.
    private static var testRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-tests-\(ProcessInfo.processInfo.processIdentifier)")
    }

    static var appSupportDir: URL {
        if isTestHarness { return testRoot.appendingPathComponent("Application Support") }
        return appSupportDir(home: URL(fileURLWithPath: NSHomeDirectory()))
    }

    /// This build's support directory under `home`, for a caller that has a
    /// home of its own to answer for rather than the one `NSHomeDirectory()`
    /// reports.
    static func appSupportDir(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/\(supportDirName)")
    }

    static var logsDir: URL {
        if isTestHarness { return testRoot.appendingPathComponent("Logs") }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/\(supportDirName)")
    }
}
