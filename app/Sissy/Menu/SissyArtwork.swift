import AppKit

/// Sissy's menu bar artwork: the silhouette, and the eye that is lit over it
/// while the Mac is being held awake.
///
/// Both stay template images and the eye is a second image drawn above the
/// first, rather than the two being composited into one. That is not a style
/// choice — **a status item's greyscale is vibrancy-blended with what is
/// behind the menu bar, and only a template image is exempt.** Measured on
/// macOS 26 against a dark menu bar: the template's ink peaks at 230, the same
/// silhouette filled white inside a non-template image peaks at 157, and the
/// same silhouette filled `systemRed` peaks at 235. So a composite costs the
/// body two fifths of its ink the moment a hold starts — the dim the shut eye
/// replaced, brought back to report something else — while a saturated colour
/// laid over a template comes through at full strength.
///
/// What a lit eye is laid over is `eyeless`, never the whole cat: the
/// silhouette carries its own eye as ink, and blue drawn on top of it leaves
/// that ink showing through the antialiased edge as a fringe — about a third
/// of the eye at the ~5×3 device pixels the menu bar draws it in, and
/// invisible in the panel at 24 pt, which is what makes it easy to ship.
///
/// Both halves are derived from the silhouette by `scripts/sissy-eye-assets.py`
/// rather than drawn: they are the final subpath of the same single `<path>`
/// and everything before it, each carried over with the source file's own
/// transform chain, so the two register pixel-for-pixel across all 26 poses
/// and frames.
enum SissyArtwork {
    enum AssetError: LocalizedError {
        case missingImage(String)

        var errorDescription: String? {
            switch self {
            case .missingImage(let name):
                "Missing Sissy frame \(name). Regenerate the asset catalogue."
            }
        }
    }

    /// The blue the panel's keep-awake switch already carries, for the same
    /// reason it carries it: on this platform blue is the colour of a control
    /// that is engaged. The system's own rather than a literal, so it follows
    /// the appearance and whatever the user has set for colour.
    static let holdTint: NSColor = .systemBlue

    /// The eye cut out of `name`, which every Sissy asset has a counterpart for.
    static func eyeAssetName(for name: String) -> String { name + eyeSuffix }

    /// `name` with the eye taken out of it, the other half of the same split.
    static func eyelessAssetName(for name: String) -> String { name + eyelessSuffix }

    /// The asset as the catalogue holds it: a template image, tinted by
    /// whichever surface draws it.
    static func silhouette(_ name: String, size: CGFloat) throws -> NSImage {
        let image = try load(name, size: size)
        image.isTemplate = true
        return image
    }

    /// The eye alone, at the silhouette's own size and origin, so drawing it
    /// centred in the same rect lands it on the eye it covers.
    static func eye(_ name: String, size: CGFloat) throws -> NSImage {
        try silhouette(eyeAssetName(for: name), size: size)
    }

    /// The silhouette with the eye's own ink taken out, which is what a lit
    /// eye is drawn over.
    static func eyeless(_ name: String, size: CGFloat) throws -> NSImage {
        try silhouette(eyelessAssetName(for: name), size: size)
    }

    private static let eyeSuffix = "Eye"
    private static let eyelessSuffix = "Eyeless"

    /// `NSImage(named:)` hands back the catalogue's shared instance, so every
    /// caller copies before resizing: mutating it would resize Sissy
    /// everywhere else she is drawn.
    private static func load(_ name: String, size: CGFloat) throws -> NSImage {
        guard let image = NSImage(named: name)?.copy() as? NSImage else {
            throw AssetError.missingImage(name)
        }
        image.size = NSSize(width: size, height: size)
        return image
    }
}

/// The lit eye, as a view over the status button's own image.
///
/// It refuses the hit test outright: a plain `NSImageView` answers for the
/// pixels it covers, and the one thing sitting on the status button must never
/// be the thing that swallows a click on it.
final class SissyEyeOverlay: NSImageView {
    /// Centred and unscaled, which is how the button draws its own image, so
    /// an eye cut from the same canvas lands on the eye it covers.
    static func installed(on button: NSButton) -> SissyEyeOverlay {
        let overlay = SissyEyeOverlay()
        overlay.imageScaling = .scaleNone
        overlay.imageAlignment = .alignCenter
        overlay.contentTintColor = SissyArtwork.holdTint
        overlay.isHidden = true
        button.addSubview(overlay)
        return overlay
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
