import XCTest

@testable import Sissy

/// What the launch purge removes from a build's HTTP storage, and what it must
/// leave alone: another bundle's files, and anything a symlink inside those
/// directories points at.
///
/// Every case runs on a temporary tree standing in for `~/Library`, so the
/// suite never reaches the developer's own caches.
final class HTTPStoragePurgeTests: XCTestCase {
    private static let release = "com.radonforge.sissy"
    private static let dev = "com.radonforge.sissy.dev"
    private static let stranger = "com.radonforge.sissyhelper"

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("http-purge-\(UUID().uuidString)")
    private var library: URL { root.appendingPathComponent("Library") }
    private var outside: URL { root.appendingPathComponent("outside") }

    override func setUpWithError() throws {
        for directory in [roots.caches, roots.httpStorages, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var roots: HTTPStoragePurge.Roots {
        HTTPStoragePurge.Roots(
            caches: library.appendingPathComponent("Caches"),
            httpStorages: library.appendingPathComponent("HTTPStorages"))
    }

    func testTheCacheDatabaseAndItsBodiesGoForBothBuilds() throws {
        var planted: [URL] = []
        for id in [Self.release, Self.dev] {
            let cache = roots.caches.appendingPathComponent(id)
            try FileManager.default.createDirectory(
                at: cache.appendingPathComponent("fsCachedData"), withIntermediateDirectories: true)
            for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData/BODY"] {
                planted.append(try write(cache.appendingPathComponent(name)))
            }
        }
        HTTPStoragePurge.run(in: roots)
        for url in planted {
            XCTAssertFalse(exists(url), "\(url.lastPathComponent) survived the purge")
        }
    }

    func testTheRestOfABuildsCacheDirectoryStays() throws {
        let kept = try write(roots.caches.appendingPathComponent(Self.release).appendingPathComponent("kept"))
        HTTPStoragePurge.run(in: roots)
        XCTAssertTrue(exists(kept))
    }

    func testTheCookieJarAndHTTPStorageGoForBothBuilds() throws {
        let storage = roots.httpStorages.appendingPathComponent(Self.release)
        let planted = [
            try write(roots.httpStorages.appendingPathComponent("\(Self.release).binarycookies")),
            try write(roots.httpStorages.appendingPathComponent("\(Self.dev).binarycookies")),
            try write(storage.appendingPathComponent("httpstorages.sqlite")),
        ]
        HTTPStoragePurge.run(in: roots)
        for url in planted {
            XCTAssertFalse(exists(url), "\(url.lastPathComponent) survived the purge")
        }
        XCTAssertFalse(exists(storage))
    }

    func testAnotherBundleSharingThePrefixIsLeftAlone() throws {
        let jar = try write(roots.httpStorages.appendingPathComponent("\(Self.stranger).binarycookies"))
        let cache = try write(
            roots.caches.appendingPathComponent(Self.stranger).appendingPathComponent("Cache.db"))
        HTTPStoragePurge.run(in: roots)
        XCTAssertTrue(exists(jar))
        XCTAssertTrue(exists(cache))
    }

    func testACacheDirectoryThatIsASymlinkIsNotFollowed() throws {
        let target = try write(outside.appendingPathComponent("Cache.db"))
        try FileManager.default.createSymbolicLink(
            at: roots.caches.appendingPathComponent(Self.release), withDestinationURL: outside)
        HTTPStoragePurge.run(in: roots)
        XCTAssertTrue(exists(target), "the purge followed the build's cache directory out of Caches")
    }

    func testASymlinkedBodiesDirectoryLosesOnlyTheLink() throws {
        let target = try write(outside.appendingPathComponent("BODY"))
        let cache = roots.caches.appendingPathComponent(Self.release)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: cache.appendingPathComponent("fsCachedData"), withDestinationURL: outside)
        HTTPStoragePurge.run(in: roots)
        XCTAssertTrue(exists(target), "the purge deleted what fsCachedData pointed at")
        XCTAssertFalse(exists(cache.appendingPathComponent("fsCachedData")))
    }

    func testASymlinkInsideTheStorageLosesOnlyTheLink() throws {
        let target = try write(outside.appendingPathComponent("httpstorages.sqlite"))
        let storage = roots.httpStorages.appendingPathComponent(Self.release)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: storage.appendingPathComponent("linked"), withDestinationURL: outside)
        HTTPStoragePurge.run(in: roots)
        XCTAssertTrue(exists(target), "the purge followed a link inside HTTPStorages")
    }

    func testAMissingTreeIsNotAnError() throws {
        try FileManager.default.removeItem(at: library)
        XCTAssertEqual(HTTPStoragePurge.run(in: roots), [])
    }

    private func write(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
