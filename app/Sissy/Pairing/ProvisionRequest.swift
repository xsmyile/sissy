import Foundation

/// Wire-format payload the desktop app sends down USB serial as
/// `CFG:<json>\n`. The firmware parses this in `SerialProvisioning.cpp` and
/// rejects anything where `v != 1` — bump only when the schema breaks
/// backward compatibility, never for additive changes.
struct ProvisionRequest: Codable, Equatable {
    let v: Int
    let type: String
    let ssid: String
    let pwd: String
    let server: Server
    let ota: Ota

    struct Server: Codable, Equatable {
        let host: String
        let port: Int
        let path: String
        let token: String
    }

    struct Ota: Codable, Equatable {
        let password: String
    }

    static func make(
        ssid: String,
        password: String,
        host: String,
        port: Int = 8787,
        path: String = "/ws",
        token: String,
        otaPassword: String
    ) -> Self {
        Self(
            v: 1,
            type: "config",
            ssid: ssid,
            pwd: password,
            server: .init(host: host, port: port, path: path, token: token),
            ota: .init(password: otaPassword)
        )
    }

    func encodedLine() throws -> Data {
        let json = try JSONEncoder().encode(self)
        var out = Data("CFG:".utf8)
        out.append(json)
        out.append(0x0A)  // newline
        return out
    }
}
