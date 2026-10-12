import Foundation

@testable import Sissy

/// A power source a test sets by hand, so no test reads the machine's own
/// battery: a laptop running the suite on a low charge would otherwise see
/// every lid hold let go.
final class PowerSourceStub: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PowerSourceReading?

    init(_ reading: PowerSourceReading? = PowerSourceReading(onBattery: false, batteryPercent: 100)) {
        current = reading
    }

    /// What the next read answers.
    var reading: PowerSourceReading? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }

    var gauge: PowerSourceGauge {
        PowerSourceGauge { [self] in reading }
    }
}
