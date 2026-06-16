import Foundation
import Observation
import Security
import ServiceManagement

/// Controls the bundled LaunchAgent through Apple's ServiceManagement API.
/// The agent plist lives inside Sissy.app/Contents/Library/LaunchAgents
/// and points at the bundled server executable in Contents/MacOS with `BundleProgram`, so the
/// registration survives app relocation without writing plist files into
/// ~/Library/LaunchAgents.
@MainActor
@Observable
final class ServerServiceController {
    /// LaunchAgent label. `com.radonforge.sissy.server` for release;
    /// `com.radonforge.sissy.server.dev` for Debug. Derived from the app's
    /// own bundle id so the right plist is registered with launchd — a
    /// release Sissy.app and a dev Sissy.app on the same machine each own
    /// their agent without colliding.
    nonisolated static let label: String =
        (Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true)
        ? "com.radonforge.sissy.server.dev"
        : "com.radonforge.sissy.server"
    nonisolated static let plistName = "\(label).plist"
    nonisolated static let daemonRelativePath = "Contents/MacOS/sissy-serverd"
    nonisolated static let agentRelativePath = "Contents/Library/LaunchAgents/\(plistName)"

    private(set) var status: SMAppService.Status = .notRegistered
    var isTransitioning: Bool = false
    var transitionLabel: String = ""

    @ObservationIgnored private let service: SMAppService
    private let logsURL: URL = ServerServiceController.defaultLogsURL

    init(service: SMAppService = .agent(plistName: ServerServiceController.plistName)) {
        self.service = service
        Task { await self.refresh() }
    }

    static var defaultLogsURL: URL { SissyPaths.logsDir }

