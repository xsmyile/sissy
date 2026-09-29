import Foundation

@testable import Sissy

extension ServerConfig {
    /// `defaults` with both log trees pointed into a test's own directory and
    /// every switch that reaches the network or the machine off: remote
    /// pricing, `statusChecks`, `macHealth`, `disk` and `network`. A suite that
    /// exercises one of them turns it back on by name.
    ///
    /// The one place those switches are listed, because each engine suite used
    /// to turn them off by hand, and a switch that ships on by default then had
    /// to be added to every copy: the copy that missed it reached the network
    /// or the machine without a test saying so. A new default-on switch with a
    /// side effect belongs here.
    static func hermetic(claudeDir: URL, codexDir: URL) -> ServerConfig {
        var config = ServerConfig.defaults
        config.claudeDataDir = claudeDir.path
        config.codexDataDir = codexDir.path
        config.remotePricing = false
        config.statusChecks = false
        config.macHealth = false
        config.disk = false
        config.network = false
        return config
    }
}
