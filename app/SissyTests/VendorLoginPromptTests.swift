import SwiftUI
import XCTest

@testable import Sissy

/// How tall the login window is drawn once the page gives way to a prompt.
///
/// Every prompt fills its window with `.frame(maxHeight: .infinity)`, which is
/// what made measuring one against an unbounded height answer with the
/// unbounded height, and every prompt as tall as the display.
@MainActor
final class VendorLoginPromptTests: XCTestCase {
    func testAShortPromptKeepsTheMinimumHeight() {
        let height = VendorLoginWindow.promptHeight(
            of: FillingPrompt(lines: 1), width: Self.width, minimum: Self.minimum)

        XCTAssertEqual(height, Self.minimum)
    }

    func testAPromptLongerThanTheMinimumGrowsToItsContentAndNoFurther() {
        let height = VendorLoginWindow.promptHeight(
            of: FillingPrompt(lines: 30), width: Self.width, minimum: Self.minimum)

        XCTAssertGreaterThan(height, Self.minimum)
        XCTAssertLessThan(height, Self.contentCeiling)
    }

    private static let width: CGFloat = 420
    private static let minimum: CGFloat = 260
    /// Thirty lines of callout text and a row of buttons, with room to spare:
    /// what a measurement that followed the proposal would overshoot by far.
    private static let contentCeiling: CGFloat = 2_000
}

/// The shape every login prompt shares: wrapped text, a spacer, a button row,
/// and a frame that fills the window.
private struct FillingPrompt: View {
    let lines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<lines, id: \.self) { _ in
                Text("A sentence long enough to wrap across the width of the prompt it sits in.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") {}
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
