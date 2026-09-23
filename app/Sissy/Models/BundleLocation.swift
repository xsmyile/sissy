import Foundation

/// Where the running bundle lives, as far as a login item is concerned.
///
/// `SMAppService.mainApp` registers the bundle at the path it is running
/// from, so a copy that will not be there at the next login registers a login
/// item that opens nothing, under a switch that still reads on. Two copies
/// are like that. A quarantined app opened where it was downloaded runs from
/// a randomized, read-only path macOS makes for it (App Translocation), and an
/// app opened inside its disk image runs from a volume that is gone once the
/// image is ejected. The README offers the disk image, so the second is one
/// double-click away for anyone who does not drag Sissy to Applications first.
enum BundleLocation: Equatable {
    /// A path that will still be there at the next login.
    case installed
    /// The randomized copy macOS runs a quarantined app from.
    case translocated
    /// A volume that cannot be written, which for an app is almost always the
    /// disk image it came in.
    case readOnlyVolume

    /// The path component every translocated copy sits under. It is the
    /// directory name macOS gives the mount, not an API: the Security
    /// framework call that answers the question directly is not in the
    /// public SDK.
    nonisolated static let translocationComponent = "AppTranslocation"

    /// The pure half: what a path and its volume say about the copy.
    /// Translocation is checked first because its mount is read-only too,
    /// and the two are worded differently to the user.
    nonisolated static func classify(path: String, volumeIsReadOnly: Bool) -> Self {
        if URL(fileURLWithPath: path).pathComponents.contains(translocationComponent) {
            return .translocated
        }
        return volumeIsReadOnly ? .readOnlyVolume : .installed
    }

    /// Where `bundle` is running from.
    ///
    /// A volume whose read-only flag cannot be read counts as writable: the
    /// answer only ever withholds the login item, and withholding it on a
    /// guess would take away the switch that keeps a day complete for a
    /// reason nobody could act on.
    static func current(bundle: Bundle = .main) -> Self {
        let url = bundle.bundleURL
        let readOnly = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly
        return classify(path: url.path, volumeIsReadOnly: readOnly ?? false)
    }

    /// Whether a login item registered from here would outlive the copy.
    var isTransient: Bool { self != .installed }

    /// What the Start-at-login row says instead of its caption when the copy
    /// is transient, and nil when it is not.
    var notice: String? {
        switch self {
        case .installed:
            nil
        case .translocated:
            "macOS is running a temporary copy of Sissy, so it cannot open at login. Move "
                + "Sissy to Applications and open it from there."
        case .readOnlyVolume:
            "Sissy is running from a read-only disk, such as the disk image it came in, so "
                + "it cannot open at login. Move it to Applications and open it from there."
        }
    }

    /// Why a login item was not registered from a transient copy.
    struct Refusal: LocalizedError, Equatable {
        let location: BundleLocation

        init(_ location: BundleLocation) {
            self.location = location
        }

        var errorDescription: String? { location.notice }
    }
}
