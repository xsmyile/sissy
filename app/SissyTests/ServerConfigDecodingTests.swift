import XCTest

@testable import Sissy

/// `server.json` is read by one hand-written decoder, key by key. What these
/// hold is that it reads back every field it writes, and that a hand-edited
/// value reads the way it did while the file went through `JSONSerialization`.
final class ServerConfigDecodingTests: XCTestCase {
    /// A config with every field, and every field inside a nested one, away
    /// from its default.
    private static let everyFieldSet: ServerConfig = {
        var config = ServerConfig.defaults
        config.claudeDataDir = "/tmp/claude"
        config.codexDataDir = "/tmp/codex"
        config.pollIntervalSeconds = 15
        config.pricingOverride = [
            "claude-opus-5": ModelPricing(
                inputPerMTok: 1, outputPerMTok: 2, cacheReadPerMTok: 3, cacheCreationPerMTok: 4,
                cacheCreation1hPerMTok: 5)
        ]
        config.remotePricing = false
        config.statusChecks = false
        config.providers = ProviderToggles(claudeCode: false, codex: true)
        config.historyRetentionDays = 30
        config.keepAwake = .on
        config.keepAwakeCeiling = .never
        config.keepScreenAwake = false
        config.agentHooks = true
        config.agentHooksRemovalPending = true
        config.forgeCounters = ForgeCounters(
            merged: false, issues: true, comments: false, latest: true, actions: false)
        config.macHealth = false
        config.disk = false
        config.network = false
        return config
    }()

    /// **A field the decoder skips must fail here**, including an optional
    /// one, which a hand-written `init(from:)` leaves nil without a word from
    /// the compiler. The fixture is checked first: every leaf has to differ
    /// from the defaults and none may be nil, so a field added to the type
    /// fails this test until the fixture sets it, and then fails the round
    /// trip until the decoder reads it.
    func testEveryFieldIsReadBackAsWritten() throws {
        let fixture = Self.leaves(of: Self.everyFieldSet)
        let defaults = Self.leaves(of: ServerConfig.defaults)
        for (path, value) in fixture {
            XCTAssertNotEqual(value, "nil", "\(path) is nil in the fixture")
            XCTAssertNotEqual(value, defaults[path], "\(path) is at its default in the fixture")
        }

        let written = try Self.encode(Self.everyFieldSet)
        let read = try JSONDecoder().decode(ServerConfig.self, from: written)

        XCTAssertEqual(try Self.encode(read), written)
    }

    /// Built from `ForgeCounter.allCases`, so a counter added to the enum is
    /// in the file this reads without the test changing: a switched-off
    /// counter that came back on would be fetched again.
    func testEveryCounterSwitchedOffStaysOff() throws {
        let counters = Dictionary(uniqueKeysWithValues: ForgeCounter.allCases.map { ($0.rawValue, false) })
        let data = try JSONSerialization.data(withJSONObject: ["forgeCounters": counters])

        let config = try JSONDecoder().decode(ServerConfig.self, from: data)

        XCTAssertEqual(config.forgeCounters?.enabled, [])
    }

    func testAnUnreadableCounterLeavesItsSiblingsAsSet() throws {
        let config = try decode(#"{"forgeCounters": {"merged": "no", "issues": false}}"#)

        XCTAssertNil(config.forgeCounters?.merged)
        XCTAssertEqual(config.forgeCounters?.issues, false)
    }

    /// A file written before the ceiling could be chosen holds for the eight
    /// hours it always did, and one naming a ceiling the list does not offer
    /// lands there too without taking the mode beside it along.
    func testACeilingAbsentOrUnknownReadsAsEightHours() throws {
        XCTAssertEqual(try decode(#"{"keepAwake": "on"}"#).keepAwakeCeiling, .eightHours)

        let config = try decode(#"{"keepAwake": "on", "keepAwakeCeiling": "3h"}"#)

        XCTAssertEqual(config.keepAwakeCeiling, .eightHours)
        XCTAssertEqual(config.keepAwake, .on)
    }

    /// A file written before the Actions switch existed keeps every switch it
    /// set and reads the new one as on.
    func testAFileWithoutTheActionsSwitchKeepsTheRest() throws {
        let config = try decode(#"{"forgeCounters": {"merged": false, "latest": false}}"#)

        XCTAssertEqual(config.forgeCounters?.merged, false)
        XCTAssertEqual(config.forgeCounters?.latest, false)
        XCTAssertEqual(config.forgeCounters?.actions, true)
    }

    /// `0` switched a network reading off for as long as the file went
    /// through `JSONSerialization`, and must go on doing so.
    func testZeroAndOneReadAsSwitches() throws {
        let config = try decode(
            #"""
            {"remotePricing": 0, "statusChecks": 0, "agentHooks": 1,
             "providers": {"codex": 0}, "forgeCounters": {"merged": 0, "issues": 1}}
            """#)

        XCTAssertEqual(config.remotePricing, false)
        XCTAssertFalse(config.statusChecks)
        XCTAssertTrue(config.agentHooks)
        XCTAssertEqual(config.providers.codex, false)
        XCTAssertEqual(config.forgeCounters?.merged, false)
        XCTAssertEqual(config.forgeCounters?.issues, true)
    }

    func testAnyOtherNumberIsNotASwitch() throws {
        let config = try decode(#"{"statusChecks": 2, "remotePricing": 0.5}"#)

        XCTAssertEqual(config.statusChecks, ServerConfig.defaults.statusChecks)
        XCTAssertNil(config.remotePricing)
    }

    /// The other half of the same bridge: `true` read as `1` where a number
    /// belongs.
    func testTrueAndFalseReadAsNumbers() throws {
        let config = try decode(#"{"historyRetentionDays": true, "pollIntervalSeconds": false}"#)

        XCTAssertEqual(config.historyRetentionDays, 1)
        XCTAssertEqual(config.pollIntervalSeconds, 0)
    }

    private func decode(_ json: String) throws -> ServerConfig {
        try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
    }

    private static func encode(_ config: ServerConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(config)
    }

    /// Every stored value down to the scalars, by its path, with a nil
    /// optional as `nil`. A dictionary is one leaf: its entries are data
    /// rather than fields.
    private static func leaves(of value: Any, at path: String = "") -> [String: String] {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let wrapped = mirror.children.first?.value else { return [path: "nil"] }
            return leaves(of: wrapped, at: path)
        case .struct, .class:
            var found: [String: String] = [:]
            for child in mirror.children {
                let name = child.label.map { path.isEmpty ? $0 : "\(path).\($0)" } ?? path
                found.merge(leaves(of: child.value, at: name)) { first, _ in first }
            }
            return found.isEmpty ? [path: String(describing: value)] : found
        default:
            return [path: String(describing: value)]
        }
    }
}
