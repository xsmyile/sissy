import CoreServices
import Foundation

/// Batch of paths delivered by a single FSEvents callback. `rescanAll` and
/// `rootChanged` signal kernel-side overflow conditions that demand a full
/// re-scan instead of (or in addition to) processing the listed `urls`.
struct FSWatcherEvent: Sendable {
    let urls: [URL]
    let rescanAll: Bool
    let rootChanged: Bool
}

/// Thin Swift wrapper around `FSEventStreamCreate` for watching a single
/// directory tree. Designed for daemon-style long-running observers; not a
/// general FSEvents library.
///
/// Why a `class` and not an `actor`: the FSEvents C API requires a plain C
/// callback (no `@Sendable`/no captures) and a strong-ref'd info pointer
/// passed via `FSEventStreamContext`. Mixing that with an actor's
/// re-entrancy would force every callback to hop the actor; we still hop
/// for the async event handler, but lifetime management stays simple by
/// keeping the stream pointer on a regular object guarded by `lock`.
///
/// Threading model: the C callback runs on `callbackQueue` (a dedicated
/// utility-QoS serial queue). It synchronously builds the `FSWatcherEvent`
/// payload then hands it to the caller's async handler via a `Task`. The
/// handler runs off the FSEvents queue so a slow consumer can't block
/// future kernel callbacks.
///
/// References:
/// - Apple "File System Events Programming Guide" (archive, still authoritative for Tahoe 26).
/// - Apple Developer Forums #115387 — strong-ref pattern, deprecation of
///   `FSEventStreamScheduleWithRunLoop` in favor of
///   `FSEventStreamSetDispatchQueue`.
///
/// `@unchecked Sendable`: mutable state (`stream`, `onEvent`) is guarded by
/// `lock`; the FSEvents C callback receives `self` via an `Unmanaged`
/// passUnretained pointer, which is safe as long as the owner keeps a
/// strong reference for the watcher's lifetime — the standard pattern for
/// CoreFoundation callbacks and the only way to bridge into Swift's
/// `Sendable` world without an actor (a C function pointer cannot carry
/// captures or hop actors).
final class FSWatcher: @unchecked Sendable {
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var onEvent: (@Sendable (FSWatcherEvent) async -> Void)?

    init(label: String = "sissy.fswatcher") {
        self.callbackQueue = DispatchQueue(label: label, qos: .utility)
    }

    deinit {
        stopLocked()
    }

    /// Begin watching `path`. Latency is the FSEvents coalescing window — at
    /// the default 1.0s the kernel batches bursts (e.g. a flurry of JSONL
    /// appends during a Claude turn) into one callback. Set lower if you need
    /// sub-second latency at the cost of more callbacks.
    ///
    /// Returns `true` on success. A second call with the watcher already
    /// started is a no-op + false; call `stop()` first if you want to switch
    /// paths.
    @discardableResult
    func start(
        path: URL,
        latency: CFTimeInterval = 1.0,
        ignoreSelf: Bool = true,
        onEvent: @escaping @Sendable (FSWatcherEvent) async -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stream != nil { return false }

        self.onEvent = onEvent

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // FileEvents     → per-file paths (without it we'd only get parent
        //                  directories and have to enumerate them ourselves).
        // UseCFTypes     → eventPaths arrives as CFArray<CFString>, which
        //                  bridges to [String] without manual C-string math.
        // WatchRoot      → fires a RootChanged event if `path` itself is
        //                  renamed/deleted. Lets the daemon log + reconnect
        //                  rather than silently losing notifications.
        // IgnoreSelf     → suppress events caused by this process. Default on
        //                  because the daemon never writes inside
        //                  `~/.claude/projects` in production; the self-test
        //                  flips it off because the test *is* the writer.
        var flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagWatchRoot)
        if ignoreSelf {
            flags |= UInt32(kFSEventStreamCreateFlagIgnoreSelf)
        }

        let paths = [path.path] as CFArray
        guard
            let s = FSEventStreamCreate(
                kCFAllocatorDefault,
                fsWatcherCallback,
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
        else {
            self.onEvent = nil
            return false
        }
        FSEventStreamSetDispatchQueue(s, callbackQueue)
        if !FSEventStreamStart(s) {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            self.onEvent = nil
            return false
        }
        stream = s
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        onEvent = nil
    }

    /// Entry point invoked from the C callback after it has decoded the
    /// `eventPaths`/`eventFlags` arrays. Splits the work: build a Sendable
    /// payload, then hop off the FSEvents queue via `Task` so a slow consumer
    /// can't stall future kernel notifications.
    fileprivate func dispatch(_ event: FSWatcherEvent) {
        let handler: (@Sendable (FSWatcherEvent) async -> Void)?
        lock.lock()
        handler = onEvent
        lock.unlock()
        guard let handler else { return }
        Task { await handler(event) }
    }
}

/// Top-level C callback. FSEvents requires a plain function pointer (no
/// captures), so the watcher is reached via `Unmanaged.fromOpaque`.
/// `clientCallBackInfo` is the pointer we stashed in
/// `FSEventStreamContext.info` (i.e. `Unmanaged.passUnretained(watcher)`).
private func fsWatcherCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()

    // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArrayRef
    // holding CFString entries. The unretained bridge below is safe because
    // the array lives for the duration of this callback.
    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let bridged = cfArray as? [String] ?? []

    var urls: [URL] = []
    urls.reserveCapacity(bridged.count)
    var rescanAll = false
    var rootChanged = false
    let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
    let userDropped = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
    let kernelDropped = FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
    let rootBit = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)

    for i in 0..<numEvents {
        let flag = eventFlags[i]
        if flag & rootBit != 0 { rootChanged = true }
        // MustScanSubDirs / UserDropped / KernelDropped all mean "we lost
        // some events" — treat identically with a full rescan.
        if flag & (mustScan | userDropped | kernelDropped) != 0 { rescanAll = true }
        if i < bridged.count {
            urls.append(URL(fileURLWithPath: bridged[i]))
        }
    }

    watcher.dispatch(
        FSWatcherEvent(urls: urls, rescanAll: rescanAll, rootChanged: rootChanged)
    )
}
