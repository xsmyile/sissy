import XCTest

@testable import Sissy

final class UsageReaderSharedTests: XCTestCase {
    private func contains(_ haystack: String, _ needle: String, from: Int = 0, to: Int? = nil)
        -> Bool
    {
        let bytes = Array(haystack.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return UsageReaderShared.bufferContains(
                base, from: from, to: to ?? bytes.count, pattern: Array(needle.utf8))
        }
    }

    func testFindsAPatternAnywhereInTheRange() {
        XCTAssertTrue(contains(#"{"subtype":"turn_duration"}"#, #""turn_duration""#))
        XCTAssertTrue(contains("abcdef", "ef"))
        XCTAssertTrue(contains("abcdef", "ab"))
    }

    func testMissesWhatIsNotThere() {
        XCTAssertFalse(contains("abcdef", "abd"))
        XCTAssertFalse(contains("abc", "abcd"))
    }

    /// The range bounds the search on both sides: a match that straddles
    /// either end is not in it.
    func testLooksOnlyInsideTheRange() {
        XCTAssertFalse(contains("abcdef", "ab", from: 1))
        XCTAssertFalse(contains("abcdef", "ef", to: 5))
        XCTAssertTrue(contains("abcdef", "cd", from: 2, to: 4))
    }
}
