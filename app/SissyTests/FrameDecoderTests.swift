import XCTest

@testable import Sissy

final class FrameDecoderTests: XCTestCase {
    private let fullFrame = """
        {"type":"frame","ts":42,"tokens":"26K","cost":"0.09","burn":"1.5K",
         "primary":"26K","primary_label":"TOKENS",
         "providers":[{"id":"claude-code","tokens":26000,"cost":"0.0914"}],
         "prev_tokens":10000,"prev_cost":"0.0326"}
        """

    func testDecodesEveryScalarOnAFullFrame() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame)).frame
        XCTAssertEqual(frame.tokens, "26K")
        XCTAssertEqual(frame.cost, "0.09")
        XCTAssertEqual(frame.burn, "1.5K")
        XCTAssertEqual(frame.primary, "26K")
        XCTAssertEqual(frame.primaryLabel, "TOKENS")
    }

    func testDecodesProviderSlice() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame)).frame
        XCTAssertEqual(frame.providers.count, 1)
        XCTAssertEqual(frame.providers.first?.id, "claude-code")
        XCTAssertEqual(frame.providers.first?.tokens, 26000)
        XCTAssertEqual(frame.providers.first?.cost, Decimal(string: "0.0914"))
    }

    /// Vendors ship their buckets in whatever order they like; the panel
    /// renders the tightest limit first, so the decoder is what sorts.
    func testDecodesProviderWindowsShortestFirst() throws {
        let payload = """
            {"type":"frame","tokens":"26K","cost":"0.09","burn":"1.5K",
             "primary":"26K","primary_label":"TOKENS","ts":1,
             "providers":[{"id":"codex","tokens":26000,"cost":"0.0914","windows":[
               {"minutes":10080,"used_percent":8.0,"resets_at":1789549854},
               {"minutes":300,"used_percent":25.5,"resets_at":1789006037}]}]}
            """
        let frame = try XCTUnwrap(FrameDecoder.decode(payload)).frame
        let windows = try XCTUnwrap(frame.providers.first?.windows)
        XCTAssertEqual(windows.map(\.minutes), [300, 10080])
        XCTAssertEqual(windows.first?.usedPercent, 25.5)
        XCTAssertEqual(windows.first?.resetsAt, Date(timeIntervalSince1970: 1_789_006_037))
    }

    func testProviderWithoutWindowsDecodesToNone() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame)).frame
        XCTAssertEqual(frame.providers.first?.windows, [])
    }

    func testDecodesProviderPlan() throws {
        let payload = """
            {"type":"frame","tokens":"26K","cost":"0.09","burn":"1.5K",
             "primary":"26K","primary_label":"TOKENS","ts":1,
             "providers":[{"id":"codex","tokens":26000,"cost":"0.0914","plan":"plus"}]}
            """
        let frame = try XCTUnwrap(FrameDecoder.decode(payload)).frame
        XCTAssertEqual(frame.providers.first?.plan, "plus")
        XCTAssertNil(frame.providers.first?.planTier)
    }

    func testDecodesProviderPlanTier() throws {
        let payload = """
            {"type":"frame","tokens":"26K","cost":"0.09","burn":"1.5K",
             "primary":"26K","primary_label":"TOKENS","ts":1,
             "providers":[{"id":"claude-code","tokens":26000,"cost":"0.0914",
               "plan":"team","plan_tier":"max_5x"}]}
            """
        let frame = try XCTUnwrap(FrameDecoder.decode(payload)).frame
        XCTAssertEqual(frame.providers.first?.plan, "team")
        XCTAssertEqual(frame.providers.first?.planTier, "max_5x")
    }

    /// A tier with no plan beside it describes limits the row cannot
    /// attribute, so the pairing is refused rather than half-rendered.
    func testATierWithoutAPlanIsDropped() throws {
        let payload = """
            {"type":"frame","tokens":"26K","cost":"0.09","burn":"1.5K",
             "primary":"26K","primary_label":"TOKENS","ts":1,
             "providers":[{"id":"claude-code","tokens":26000,"cost":"0.0914",
               "plan_tier":"max_5x"}]}
            """
        let frame = try XCTUnwrap(FrameDecoder.decode(payload)).frame
        XCTAssertNil(frame.providers.first?.plan)
        XCTAssertNil(frame.providers.first?.planTier)
    }

    /// The daemon omits the key rather than sending null, and a daemon from
    /// before the field sends nothing at all — both have to read as "this
    /// account named no plan" and not as a decode failure that drops the row.
    func testProviderWithoutAPlanStillDecodes() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame)).frame
        XCTAssertEqual(frame.providers.count, 1)
        XCTAssertNil(frame.providers.first?.plan)
    }

    /// Cost crosses the wire as a canonical decimal string precisely so a
    /// sub-cent total survives; a `Double` hop here would drop precision.
    func testDecodesTheKeepAwakeState() throws {
        let json = """
            {"type":"frame","ts":42,"tokens":"26K","cost":"0.09","burn":"1.5K",
             "primary":"26K","primary_label":"TOKENS","providers":[],
             "keep_awake":{"mode":"on","active":true}}
            """
        let frame = try XCTUnwrap(FrameDecoder.decode(json)).frame
        XCTAssertEqual(frame.keepAwake, KeepAwakeState(mode: .on, active: true))
    }

    /// The mode and its effect are separate fields because they come apart:
    /// power management can refuse the assertion the user asked for.
    func testAModeThatIsNotHoldingDecodesAsBoth() throws {
        let json = """
            {"type":"frame","ts":42,"tokens":"26K","cost":"0.09","burn":"1.5K",
             "primary":"26K","primary_label":"TOKENS","providers":[],
             "keep_awake":{"mode":"on","active":false}}
            """
        let frame = try XCTUnwrap(FrameDecoder.decode(json)).frame
        XCTAssertEqual(frame.keepAwake.mode, .on)
        XCTAssertFalse(frame.keepAwake.active)
    }

    func testAnUnknownKeepAwakeModeDecodesToOffWithoutDroppingTheFrame() throws {
        let json = """
            {"type":"frame","ts":42,"tokens":"26K","cost":"0.09","burn":"1.5K",
             "primary":"26K","primary_label":"TOKENS","providers":[],
             "keep_awake":{"mode":"hypersleep","active":true}}
            """
        let frame = try XCTUnwrap(FrameDecoder.decode(json)).frame
        XCTAssertEqual(frame.tokens, "26K")
        XCTAssertEqual(frame.keepAwake, .off)
    }

    func testAnOmittedKeepAwakeKeyDecodesToOff() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame)).frame
        XCTAssertEqual(frame.keepAwake, .off)
    }

    func testPrevCostRoundTripsLossless() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(fullFrame)).frame
        XCTAssertEqual(frame.prevTokens, 10000)
        XCTAssertEqual(frame.prevCost, Decimal(string: "0.0326"))
    }

    func testOmittedPrevKeysDecodeToNoComparison() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(#"{"type":"frame","tokens":"1K"}"#)).frame
        XCTAssertNil(frame.prevTokens)
        XCTAssertNil(frame.prevCost)
    }

    func testHalfPresentPrevPairDecodesToNoComparison() throws {
        let json = #"{"type":"frame","tokens":"1K","prev_tokens":10}"#
        let frame = try XCTUnwrap(FrameDecoder.decode(json)).frame
        XCTAssertNil(frame.prevTokens)
        XCTAssertNil(frame.prevCost)
    }

    func testMalformedPrevCostDecodesToNoComparison() throws {
        let json = #"{"type":"frame","tokens":"1K","prev_tokens":10,"prev_cost":"abc"}"#
        let frame = try XCTUnwrap(FrameDecoder.decode(json)).frame
        XCTAssertNil(frame.prevTokens)
        XCTAssertNil(frame.prevCost)
    }

    func testMalformedProviderRowIsSkippedWithoutDroppingTheFrame() throws {
        let json = """
            {"type":"frame","tokens":"1K","providers":[{"id":"x","tokens":1,"cost":"nope"},
             {"id":"codex","tokens":2,"cost":"1.00"}]}
            """
        let frame = try XCTUnwrap(FrameDecoder.decode(json)).frame
        XCTAssertEqual(frame.providers.map(\.id), ["codex"])
    }

    func testMissingScalarsFallBackToPlaceholders() throws {
        let frame = try XCTUnwrap(FrameDecoder.decode(#"{"type":"frame","tokens":"1K"}"#)).frame
        XCTAssertEqual(frame.cost, FrameDecoder.placeholder)
        XCTAssertEqual(frame.burn, FrameDecoder.placeholder)
        XCTAssertEqual(frame.primary, "1K")
        XCTAssertEqual(frame.primaryLabel, "TOKENS")
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
        let decoded = try XCTUnwrap(FrameDecoder.decode(fullFrame))
        XCTAssertEqual(decoded.builtAt, Date(timeIntervalSince1970: 42))
    }

    func testBuiltAtIsAbsentWithoutATimestamp() throws {
        let decoded = try XCTUnwrap(FrameDecoder.decode(#"{"type":"frame","tokens":"1K"}"#))
        XCTAssertNil(decoded.builtAt)
    }
}
