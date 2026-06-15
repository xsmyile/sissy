import XCTest

@testable import Sissy

final class ProvisionRequestTests: XCTestCase {
    func testRequestEncodesAsExpectedJSON() throws {
        let req = ProvisionRequest.make(
            ssid: "MyWiFi",
            password: "secret",
            host: "192.168.1.158",
            port: 8787,
            token: "abc123",
            otaPassword: "sissy"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(decoded["v"] as? Int, 1)
        XCTAssertEqual(decoded["type"] as? String, "config")
        XCTAssertEqual(decoded["ssid"] as? String, "MyWiFi")
        XCTAssertEqual(decoded["pwd"] as? String, "secret")
        let server = try XCTUnwrap(decoded["server"] as? [String: Any])
        XCTAssertEqual(server["host"] as? String, "192.168.1.158")
        XCTAssertEqual(server["port"] as? Int, 8787)
        XCTAssertEqual(server["path"] as? String, "/ws")
        XCTAssertEqual(server["token"] as? String, "abc123")
        let ota = try XCTUnwrap(decoded["ota"] as? [String: Any])
        XCTAssertEqual(ota["password"] as? String, "sissy")
    }

    func testEncodedLineHasCFGPrefixAndTerminator() throws {
        let req = ProvisionRequest.make(
            ssid: "S", password: "P", host: "H", token: "T", otaPassword: "otap"
        )
        let bytes = try req.encodedLine()
        let str = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(str.hasPrefix("CFG:"))
        XCTAssertTrue(str.hasSuffix("\n"))
    }
}

final class SerialPortDiscoveryTests: XCTestCase {
    func testSerialPortDisplayNameStripsCuPrefix() {
        XCTAssertEqual(SerialPort(path: "/dev/cu.usbserial-10").displayName, "usbserial-10")
        XCTAssertEqual(SerialPort(path: "/dev/cu.SLAB_USBtoUART").displayName, "SLAB_USBtoUART")
    }

    func testListDoesNotCrash() {
        // The actual list depends on what's plugged in; assert only that the
        // call returns and doesn't crash.
        _ = SerialPortDiscovery.list()
    }
}

final class PairingHostValidationTests: XCTestCase {
    func testAcceptsRoutableLANAddress() {
        XCTAssertTrue(PairingViewModel.isValidProvisioningHost("192.168.1.158"))
        XCTAssertTrue(PairingViewModel.isValidProvisioningHost("10.0.0.5"))
        XCTAssertTrue(PairingViewModel.isValidProvisioningHost("sissy.local"))
        XCTAssertTrue(PairingViewModel.isValidProvisioningHost("  192.168.1.158  "))
    }

    func testRejectsEmpty() {
        XCTAssertFalse(PairingViewModel.isValidProvisioningHost(""))
        XCTAssertFalse(PairingViewModel.isValidProvisioningHost("   "))
        XCTAssertNotNil(PairingViewModel.provisioningHostError(""))
    }

    func testRejectsLoopback() {
        for host in ["127.0.0.1", "127.1.2.3", "localhost", "Localhost", "::1", "0.0.0.0", "::"] {
            XCTAssertFalse(
                PairingViewModel.isValidProvisioningHost(host),
                "expected \(host) to be rejected")
        }
    }
}
