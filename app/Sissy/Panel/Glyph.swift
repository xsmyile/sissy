import SwiftUI

/// Every glyph Sissy draws that is not a mark of its own or a vendor's: a
/// Hugeicons symbol (the free Stroke Rounded set), compiled into the asset
/// catalogue as a custom SF Symbol so it takes `font` and tint the way a
/// system symbol does. It has one weight whatever `font` asks for, and
/// `scripts/generate-glyphs.py` says why.
///
/// The raw value is the Hugeicons name and the asset's, and this list is the
/// one `scripts/generate-glyphs.py` reads: a case added here is a symbolset
/// that script writes, and one removed is a symbolset it deletes. Nothing
/// draws a glyph by its bare name, because `Image(_:)` given a name the
/// catalogue lacks draws nothing rather than failing.
///
/// A glyph is decorative: `Image(_:)` would hand VoiceOver the asset's name,
/// `ArrowLeft01` where the system symbol said "Back", so a control drawn with
/// nothing but a glyph names itself with `accessibilityLabel`.
enum Glyph: String, CaseIterable {
    case dashboardSpeed02 = "DashboardSpeed02"
    case aiProgramming = "AiProgramming"
    case computerActivity = "ComputerActivity"
    case hardDrive = "HardDrive"
    case arrowDataTransferVertical = "ArrowDataTransferVertical"
    case gitFork = "GitFork"
    case refresh01 = "Refresh01"
    case calendar03 = "Calendar03"
    case arrowLeft01 = "ArrowLeft01"
    case arrowRight01 = "ArrowRight01"
    case arrowDown01 = "ArrowDown01"
    case coffee02 = "Coffee02"
    case settings01 = "Settings01"
    case alert02 = "Alert02"
    case tick02 = "Tick02"
    case userSwitch = "UserSwitch"
    case arrowUpRight01 = "ArrowUpRight01"
    case gitMerge = "GitMerge"
    case circleDot = "CircleDot"
    case comment02 = "Comment02"
    case clock01 = "Clock01"
    case playCircle = "PlayCircle"
    case cloudUpload = "CloudUpload"
    case gitPullRequest = "GitPullRequest"
    case view = "View"
    case bot = "Bot"
    case informationCircle = "InformationCircle"
    case alertCircle = "AlertCircle"
    case user = "User"
    case userAdd01 = "UserAdd01"
    case moreHorizontal = "MoreHorizontal"
    case star = "Star"
}

extension Image {
    init(_ glyph: Glyph) {
        self.init(decorative: glyph.rawValue)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, glyph: Glyph) {
        self.init {
            Text(title)
        } icon: {
            Image(glyph)
        }
    }
}
