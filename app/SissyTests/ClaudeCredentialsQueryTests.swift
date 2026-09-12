import LocalAuthentication
import XCTest

@testable import Sissy

/// The query is the whole feature: a read that carries these keys cannot put a
/// dialog on screen, and a read that has lost them silently can. Both halves
/// are asserted because either one alone leaves the door open — the context
/// covers the modern path, and the legacy keychain Claude Code writes into can
/// still raise Allow/Deny through it.
final class ClaudeCredentialsQueryTests: XCTestCase {
    func testASilentReadForbidsInteractionThroughTheAuthenticationContext() throws {
        let query = ClaudeCredentialsStore.makeQuery(allowingInteraction: false)

        let context = try XCTUnwrap(
            query[kSecUseAuthenticationContext as String] as? LAContext,
            "the silent read carries no authentication context"
        )
        XCTAssertTrue(context.interactionNotAllowed)
    }

    /// Resolved by name at runtime, so this is also the test that the symbol
    /// is still there: a rename or a removal in a future SDK would leave the
    /// query quietly interactive, which is the failure nobody would notice
    /// until a dialog appeared on someone's Mac at login.
    func testASilentReadAlsoFailsTheLegacyKeychainUI() throws {
        let query = ClaudeCredentialsStore.makeQuery(allowingInteraction: false)

        let key = try XCTUnwrap(
            resolve(ClaudeCredentialsStore.authenticationUIName),
            "kSecUseAuthenticationUI no longer resolves; the legacy keychain can still ask"
        )
        let fail = try XCTUnwrap(resolve(ClaudeCredentialsStore.authenticationUIFailName))
        XCTAssertEqual(query[key] as? String, fail)
    }

    /// The read a user action makes is the ordinary one. It has to be able to
    /// ask — that is the only moment Sissy is allowed to.
    func testAUserActionReadCarriesNeitherSuppressor() throws {
        let query = ClaudeCredentialsStore.makeQuery(allowingInteraction: true)

        XCTAssertNil(query[kSecUseAuthenticationContext as String])
        let key = try XCTUnwrap(resolve(ClaudeCredentialsStore.authenticationUIName))
        XCTAssertNil(query[key])
    }

    func testBothReadsAskForTheServiceClaudeCodeWritesUnder() {
        for interactive in [true, false] {
            let query = ClaudeCredentialsStore.makeQuery(allowingInteraction: interactive)
            XCTAssertEqual(
                query[kSecAttrService as String] as? String,
                ClaudeCredentialsStore.keychainService
            )
        }
    }

    private func resolve(_ name: String) -> String? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return symbol.assumingMemoryBound(to: CFString?.self).pointee as String?
    }
}
