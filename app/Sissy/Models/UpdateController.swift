import Foundation
import Observation
import Sparkle

/// Sissy's own updates, through Sparkle's standard updater and its windows.
///
/// Sparkle's `UserDefaults` are the state, and no copy of it lands in
/// `preferences.json`, for the reason `LoginItemController` gives for
/// `SMAppService`: the updater's own window can change a setting (its alert
/// carries the automatic-install checkbox), and a mirrored flag would then
/// claim something the updater had already undone. What is kept here is a
/// readout of those settings for SwiftUI, refreshed by key-value observation,
/// with every write going through to Sparkle.
///
/// Nothing is asked at first launch. `SUEnableAutomaticChecks` is declared in
/// the Info.plist, which is what stops Sparkle from prompting for permission
/// on the second one; the switches in About are where it is turned off.
///
/// A development build never starts it: `scripts/dev-build-app.sh` stamps the
/// real tag version on a Debug bundle, so the version cannot tell a dev build
/// from a release, and its `.dev` bundle id is the discriminator instead.
@MainActor
@Observable
final class UpdateController: NSObject {
    private(set) var isRunning = false
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecks = false
    private(set) var automaticallyInstalls = false
    /// Sparkle allows automatic installs only while automatic checks are on,
    /// so the install switch follows this rather than restating that rule.
    private(set) var allowsAutomaticInstalls = false
    private(set) var lastCheck: Date?

    /// What a check has found, as About words it under its button.
    enum CheckStatus: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case failed
    }

    /// Set by every check, whoever started it, so the band says what the last
    /// one found rather than only when it ran. `failed` is set only for the
    /// check About started, because a scheduled check that failed was never
    /// the user's to hear about.
    private(set) var checkStatus: CheckStatus = .idle

    /// The version a scheduled check found and put on screen, until that
    /// update session ends. A background app's scheduled alert is presented
    /// behind whatever is frontmost, so the status menu names the version as
    /// the way back to it.
    private(set) var pendingVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// A development build never runs the updater, and About says so by this
    /// rather than by `isRunning`, which is also false before `start()`.
    @ObservationIgnored let isDevBuild: Bool

    /// `isDevBuild` is injected so a test can stand the controller on either
    /// kind of build. Left to its default it asks about the running bundle.
    init(isDevBuild: Bool = SissyPaths.isDev) {
        self.isDevBuild = isDevBuild
        super.init()
    }

    /// Starts the updater once, on a release build. The first scheduled check
    /// is Sparkle's to time: it does not run at launch unless a day has passed
    /// since the last one.
    func start() {
        guard !isDevBuild, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        observe(controller.updater)
        isRunning = true
    }

    /// Checks now and shows what it finds. With an update already on screen,
    /// Sparkle brings that window forward instead of starting a second check,
    /// which is why the controls that call this stay enabled while it is up.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Checks without a window and reports in `checkStatus`, which is how
    /// About shows a check where its button is. A found update is then
    /// offered by the button, and pressing it is what opens Sparkle's alert.
    ///
    /// A probe does nothing while a session is in progress, so with one up,
    /// or with an update already found, this falls through to
    /// `checkForUpdates()`, which brings that session's window forward.
    /// A probe also skips versions the user skipped, which a check they
    /// start from the alert would still offer.
    func checkInline() {
        guard let controller else { return }
        guard !controller.updater.sessionInProgress, availableVersion == nil else {
            checkForUpdates()
            return
        }
        checkStatus = .checking
        controller.updater.checkForUpdateInformation()
    }

    /// The version the last check found, while nothing has declined it.
    var availableVersion: String? {
        guard case .available(let version) = checkStatus else { return nil }
        return version
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyInstalls(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    /// Where the appcast is read from, as the bundle declares it, so the
    /// Settings caption names the host a check reaches without restating it.
    @ObservationIgnored let feedHost: String? =
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        .flatMap(URL.init(string:))?.host()

    /// The line under About's check button. `lastCheck` is nil on a copy that
    /// has never checked, which says nothing rather than "never".
    nonisolated static func statusLine(_ status: CheckStatus, lastCheck: Date?) -> String? {
        let checked = lastCheck.map { $0.formatted(.relative(presentation: .named)) }
        switch status {
        case .checking:
            return "Checking for updates…"
        case .available(let version):
            return "Version \(version) is available"
        case .failed:
            return "Could not check for updates"
        case .upToDate:
            return checked.map { "Up to date · checked \($0)" } ?? "Up to date"
        case .idle:
            return checked.map { "Last checked \($0)" }
        }
    }

    /// What the status menu's update row reads.
    nonisolated static func menuTitle(pendingVersion: String?) -> String {
        guard let pendingVersion else { return "Check for Updates…" }
        return "Update to \(pendingVersion)…"
    }

    private func observe(_ updater: SPUUpdater) {
        observations = [
            track(updater, \.canCheckForUpdates) { $0.canCheckForUpdates = $1 },
            track(updater, \.automaticallyChecksForUpdates) { $0.automaticallyChecks = $1 },
            track(updater, \.automaticallyDownloadsUpdates) { $0.automaticallyInstalls = $1 },
            track(updater, \.allowsAutomaticUpdates) { $0.allowsAutomaticInstalls = $1 },
            track(updater, \.lastUpdateCheckDate) { $0.lastCheck = $1 },
        ]
    }

    /// Sparkle changes these on the main thread, which its headers require of
    /// every caller, so the handler is already on the main actor.
    private func track<Value: Sendable>(
        _ updater: SPUUpdater,
        _ keyPath: KeyPath<SPUUpdater, Value>,
        _ assign: @escaping @MainActor (UpdateController, Value) -> Void
    ) -> NSKeyValueObservation {
        updater.observe(keyPath, options: [.initial, .new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                assign(self, value)
            }
        }
    }
}

/// What Sparkle reports about a check, reduced to what `checkStatus` reads.
enum UpdateCheckEvent: Equatable {
    case found(String)
    case notFound
    /// The cycle ended, `failed` when Sparkle ended it with an error. Read 2026-09-24
    /// in Sparkle 2.x's basic update driver: a feed that could not be
    /// fetched aborts the cycle and never reports `notFound`, which Sparkle
    /// sends only after an appcast was read and held nothing newer.
    case finished(failed: Bool)
    case skipped
}

extension UpdateController {
    /// The status an event leaves. Only a check still `checking` at the end
    /// of its cycle found neither answer, so only that one reads as failed.
    nonisolated static func status(after event: UpdateCheckEvent, from status: CheckStatus)
        -> CheckStatus
    {
        switch event {
        case .found(let version):
            return .available(version)
        case .notFound:
            return .upToDate
        case .finished(let failed):
            guard status == .checking else { return status }
            return failed ? .failed : .idle
        case .skipped:
            return .idle
        }
    }

    private func record(_ event: UpdateCheckEvent) {
        checkStatus = Self.status(after: event, from: checkStatus)
    }
}

/// What every check found, whoever started it.
extension UpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        record(.found(item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        record(.notFound)
    }

    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
    ) {
        record(.finished(failed: error != nil))
    }

    /// A skipped version is one a probe will not find again, so the band
    /// stops offering it.
    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard choice == .skip else { return }
        record(.skipped)
    }
}

/// Sparkle's gentle reminders, which it asks a background app to declare.
/// Sparkle still presents every alert itself; the only reminder added is the
/// status menu naming the version while an alert that may be buried is up.
extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        pendingVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
