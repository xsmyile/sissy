import AppKit
import Foundation

/// The text behind About's "Copy diagnostics": what an issue needs before
/// anyone can act on it, and nothing a user would hesitate to paste in
/// public. Token counts are exact rather than abbreviated, because a report
/// is read for its digits; costs are left out, since no report has needed
/// them and they're the one number a user may not want quoted.
struct DiagnosticsReport {
    /// Everything the report states, with nothing left to look up. Pure by
    /// construction so the wording is testable without a bundle, a clock or
    /// a live daemon.
    struct Snapshot: Equatable {
        let version: String
        let build: String
        let systemVersion: String
        let endpoint: String
        let serverState: String
        let linkIsConnected: Bool
        let claudeLimits: Bool
        let providers: [DisplayFrame.ProviderSlice]
    }

    static func text(_ snapshot: Snapshot) -> String {
        [
            "Sissy \(snapshot.version) (\(snapshot.build))",
            "macOS \(normalize(systemVersion: snapshot.systemVersion))",
            "Server: \(snapshot.serverState) at \(snapshot.endpoint)",
            "Link: \(snapshot.linkIsConnected ? "connected" : "disconnected")",
            "Claude limits: \(snapshot.claudeLimits ? "on" : "off")",
            "Providers: \(describe(snapshot.providers))",
        ].joined(separator: "\n")
    }

    @MainActor
    static func current(
        model: SissyModel,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> String {
        let prefs = model.preferences
        return text(
            Snapshot(
                version: bundle.shortVersion,
                build: bundle.buildNumber,
                systemVersion: processInfo.operatingSystemVersionString,
                endpoint: "\(prefs.serverHost):\(prefs.serverPort)",
                serverState: model.menuSnapshot.server.subtitle,
                linkIsConnected: model.webSocketClient.isConnected,
                claudeLimits: prefs.claudeLimits,
                providers: model.currentFrame?.providers ?? []
            )
        )
    }

    @MainActor
    static func copyToClipboard(model: SissyModel) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(current(model: model), forType: .string)
    }

    /// `operatingSystemVersionString` reads "Version 26.0 (Build 25A354)".
    /// The report already says which OS this is, so the prefix is noise.
    private static func normalize(systemVersion: String) -> String {
        let prefix = "Version "
        guard systemVersion.hasPrefix(prefix) else { return systemVersion }
        return String(systemVersion.dropFirst(prefix.count))
    }

    private static func describe(_ slices: [DisplayFrame.ProviderSlice]) -> String {
        guard !slices.isEmpty else { return "none reported" }
        return slices.map { slice in
            "\(slice.id) \(slice.tokens) tokens, \(describe(slice.windows))"
        }
        .joined(separator: "; ")
    }

    private static func describe(_ windows: [DisplayFrame.UsageWindow]) -> String {
        guard !windows.isEmpty else { return "no windows" }
        return
            windows
            .map { "\($0.minutes)m \(Int($0.usedPercent.rounded()))%" }
            .joined(separator: " ")
    }
}
