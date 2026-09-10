import XCTest

@testable import Sissy

final class DiagnosticsReportTests: XCTestCase {
    private func snapshot(
        providers: [DisplayFrame.ProviderSlice] = [],
        serverState: String = "Running",
        linkIsConnected: Bool = true,
        claudeLimits: Bool = true,
        systemVersion: String = "Version 26.0 (Build 25A354)"
    ) -> DiagnosticsReport.Snapshot {
        DiagnosticsReport.Snapshot(
            version: "0.1.9",
            build: "42",
            systemVersion: systemVersion,
            endpoint: "127.0.0.1:5155",
            serverState: serverState,
            linkIsConnected: linkIsConnected,
            claudeLimits: claudeLimits,
            providers: providers
        )
    }

    func testReportStatesVersionOSServerAndLink() {
        let lines = DiagnosticsReport.text(snapshot()).split(separator: "\n").map(String.init)

        XCTAssertEqual(lines[0], "Sissy 0.1.9 (42)")
        XCTAssertEqual(lines[1], "macOS 26.0 (Build 25A354)")
        XCTAssertEqual(lines[2], "Server: Running at 127.0.0.1:5155")
        XCTAssertEqual(lines[3], "Link: connected")
        XCTAssertEqual(lines[4], "Claude limits: on")
    }

    func testUnprefixedSystemVersionIsLeftAlone() {
        let text = DiagnosticsReport.text(snapshot(systemVersion: "26.0"))

        XCTAssertTrue(text.contains("macOS 26.0"))
    }

    func testStoppedServerAndDroppedLinkAreStated() {
        let text = DiagnosticsReport.text(
            snapshot(serverState: "Stopped", linkIsConnected: false, claudeLimits: false)
        )

        XCTAssertTrue(text.contains("Server: Stopped at 127.0.0.1:5155"))
        XCTAssertTrue(text.contains("Link: disconnected"))
        XCTAssertTrue(text.contains("Claude limits: off"))
    }

    func testProvidersReportExactTokensAndTheirWindows() {
        let text = DiagnosticsReport.text(
            snapshot(providers: [
                DisplayFrame.ProviderSlice(
                    id: "claude-code",
                    tokens: 1_234_567,
                    cost: 12.34,
                    windows: [
                        DisplayFrame.UsageWindow(minutes: 300, usedPercent: 41.6, resetsAt: .now),
                        DisplayFrame.UsageWindow(minutes: 10080, usedPercent: 7.2, resetsAt: .now),
                    ]
                ),
                DisplayFrame.ProviderSlice(id: "codex", tokens: 89_012, cost: 1.5),
            ])
        )

        XCTAssertTrue(
            text.contains(
                "Providers: claude-code 1234567 tokens, 300m 42% 10080m 7%; codex 89012 tokens, no windows"),
            text
        )
    }

    func testNoFrameYetReportsNoProviders() {
        XCTAssertTrue(DiagnosticsReport.text(snapshot()).contains("Providers: none reported"))
    }

    func testReportCarriesNoCostFigures() {
        let text = DiagnosticsReport.text(
            snapshot(providers: [
                DisplayFrame.ProviderSlice(id: "claude-code", tokens: 10, cost: 99.99)
            ])
        )

        XCTAssertFalse(text.contains("99.99"))
    }
}
