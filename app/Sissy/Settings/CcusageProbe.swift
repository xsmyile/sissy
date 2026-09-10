import Foundation

/// Which `ccusage` is installed on this machine, for the diagnostics report.
///
/// Two programs answer to the name. The npm package is the cost oracle Sissy is
/// measured against in CI; Homebrew's formula compiles a separate Rust
/// implementation out of the same repository, and the two have shipped
/// disagreeing cache-write conventions — a 1-hour cache write billed at the
/// 5-minute rate reads as Sissy over-billing by ~7% on a real day, which it is
/// not. A report saying "ccusage disagrees with Sissy" is therefore
/// unactionable until it names the binary behind the number.
///
/// Nothing is executed. The version is read off the install layout — npm keeps
/// it in the package manifest, Homebrew in the Cellar path — so gathering this
/// stays a synchronous, side-effect-free read that cannot hang the menu bar on
/// a subprocess that never returns.
enum CcusageProbe {
    /// One `ccusage` found on disk. `version` is absent for an install whose
    /// layout does not carry one, which is itself worth reporting: it means
    /// neither of the two known distributions put it there.
    struct Install: Equatable {
        let path: String
        let kind: Kind
        let version: String?
    }

    enum Kind: Equatable {
        /// The npm package — the oracle. Its executable resolves inside a
        /// `node_modules` tree whatever prefix or version manager installed it.
        case npm
        /// Homebrew's formula, which builds the Rust implementation.
        case homebrew
        /// Anything else: a `cargo install`, a hand-placed binary, a distribution
        /// that did not exist when this was written.
        case other
    }

    /// Every `ccusage` reachable from a well-known install location, newest
    /// path first within each root, deduplicated by what the symlinks resolve
    /// to.
    ///
    /// Deliberately not `which`: an app launched from Finder inherits
    /// `/usr/bin:/bin:/usr/sbin:/sbin` and would miss every install, and a
    /// version manager's active `bin` is a per-shell directory that does not
    /// outlive the terminal that made it. Finding two is not an error to
    /// resolve — it is the most useful thing the report can say, because the
    /// shell picks one and the user's expectation follows the other.
    static func installs(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        systemBinDirs: [String] = Self.defaultSystemBinDirs,
        fileManager: FileManager = .default
    ) -> [Install] {
        var seen = Set<String>()
        var found: [Install] = []
        let candidates = candidatePaths(
            home: home, systemBinDirs: systemBinDirs, fileManager: fileManager)
        for candidate in candidates {
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            let resolved = candidate.resolvingSymlinksInPath().path
            guard seen.insert(resolved).inserted else { continue }
            let kind = kind(resolvedPath: resolved)
            found.append(
                Install(
                    path: abbreviate(candidate.path, home: home),
                    kind: kind,
                    version: version(kind: kind, resolvedPath: resolved, fileManager: fileManager)
                )
            )
        }
        return found
    }

    /// Which distribution put an executable at `resolvedPath`, decided by where
    /// the symlinks land rather than by where the user's `PATH` points.
    static func kind(resolvedPath: String) -> Kind {
        if resolvedPath.contains("/node_modules/") { return .npm }
        if resolvedPath.contains("/Cellar/") { return .homebrew }
        return .other
    }

    /// The version out of a Homebrew Cellar path
    /// (`…/Cellar/ccusage/20.1.0/bin/ccusage` → `20.1.0`). Homebrew's layout
    /// puts it there by construction, so there is nothing to read.
    static func homebrewVersion(resolvedPath: String) -> String? {
        let components = resolvedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard let cellar = components.firstIndex(of: "Cellar"),
            cellar + 2 < components.count
        else { return nil }
        return String(components[cellar + 2])
    }

    /// The package directory an npm-installed executable sits under
    /// (`…/node_modules/ccusage/src/cli.js` → `…/node_modules/ccusage`), so its
    /// manifest can be read for the version. Nil when the path does not end up
    /// inside a package of that name — a scoped fork, or a rename.
    static func npmPackageRoot(resolvedPath: String) -> String? {
        let marker = "/node_modules/\(executableName)"
        guard let range = resolvedPath.range(of: marker, options: .backwards) else { return nil }
        let root = String(resolvedPath[resolvedPath.startIndex..<range.upperBound])
        let remainder = resolvedPath[range.upperBound...]
        guard remainder.isEmpty || remainder.hasPrefix("/") else { return nil }
        return root
    }

    private static let executableName = "ccusage"

    /// Absolute directories that hold a `ccusage` on a normal Mac. Injectable
    /// rather than read straight from the constant so a test can scope the
    /// scan to a temporary home instead of finding whatever the machine
    /// running it happens to have installed.
    static let defaultSystemBinDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Home-relative `bin` directories for the runtimes that install into the
    /// user's own account.
    private static let homeBinDirs = [".local/bin", ".bun/bin", ".cargo/bin", ".volta/bin"]

    /// Node version managers keep one prefix per installed runtime, so the
    /// executable lives under a directory named after a version this code
    /// cannot know. Each entry is the root to enumerate and the path from one
    /// of its children down to the `bin` directory.
    private static let versionManagerRoots: [(root: String, binSubpath: String)] = [
        (".local/share/fnm/node-versions", "installation/bin"),
        (".nvm/versions/node", "bin"),
    ]

    private static func candidatePaths(
        home: URL,
        systemBinDirs: [String],
        fileManager: FileManager
    ) -> [URL] {
        var paths = systemBinDirs.map {
            URL(fileURLWithPath: $0).appendingPathComponent(executableName)
        }
        paths += homeBinDirs.map {
            home.appendingPathComponent($0).appendingPathComponent(executableName)
        }
        for entry in versionManagerRoots {
            let root = home.appendingPathComponent(entry.root)
            let versions =
                (try? fileManager.contentsOfDirectory(atPath: root.path))?.sorted(by: >) ?? []
            paths += versions.map {
                root.appendingPathComponent($0)
                    .appendingPathComponent(entry.binSubpath)
                    .appendingPathComponent(executableName)
            }
        }
        return paths
    }

    private static func version(
        kind: Kind,
        resolvedPath: String,
        fileManager: FileManager
    ) -> String? {
        switch kind {
        case .homebrew:
            return homebrewVersion(resolvedPath: resolvedPath)
        case .npm:
            guard let root = npmPackageRoot(resolvedPath: resolvedPath) else { return nil }
            return manifestVersion(atPackageRoot: root, fileManager: fileManager)
        case .other:
            return nil
        }
    }

    /// Reads `version` out of a package manifest. Untrusted file content: the
    /// value lands in a report the user pastes in public, so anything that is
    /// not a short single-line string is dropped rather than quoted.
    private static func manifestVersion(
        atPackageRoot root: String,
        fileManager: FileManager
    ) -> String? {
        let manifest = URL(fileURLWithPath: root).appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: manifest.path),
            let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["version"] as? String,
            !version.isEmpty, version.count <= maxVersionLength,
            !version.contains(where: \.isNewline)
        else { return nil }
        return version
    }

    private static let maxVersionLength = 32

    private static func abbreviate(_ path: String, home: URL) -> String {
        guard path.hasPrefix(home.path) else { return path }
        return "~" + path.dropFirst(home.path.count)
    }
}
