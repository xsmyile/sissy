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
/// directory tree. Designed for long-running observers; not a
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
/// payload then yields it to a stream that one task drains into the caller's
/// async handler, so batches arrive in the order the kernel sent them and one
/// at a time: a `rescanAll` batch cannot land after the per-file batch that
/// followed it. The handler runs off the FSEvents queue so a slow consumer
/// can't block future kernel callbacks.
///
/// The stream is torn down on `callbackQueue` itself, so no callback is still
/// running against a watcher that `stop()` or `deinit` has already let go.
/// That makes `stop()` wait for a callback in flight, which only builds the
/// payload and yields it.
///
/// References:
/// - Apple "File System Events Programming Guide" (archive, still authoritative for Tahoe 26).
/// - Apple Developer Forums #115387 — strong-ref pattern, deprecation of
///   `FSEventStreamScheduleWithRunLoop` in favor of
///   `FSEventStreamSetDispatchQueue`.
///
/// `@unchecked Sendable`: mutable state (`stream`, `events`) is guarded by
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
    private var events: AsyncStream<FSWatcherEvent>.Continuation?
    /// Marks `callbackQueue` as this watcher's, so a teardown that is already
    /// running on it does not wait on itself.
    private static let queueKey = DispatchSpecificKey<UUID>()
    private let queueToken = UUID()

    init(label: String = "sissy.fswatcher") {
        self.callbackQueue = DispatchQueue(label: label, qos: .utility)
        callbackQueue.setSpecific(key: Self.queueKey, value: queueToken)
    }

    deinit {
        onCallbackQueue { stopLocked() }
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
        //                  renamed/deleted. Lets the reader log it and re-arm
        //                  rather than silently losing notifications.
        // IgnoreSelf     → suppress events caused by this process. Default on
        //                  because Sissy never writes inside
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
            return false
        }
        FSEventStreamSetDispatchQueue(s, callbackQueue)
        if !FSEventStreamStart(s) {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        let (batches, continuation) = AsyncStream<FSWatcherEvent>.makeStream()
        events = continuation
        Task {
            for await batch in batches { await onEvent(batch) }
        }
        return true
    }

    func stop() {
        onCallbackQueue {
            lock.lock()
            defer { lock.unlock() }
            stopLocked()
        }
    }

    /// Ends the stream and the delivery task after the batches already
    /// yielded, which the caller's handler still receives and is expected to
    /// ignore once it has stopped, as it did when each batch was a task of
    /// its own. A per-file batch dropped here would wait for the tail's
    /// safety-net poll.
    private func stopLocked() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        events?.finish()
        events = nil
    }

    /// Runs `work` on `callbackQueue`, where the C callback runs, so a
    /// teardown can never interleave with a callback in flight. Inline when
    /// already there, which is where a last reference dropped by a callback
    /// would run `deinit`.
    private func onCallbackQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == queueToken {
            work()
        } else {
            callbackQueue.sync(execute: work)
        }
    }

    /// Entry point invoked from the C callback after it has decoded the
    /// `eventPaths`/`eventFlags` arrays. Yields the Sendable payload to the
    /// delivery stream, which a slow consumer drains at its own pace without
    /// stalling future kernel notifications.
    fileprivate func dispatch(_ event: FSWatcherEvent) {
        lock.lock()
        let events = events
        lock.unlock()
        events?.yield(event)
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
