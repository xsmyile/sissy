import Foundation

/// Resolves on-disk locations that differ between release and Debug builds
/// so two installs can coexist. Detection is bundle-id based: project.yml
/// gives Debug a `.dev` suffix (`com.radonforge.sissy.dev`) while Release
/// keeps the canonical id. The daemon has a mirrored helper in
/// `SissyServer/SissyPaths.swift` — both must produce the same path for the
/// same install so the daemon reads what the app wrote.
enum SissyPaths {
    /// True when the running bundle id ends in `.dev`. False (release path)
    /// for any bundle without an identifier so a CLI-only test harness
    /// doesn't accidentally pollute a `Sissy-Dev/` dir that nothing else
    /// reads.
    static let isDev: Bool = {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return id.hasSuffix(".dev")
    }()

    /// `Sissy` (release) or `Sissy-Dev` (Debug). Used as both the
    /// `Application Support` and `Library/Logs` subdirectory so a dev
    /// daemon's preferences, server.json, milestones, usage-state, and log
    /// file all live under one isolated tree.
    static var supportDirName: String { isDev ? "Sissy-Dev" : "Sissy" }

    /// Default server port. Dev defaults to 8788 to avoid the canonical 8787
    /// taken by a release daemon on the same machine; user preferences
    /// override the default either way.
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
