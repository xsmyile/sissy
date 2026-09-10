import XCTest

@testable import Sissy

final class CcusageProbeTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        home = nil
        try super.tearDownWithError()
    }

    // MARK: Classification

    func testAnExecutableInsideNodeModulesIsTheNpmBuild() {
        let path = "/opt/node/lib/node_modules/ccusage/src/cli.js"

        XCTAssertEqual(CcusageProbe.kind(resolvedPath: path), .npm)
    }

    func testAnExecutableInsideTheCellarIsTheHomebrewBuild() {
        let path = "/opt/homebrew/Cellar/ccusage/20.1.0/bin/ccusage"

        XCTAssertEqual(CcusageProbe.kind(resolvedPath: path), .homebrew)
    }

    func testAnExecutableInNeitherLayoutIsAnUnknownBuild() {
        let path = "/Users/someone/.cargo/bin/ccusage"

        XCTAssertEqual(CcusageProbe.kind(resolvedPath: path), .other)
    }

    func testTheHomebrewVersionIsTheCellarPathComponent() {
        let path = "/opt/homebrew/Cellar/ccusage/20.1.0/bin/ccusage"

        XCTAssertEqual(CcusageProbe.homebrewVersion(resolvedPath: path), "20.1.0")
    }

    func testATruncatedCellarPathCarriesNoVersion() {
        XCTAssertNil(CcusageProbe.homebrewVersion(resolvedPath: "/opt/homebrew/Cellar/ccusage"))
    }

    func testTheNpmPackageRootStopsAtThePackageDirectory() {
        let path = "/opt/node/lib/node_modules/ccusage/src/cli.js"

        XCTAssertEqual(
            CcusageProbe.npmPackageRoot(resolvedPath: path),
            "/opt/node/lib/node_modules/ccusage"
        )
    }

    func testAPackageWhoseNameOnlyPrefixMatchesIsNotTheRoot() {
        let path = "/opt/node/lib/node_modules/ccusage-fork/src/cli.js"

        XCTAssertNil(CcusageProbe.npmPackageRoot(resolvedPath: path))
    }

    // MARK: Discovery

    func testAVersionManagerPrefixIsFoundAndItsManifestVersionRead() throws {
        try installNpm(nodeVersion: "v24.14.0", packageVersion: "20.0.20")

        let installs = CcusageProbe.installs(home: home, systemBinDirs: [])

        XCTAssertEqual(installs.count, 1)
        XCTAssertEqual(installs.first?.kind, .npm)
        XCTAssertEqual(installs.first?.version, "20.0.20")
        XCTAssertEqual(
            installs.first?.path,
            "~/.local/share/fnm/node-versions/v24.14.0/installation/bin/ccusage"
        )
    }

    func testASecondSymlinkOntoTheSameFileIsReportedOnce() throws {
        try installNpm(nodeVersion: "v24.14.0", packageVersion: "20.0.20")
        let shim = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: shim.appendingPathComponent("ccusage"),
            withDestinationURL: npmExecutable(nodeVersion: "v24.14.0")
        )

        let installs = CcusageProbe.installs(home: home, systemBinDirs: [])

        XCTAssertEqual(installs.count, 1)
    }

    func testTheHomebrewBuildIsFoundThroughItsCellarSymlink() throws {
        let prefix = home.appendingPathComponent("brew")
        let cellarBin = prefix.appendingPathComponent("Cellar/ccusage/20.1.0/bin")
        let bin = prefix.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: cellarBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let binary = cellarBin.appendingPathComponent("ccusage")
        try Data().write(to: binary)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("ccusage"), withDestinationURL: binary)

        let installs = CcusageProbe.installs(home: home, systemBinDirs: [bin.path])

        XCTAssertEqual(installs.count, 1)
        XCTAssertEqual(installs.first?.kind, .homebrew)
        XCTAssertEqual(installs.first?.version, "20.1.0")
    }

    func testAMachineWithNoCcusageReportsNone() {
        XCTAssertTrue(CcusageProbe.installs(home: home, systemBinDirs: []).isEmpty)
    }

    func testAManifestWithoutAVersionLeavesTheInstallUnversioned() throws {
        try installNpm(nodeVersion: "v24.14.0", packageVersion: nil)

        let installs = CcusageProbe.installs(home: home, systemBinDirs: [])

        XCTAssertEqual(installs.first?.kind, .npm)
        XCTAssertNil(installs.first?.version)
    }

    // MARK: Fixtures

    /// Reproduces what `npm i -g ccusage` leaves behind under a Node version
    /// manager: the package in the prefix's `lib/node_modules`, and a `bin`
    /// symlink pointing into it.
    private func installNpm(nodeVersion: String, packageVersion: String?) throws {
        let prefix =
            home
            .appendingPathComponent(".local/share/fnm/node-versions/\(nodeVersion)/installation")
        let packageRoot = prefix.appendingPathComponent("lib/node_modules/ccusage")
        let source = packageRoot.appendingPathComponent("src")
        let bin = prefix.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("cli.js"))
        let manifest =
            packageVersion.map { "{\"name\":\"ccusage\",\"version\":\"\($0)\"}" }
            ?? "{\"name\":\"ccusage\"}"
        try Data(manifest.utf8).write(to: packageRoot.appendingPathComponent("package.json"))
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("ccusage"),
            withDestinationURL: source.appendingPathComponent("cli.js")
        )
    }

    private func npmExecutable(nodeVersion: String) -> URL {
        home
            .appendingPathComponent(".local/share/fnm/node-versions/\(nodeVersion)/installation")
            .appendingPathComponent("lib/node_modules/ccusage/src/cli.js")
    }
}
