import AppKit

/// Sissy's menu bar artwork: the silhouette, the eye that is lit over it while
/// the Mac is being held awake, and the dot behind her neck while the Mac is
/// short of memory or disk.
///
/// All of them stay template images and each tinted layer is a second image
/// drawn above the silhouette, rather than the two being composited into one. That is not a style
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
    /// The panel's own warning colour, the one the Mac line on the Overview
    /// wears at the same level, so the dot and the line it leads to agree.
    ///
    /// Orange rather than the system's yellow because the dot sits on the
    /// menu bar's own background, and a light menu bar is where it has to
    /// read: computed 2026-09-27 from the light-appearance system colours
    /// against a bar at 240 grey, the system's yellow stands at a WCAG
    /// contrast of 1.33 and its orange at 1.93, where the blue the hold is lit
    /// in stands at 3.52 and the red at 3.11. The yellow was a dot that had
    /// gone out.
    static let warnTint: NSColor = .systemOrange
    static let criticalTint: NSColor = .systemRed

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

    /// The dot alone, at the silhouette's own size and origin.
    static func dot(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect(in: rect, margin: 0)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// `body` with the dot and a ring around it cut out of its ink, which is
    /// what the dot is drawn over.
    ///
    /// The ring is what keeps the dot a dot: measured 2026-09-27 against every
    /// pose and frame, no point in the corner behind the neck clears the ink
    /// by more than 2.33 of the canvas's 22, so a dot large enough to read
    /// touches it, and at 5 device pixels a colour touching ink merges into it.
    /// Drawn rather than rasterized, so the cut is taken at whatever scale the
    /// menu bar renders at.
    static func knockedOut(_ body: NSImage) -> NSImage {
        let image = NSImage(size: body.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            body.draw(in: rect)
            context.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect(in: rect, margin: dotGap)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Where the dot sits, in the units of the 22 pt canvas every Sissy asset
    /// is drawn on and measured from its lower left: behind the neck, the one
    /// corner the head leaves empty in every pose.
    static let dotCanvas: CGFloat = 22
    static let dotCentre = CGPoint(x: 3.0, y: 2.6)
    static let dotRadius: CGFloat = 1.8
    static let dotGap: CGFloat = 0.9

    /// The dot's square in `rect`, grown by `margin` canvas units on every
    /// side.
    static func dotRect(in rect: NSRect, margin: CGFloat) -> NSRect {
        let scale = rect.width / dotCanvas
        let radius = (dotRadius + margin) * scale
        return NSRect(
            x: rect.minX + dotCentre.x * scale - radius,
            y: rect.minY + dotCentre.y * scale - radius,
            width: radius * 2,
            height: radius * 2
        )
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

/// What the dot behind Sissy's neck is saying, which decides its colour.
///
/// It is the Mac's level alone, and the eye stays the hold's: the two are
/// different questions, and one mark carrying both hid the hold for as long
/// as the Mac was under pressure. At normal, with the module off or before a
/// reading there is no dot, because an unread level is not a warning.
enum SissyDot: Equatable {
    case warn
    case critical

    init?(level: MacHealthLevel?) {
        switch level {
        case .critical: self = .critical
        case .warn: self = .warn
        case .normal, nil: return nil
        }
    }

    var tint: NSColor {
        switch self {
        case .warn: SissyArtwork.warnTint
        case .critical: SissyArtwork.criticalTint
        }
    }
}

/// A tinted layer over the status button's own image, cut from the same
/// canvas as the silhouette so it lands where that canvas puts it.
///
/// It refuses the hit test outright: a plain `NSImageView` answers for the
/// pixels it covers, and the one thing sitting on the status button must never
/// be the thing that swallows a click on it.
final class SissyOverlay: NSImageView {
    /// Centred and unscaled, which is how the button draws its own image, so
    /// a layer cut from the same canvas lands on the ink it belongs to.
    static func installed(on button: NSButton, tint: NSColor) -> SissyOverlay {
        let overlay = SissyOverlay()
        overlay.imageScaling = .scaleNone
        overlay.imageAlignment = .alignCenter
        overlay.contentTintColor = tint
        overlay.isHidden = true
        button.addSubview(overlay)
        return overlay
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
