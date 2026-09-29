import XCTest

@testable import Sissy

final class BoundedProcessTests: XCTestCase {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    func testInputReachesTheChildAndItsOutputComesBack() throws {
        let outcome = try BoundedProcess.run(
            Self.shell, ["-c", "cat; echo oops >&2"], input: Data("hello".utf8),
            captureErrors: true, timeout: 5)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.reason, .exit)
        XCTAssertEqual(String(bytes: outcome.output, encoding: .utf8), "hello")
        XCTAssertEqual(String(bytes: outcome.errors, encoding: .utf8), "oops\n")
    }

    /// A child that ignores `SIGTERM` is killed once the grace has passed,
    /// rather than holding the caller for as long as it likes.
    func testAChildThatIgnoresTerminationIsKilled() throws {
        let started = Date()
        let outcome = try BoundedProcess.run(
            Self.shell, ["-c", "trap '' TERM; exec sleep 30"], timeout: 0.2)
        XCTAssertEqual(outcome.reason, .uncaughtSignal)
        XCTAssertEqual(outcome.status, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAToolThatCannotStartThrows() {
        XCTAssertThrowsError(
            try BoundedProcess.run(URL(fileURLWithPath: "/nonexistent/tool"), [], timeout: 1))
    }
}
