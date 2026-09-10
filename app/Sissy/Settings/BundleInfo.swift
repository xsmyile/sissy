import Foundation

/// What the running bundle already declares about itself, so the surfaces
/// that show the version or the author read it from one place instead of
/// restating it in code.
extension Bundle {
    /// `CFBundleShortVersionString`. A bundle reporting `0.0.0` is a local
    /// build by construction: every release path passes the version resolved
    /// from the git tag, and `project.yml` carries only a placeholder.
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    }

    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
    }

    /// `NSHumanReadableCopyright`, the one place the author and the license
    /// are already declared.
    var humanReadableCopyright: String {
        (infoDictionary?["NSHumanReadableCopyright"] as? String) ?? ""
    }
}
