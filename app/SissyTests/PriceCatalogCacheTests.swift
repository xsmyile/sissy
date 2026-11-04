import XCTest

@testable import Sissy

/// A cache write that fails costs the next launch a fetch or the embedded seed,
/// and it used to go under `try?` with nothing to say why.
final class PriceCatalogCacheTests: XCTestCase {
    func testACacheThatCannotBeWrittenSaysSo() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-catalog-\(UUID().uuidString)")
        try Data().write(to: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let name = "catalog-\(UUID().uuidString).json"
        let catalog = PriceCatalog(fetchedAt: Date(), anthropic: [:], openai: [:])

        PriceCatalogSource.saveCache(catalog, to: base.appendingPathComponent(name))

        XCTAssertTrue(LoggedLines.contain(name))
    }
}
