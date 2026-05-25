import Foundation

enum Auth {
    /// Bearer-token check. Empty `expected` opens the endpoint (dev / first-run
    /// mode) so a freshly bundled daemon stays reachable before the user has
    /// generated a token. Match is done in constant time over the expected
    /// length — see `constantTimeEquals`.
    static func authorized(headerValue: String?, expected: String) -> Bool {
        if expected.isEmpty { return true }
        guard let value = headerValue, value.hasPrefix("Bearer ") else { return false }
        let token = String(value.dropFirst("Bearer ".count))
        return constantTimeEquals(token, expected)
    }

    /// Compares `a` against `b` in time proportional to `b.count` (the expected
    /// token). Length mismatch is folded into the diff bit instead of an early
    /// return so the loop walks the full expected length regardless of input.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        let n = bb.count
        var diff: UInt8 = ab.count == n ? 0 : 1
        for i in 0..<n {
            let av = i < ab.count ? ab[i] : 0
            diff |= av ^ bb[i]
        }
        return diff == 0
    }
}
