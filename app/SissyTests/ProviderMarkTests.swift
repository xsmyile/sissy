import AppKit
import XCTest

@testable import Sissy

/// The optical correction that makes a provider's mark look level with the
/// text beside it.
final class ProviderMarkTests: XCTestCase {

    /// A row like "Claude Code" has no descenders, so its ink stops at the
    /// baseline while its line box reserves room below it. Centring a mark on
    /// that box centres it on empty space and the mark reads high, which is
    /// why the correction is downward rather than nothing.
    func testCapitalsSitBelowTheCentreOfTheirLineBox() {
        XCTAssertGreaterThan(ProviderMark.capCentreOffset(forTextSize: 13), 0)
    }

    /// Read off the font, so a row set larger is corrected by more. A fixed
    /// number would be right at one size and wrong at every other.
    func testTheCorrectionGrowsWithTheText() {
        XCTAssertGreaterThan(
            ProviderMark.capCentreOffset(forTextSize: 24),
            ProviderMark.capCentreOffset(forTextSize: 12))
    }

    /// It is a nudge, not a layout: a correction that reached a whole point at
    /// the sizes the panel uses would mean the metrics were being read wrong.
    func testTheCorrectionStaysSubPointAtPanelSizes() {
        for textSize in [CGFloat(11), 12, 13] {
            XCTAssertLessThan(ProviderMark.capCentreOffset(forTextSize: textSize), 1)
        }
    }
}
