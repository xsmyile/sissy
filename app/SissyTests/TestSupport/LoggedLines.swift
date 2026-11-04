import Foundation

@testable import Sissy

/// What the process has logged, read back off the file `sissyLog` writes, for
/// the failures whose only outcome is a line.
enum LoggedLines {
    /// Whether any line holds `marker`, which a test makes unique to itself.
    static func contain(_ marker: String) -> Bool {
        ["sissy.err.log", "sissy.err.1.log"].contains { name in
            let url = SissyPaths.logsDir.appendingPathComponent(name)
            return (try? String(contentsOf: url, encoding: .utf8))?.contains(marker) ?? false
        }
    }
}
