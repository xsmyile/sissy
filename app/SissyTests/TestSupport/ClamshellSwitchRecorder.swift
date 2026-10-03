import Foundation

@testable import Sissy

/// A clamshell switch that records what it was asked and never reaches the
/// kernel. The real one is machine-wide state a crashed test run would leave
/// set, so no test holds a lid through it.
final class ClamshellSwitchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    private var accepting = true

    /// Every call so far, `true` for a set and `false` for a clear.
    var calls: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Whether the kernel would be holding the switch after the calls so far.
    var isSet: Bool { calls.last ?? false }

    /// Makes every later call fail, the way a kernel refusal does.
    func refuse() {
        lock.lock()
        accepting = false
        lock.unlock()
    }

    var clamshellSwitch: ClamshellSleepSwitch {
        ClamshellSleepSwitch { [self] disabled in
            lock.lock()
            defer { lock.unlock() }
            guard accepting else { return false }
            recorded.append(disabled)
            return true
        }
    }
}
