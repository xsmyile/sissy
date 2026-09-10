import XCTest

@testable import Sissy

final class FrameDecoderTests: XCTestCase {
    private let fullFrame = """
        {"type":"frame","ts":42,"tokens":"26K","cost":"0.09","burn":"1.5K","state":"trend",
         "primary":"26K","primary_label":"TOKENS","device_present":true,
         "providers":[{"id":"claude-code","tokens":26000,"cost":"0.0914"}],
         "prev_tokens":10000,"prev_cost":"0.0326"}
        """

    func testDecodesEveryScalarOnAFullFrame() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame))
        XCTAssertEqual(frame.tokens, "26K")
        XCTAssertEqual(frame.cost, "0.09")
        XCTAssertEqual(frame.burn, "1.5K")
        XCTAssertEqual(frame.state, "trend")
        XCTAssertEqual(frame.ts, 42)
        XCTAssertEqual(frame.primary, "26K")
        XCTAssertEqual(frame.primaryLabel, "TOKENS")
        XCTAssertTrue(frame.devicePresent)
    }

    func testDecodesProviderSlice() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame))
        XCTAssertEqual(frame.providers.count, 1)
        XCTAssertEqual(frame.providers.first?.id, "claude-code")
        XCTAssertEqual(frame.providers.first?.tokens, 26000)
        XCTAssertEqual(frame.providers.first?.cost, Decimal(string: "0.0914"))
    }

    /// Vendors ship their buckets in whatever order they like; the panel
    /// renders the tightest limit first, so the decoder is what sorts.
    func testDecodesProviderWindowsShortestFirst() throws {
        let payload = """
            {"type":"frame","tokens":"26K","cost":"0.09","burn":"1.5K","state":"code",
             "primary":"26K","primary_label":"TOKENS","device_present":true,"ts":1,
             "providers":[{"id":"codex","tokens":26000,"cost":"0.0914","windows":[
               {"minutes":10080,"used_percent":8.0,"resets_at":1789549854},
               {"minutes":300,"used_percent":25.5,"resets_at":1789006037}]}]}
            """
        let frame = try XCTUnwrap(FrameDecoder.decode(payload))
        let windows = try XCTUnwrap(frame.providers.first?.windows)
        XCTAssertEqual(windows.map(\.minutes), [300, 10080])
        XCTAssertEqual(windows.first?.usedPercent, 25.5)
        XCTAssertEqual(windows.first?.resetsAt, Date(timeIntervalSince1970: 1_789_006_037))
    }

    func testProviderWithoutWindowsDecodesToNone() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame))
        XCTAssertEqual(frame.providers.first?.windows, [])
    }

    /// Cost crosses the wire as a canonical decimal string precisely so a
    /// sub-cent total survives; a `Double` hop here would drop precision.
    func testPrevCostRoundTripsLossless() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame))
        XCTAssertEqual(frame.prev?.tokens, 10000)
        XCTAssertEqual(frame.prev?.cost, Decimal(string: "0.0326"))
    }

    func testOmittedPrevKeysDecodeToNoComparison() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(#"{"type":"frame","tokens":"1K"}"#))
        XCTAssertNil(frame.prev)
    }

    func testHalfPresentPrevPairDecodesToNoComparison() throws {
        let json = #"{"type":"frame","tokens":"1K","prev_tokens":10}"#
        let frame = try XCTUnwrap(FrameDecoder.decode(json))
        XCTAssertNil(frame.prev)
    }

    func testMalformedPrevCostDecodesToNoComparison() throws {
        let json = #"{"type":"frame","tokens":"1K","prev_tokens":10,"prev_cost":"abc"}"#
        let frame = try XCTUnwrap(FrameDecoder.decode(json))
        XCTAssertNil(frame.prev)
    }

    func testMalformedProviderRowIsSkippedWithoutDroppingTheFrame() throws {
        let json = """
            {"type":"frame","tokens":"1K","providers":[{"id":"x","tokens":1,"cost":"nope"},
             {"id":"codex","tokens":2,"cost":"1.00"}]}
            """
        let frame = try XCTUnwrap(FrameDecoder.decode(json))
        XCTAssertEqual(frame.providers.map(\.id), ["codex"])
    }

    func testMissingScalarsFallBackToPlaceholders() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(#"{"type":"frame","tokens":"1K"}"#))
        XCTAssertEqual(frame.cost, FrameDecoder.placeholder)
        XCTAssertEqual(frame.burn, FrameDecoder.placeholder)
        XCTAssertEqual(frame.state, "think")
        XCTAssertEqual(frame.primary, "1K")
        XCTAssertEqual(frame.primaryLabel, "TOKENS")
        XCTAssertFalse(frame.devicePresent)
    }

    func testNonFrameMessageIsRejected() {
        XCTAssertNil(FrameDecoder.decode(#"{"type":"hello","client":"mac-app"}"#))
    }

    func testMalformedJSONIsRejected() {
        XCTAssertNil(FrameDecoder.decode("not json"))
    }

    /// The panel's "updated Ns ago" measures the daemon's emit, not the
    /// socket: the Hub replays one cached payload to every client that
    /// connects, so a receive-time clock would call a stale frame fresh.
    func testBuiltAtComesFromTheDaemonTimestamp() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame))
        XCTAssertEqual(frame.builtAt, Date(timeIntervalSince1970: 42))
    }

    func testBuiltAtIsAbsentWithoutATimestamp() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(#"{"type":"frame","tokens":"1K"}"#))
        XCTAssertNil(frame.builtAt)
    }
}