    var isAvailable: Bool { Self.bundledLaunchAgentIsPresent() }
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }
    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }
    var openableLogsURL: URL { logsURL }

    nonisolated static func bundledLaunchAgentIsPresent(
        in appBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> Bool {
        let plistURL = appBundleURL.appendingPathComponent(agentRelativePath)
        let daemonURL = appBundleURL.appendingPathComponent(daemonRelativePath)
        guard fileManager.fileExists(atPath: plistURL.path),
            fileManager.fileExists(atPath: daemonURL.path),
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist["Label"] as? String == label
            && plist["BundleProgram"] as? String == daemonRelativePath
    }

    func refresh() async {
        status = service.status
    }

    enum ServiceError: LocalizedError {
        case notFound
        case requiresApproval
        case codesignRejected(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return
                    "Bundled LaunchAgent plist or daemon executable is missing from the Sissy app bundle. Rebuild and relaunch the app."
            case .requiresApproval:
                return "macOS requires approval for the Sissy server in Login Items before it can run."
            case .codesignRejected(let detail):
                return """
                    macOS rejected Sissy's bundled LaunchAgent because the app is not signed with a trusted code-signing identity.

                    \(detail)

                    Refresh the Apple Development certificate in Xcode if needed, then rebuild with scripts/dev-build-app.sh. Don't launch a CODE_SIGNING_ALLOWED=NO build when testing Server start/stop.
                    """
            }
        }
    }

    func start(readiness: (() async -> Bool)? = nil) async throws {
        beginTransition("Starting...")
        defer { endTransition() }

        guard Self.bundledLaunchAgentIsPresent() else {
            throw ServiceError.notFound
        }
        if let signingIssue = Self.bundledCodeSigningIssue() {
            throw ServiceError.codesignRejected(signingIssue)
        }

        await refresh()
        switch status {
        case .notFound:
            try register()
        case .requiresApproval:
            throw ServiceError.requiresApproval
        case .notRegistered:
            try register()
        case .enabled:
            break
        @unknown default:
            break
        }

        await waitUntilStarted(timeoutSeconds: 10, readiness: readiness)
    }

    func stop(readiness: (() async -> Bool)? = nil) async throws {
        beginTransition("Stopping...")
        defer { endTransition() }

        await refresh()
        if isRegistered {
            try unregister()
        }
        await waitUntilStopped(timeoutSeconds: 6, readiness: readiness)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func errorLogBookmark() -> ErrorLogBookmark {
        let url = logsURL.appendingPathComponent("sissy.err.log")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        return ErrorLogBookmark(offset: size)
    }

    func startFailureHint(since bookmark: ErrorLogBookmark, port: Int) -> String? {
        Self.startFailureHint(from: errorLog(since: bookmark), port: port)
    }

    static func startFailureHint(from log: String, port: Int) -> String? {
        if log.contains("Address already in use") || log.contains("errno: 48") {
            return
                "Port \(port) is already in use. Stop the process using that port, or change Sissy's server port, then start the server again."
        }
        if log.contains("config load failed") {
            return
                "The daemon could not load its server configuration. Open Logs for the detailed error, then save preferences or restart the server."
        }
        if log.contains("start failed") {
            return "The daemon exited during startup. Open Logs for the detailed launch error."
        }
        return nil
    }

    struct ErrorLogBookmark: Equatable {
        let offset: UInt64
    }

    private func register() throws {
        do {
            try service.register()
        } catch {
            let nsError = error as NSError
            if nsError.code == kSMErrorAlreadyRegistered {
                return
            }
            if Self.isCodesignFailure(nsError) {
                throw ServiceError.codesignRejected(nsError.localizedDescription)
            }
            throw error
        }
    }

    private func unregister() throws {
        do {
            try service.unregister()
        } catch {
            let nsError = error as NSError
            if nsError.code == kSMErrorJobNotFound {
                return
            }
            throw error
        }
    }

    private func beginTransition(_ label: String) {
        isTransitioning = true
        transitionLabel = label
    }

    private func endTransition() {
        isTransitioning = false
        transitionLabel = ""
    }

    private func waitUntilStarted(timeoutSeconds: Double, readiness: (() async -> Bool)?) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            await refresh()
            if let readiness, await readiness() { return }
            if status == .requiresApproval { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func waitUntilStopped(timeoutSeconds: Double, readiness: (() async -> Bool)?) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            await refresh()
            if let readiness, await readiness() { return }
            if status == .notRegistered { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func errorLog(since bookmark: ErrorLogBookmark) -> String {
        let url = logsURL.appendingPathComponent("sissy.err.log")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attrs[.size] as? NSNumber)?.uint64Value,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return "" }
        defer { try? handle.close() }
        let offset = min(bookmark.offset, size)
        do {
            try handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    nonisolated static func isCodesignFailure(_ error: NSError) -> Bool {
        error.code == -67056
            || error.localizedDescription.localizedCaseInsensitiveContains("codesigning failure")
    }

    nonisolated static func bundledCodeSigningIssue(
        in appBundleURL: URL = Bundle.main.bundleURL
    ) -> String? {
        let appName = appBundleURL.lastPathComponent
        let daemonURL = appBundleURL.appendingPathComponent(daemonRelativePath)

        switch checkSignedCode(at: appBundleURL, displayName: appName) {
        case .invalid(let message):
            return message
        case .signed(let appTeamID):
            switch checkSignedCode(at: daemonURL, displayName: "sissy-serverd") {
            case .invalid(let message):
                return message
            case .signed(let daemonTeamID):
                if appTeamID != daemonTeamID {
                    return """
                        \(appName) is signed by team \(appTeamID), but sissy-serverd is signed by team \(daemonTeamID). Rebuild both targets together.
                        """
                }
                return nil
            }
        }
    }

    private enum CodeSigningCheck {
        case signed(String)
        case invalid(String)
    }

    private nonisolated static func checkSignedCode(
        at url: URL,
        displayName: String
    ) -> CodeSigningCheck {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            return .invalid(
                "\(displayName) is not signed or cannot be read by codesign: \(describe(status))."
            )
        }

        status = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
            nil
        )
        guard status == errSecSuccess else {
            return .invalid("\(displayName)'s code signature is invalid: \(describe(status)).")
        }

        var rawInfo: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInfo
        )
        guard status == errSecSuccess,
            let info = rawInfo as? [CFString: Any]
        else {
            return .invalid(
                "\(displayName)'s signing information could not be read: \(describe(status))."
            )
        }

        guard let teamID = info[kSecCodeInfoTeamIdentifier] as? String,
            !teamID.isEmpty
        else {
            return .invalid(
                "\(displayName) is ad-hoc signed or unsigned; no Apple TeamIdentifier is present."
            )
        }

        return .signed(teamID)
    }

    private nonisolated static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (\(status))"
        }
        return "OSStatus \(status)"
    }
}
