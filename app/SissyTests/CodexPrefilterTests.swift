import XCTest

@testable import Sissy

/// Which rollout lines `CodexAdapter.lineMayCount` hands on to the parser.
///
/// The prefilter answers for a window of a buffer rather than a whole one,
/// because the tail passes it a line inside a chunk, so a marker has to sit
/// wholly inside that window to count.
final class CodexPrefilterTests: XCTestCase {
    private let adapter = CodexAdapter.fixture(
        codexDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-prefilter-\(UUID().uuidString)"))

    private static let types = ["token_count", "turn_context", "session_meta", "task_complete"]

    func testEveryMarkerIsAnchoredOnItsFirstUnderscore() {
        for marker in CodexAdapter.markers {
            XCTAssertEqual(
                marker.bytes.firstIndex(of: UInt8(ascii: "_")), marker.underscore,
                "\(String(decoding: marker.bytes, as: UTF8.self)) is anchored off its first underscore")
        }
    }

    func testEveryMarkerPasses() {
        for type in Self.types {
            XCTAssertTrue(
                passes(#"{"type":"event_msg","payload":{"type":"\#(type)"}}"#),
                "a line carrying \(type) was dropped")
        }
    }

    func testAMarkerAtEitherEdgeOfTheLinePasses() {
        XCTAssertTrue(passes(#""token_count""#), "a line that is only the marker was dropped")
        XCTAssertTrue(
            passes(#"{"snake_case_key":1,"type":"turn_context""#),
            "a marker ending the line was dropped")
    }

    func testALineWithUnderscoresAndNoMarkerIsDropped() {
        XCTAssertFalse(
            passes(#"{"type":"response_item","payload":{"call_id":"a_b","token_counts":"x"}}"#),
            "a line with no marker was handed to the parser")
    }

    func testAMarkerOutsideTheWindowIsDropped() {
        let line = Array(#"xx"token_count"yy"#.utf8)
        line.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            XCTAssertTrue(adapter.lineMayCount(base, from: 2, to: 15), "the whole marker was missed")
            XCTAssertFalse(
                adapter.lineMayCount(base, from: 3, to: buf.count),
                "a marker cut at the window's start passed")
            XCTAssertFalse(
                adapter.lineMayCount(base, from: 0, to: 14),
                "a marker cut at the window's end passed")
        }
    }

    private func passes(_ line: String) -> Bool {
        Array(line.utf8).withUnsafeBufferPointer {
            adapter.lineMayCount($0.baseAddress!, from: 0, to: $0.count)
        }
    }
}
