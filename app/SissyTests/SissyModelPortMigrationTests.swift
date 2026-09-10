import ServiceManagement
import XCTest

@testable import Sissy

/// The port migration is the one launch path that writes to disk and can
/// restart the LaunchAgent, and `xcodebuild test` launches the real app host —
/// so both halves are pinned away from the machine's own install: preferences
/// go to a temporary directory, and `SMAppService` is aimed at a plist the
/// bundle does not carry.
@MainActor
final class SissyModelPortMigrationTests: XCTestCase {
    private var legacyDefaultPort: Int { SissyPaths.isDev ? 8788 : 8787 }

    private func makeModel(supportDirectory: URL) -> SissyModel {
        SissyModel(
            serverService: ServerServiceController(
                service: .agent(plistName: "com.radonforge.sissy.tests.absent.plist")
            ),
            supportDirectory: supportDirectory
        )
    }

    private func makeSupportDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-migration-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func serverConfigURL(in directory: URL) -> URL {
        directory.appendingPathComponent(Preferences.serverConfigFileName)
    }

    private func serverConfigPort(in directory: URL) throws -> Int? {
        let data = try Data(contentsOf: serverConfigURL(in: directory))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["port"] as? Int
    }

    /// Both files have to move: `preferences.json` is what the app reads back
    /// on the next launch, `server.json` is the only thing the daemon reads.
    func testALegacyPortMovesAndIsPersistedToBothFiles() throws {
        let dir = try makeSupportDir()
        Preferences(serverPort: legacyDefaultPort).save(to: dir)

        let model = makeModel(supportDirectory: dir)
        XCTAssertEqual(model.preferences.serverPort, legacyDefaultPort)

        model.migrateServerPortIfNeeded()

        XCTAssertEqual(model.preferences.serverPort, SissyPaths.defaultServerPort)
        XCTAssertEqual(Preferences.load(from: dir).serverPort, SissyPaths.defaultServerPort)
        XCTAssertEqual(try serverConfigPort(in: dir), SissyPaths.defaultServerPort)
    }

    /// An install already on the current port must not be written at all — a
    /// rewrite here would restart the daemon on every launch.
    func testAnInstallOnTheCurrentPortIsNotRewritten() throws {
        let dir = try makeSupportDir()
        Preferences(serverPort: SissyPaths.defaultServerPort).save(to: dir)

        makeModel(supportDirectory: dir).migrateServerPortIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: serverConfigURL(in: dir).path))
    }

    /// A hand-picked port outranks the new default, so nothing is written for
    /// it either.
    func testAHandPickedPortIsLeftOnDisk() throws {
        let dir = try makeSupportDir()
        Preferences(serverPort: 9999).save(to: dir)

        let model = makeModel(supportDirectory: dir)
        model.migrateServerPortIfNeeded()

        XCTAssertEqual(model.preferences.serverPort, 9999)
        XCTAssertFalse(FileManager.default.fileExists(atPath: serverConfigURL(in: dir).path))
    }
}
