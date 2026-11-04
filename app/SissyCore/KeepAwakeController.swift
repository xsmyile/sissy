import Foundation

/// The keep-awake hold as the engine drives it: what it has taken, what it is
/// owed, and when it ends.
///
/// A value on the engine rather than an actor of its own. What suspends is the
/// call into `KeepAwake`, and that stays the engine's, so a hold moved here adds
/// no suspension point to `UsageEngine.start` or `UsageEngine.stop`, and a change
/// to the hold cannot land between two lines that read as one step today.
///
/// What it does not hold is the setting: `config` is the engine's, and so is the
/// write that saves it. `begin` and `settle` are the two halves of one apply,
/// either side of the engine's own suspension.
struct KeepAwakeController {
    /// What one call into the assertions is asking for, carried across the
    /// suspension so its answer can tell whether it still speaks for the engine.
    struct Apply {
        fileprivate let generation: Int
        let wanted: Bool
        let lidAsked: Bool
        let floorReached: Bool
    }

    /// Holds the power assertion. Constructed unconditionally and inert until
    /// asked, like the probe beside it: an actor nobody has told to hold anything
    /// touches nothing.
    let assertions: KeepAwake
    /// How long a hold in each mode survives without help.
    private let policy: KeepAwakePolicy
    /// Reads where the power comes from, for the battery floor.
    private let powerSource: PowerSourceGauge
    /// Whether the Mac is being held awake right now, as opposed to what the
    /// user asked for — which is `config.keepAwake`. They differ when power
    /// management refuses the assertion, and the panel shows both.
    private(set) var active = false
    /// When the hold in force was taken, and `nil` while nothing is held.
    ///
    /// It belongs to the hold rather than to the call that applied it: a hold
    /// already in force keeps the instant it started from, so what the panel
    /// counts up from is the Mac's, never the last time this ran.
    private var since: Date?
    /// What the ceiling on `on` counts from, which is not always `since`.
    ///
    /// It starts with the hold and starts again whenever the user asks for a
    /// run from now under one: a ceiling picked, the lid switched on, or the
    /// mode switched to `on` under an automatic hold. Counted from the hold
    /// instead, a ceiling picked under it ended it in seconds on two nights,
    /// see `UsageEngine.setKeepAwakeCeiling`. `since` keeps the older instant,
    /// because what the panel counts up from is how long the Mac has been held,
    /// and that did not change.
    private var ceilingFrom: Date?
    /// Whether the lid half is being let go because the battery fell below
    /// `config.lidBatteryFloor`, held so the release and the return are each
    /// logged once rather than on every apply.
    private var lidReleasedForBattery = false
    /// Asks for the floor to be read again on every change of power source,
    /// held only while a lid hold with a floor is wanted.
    private var powerSourceWatch: PowerSourceWatch?
    /// Whether the screen is being held lit too, as opposed to whether the
    /// user asked for it — which is `config.keepScreenAwake`. Same split as
    /// `active` draws against the mode, for the same reason.
    private(set) var coversScreen = false
    /// Whether closing the lid leaves the Mac working, as opposed to whether
    /// the user asked for it, which is `config.keepAwakeWithLidClosed`.
    private(set) var coversLid = false
    /// Which apply currently speaks for the engine. Bumped on entry so a call
    /// that returns to find a newer stamp knows it was overtaken while suspended.
    private var generation = 0
    /// When a turn last landed, which is what `auto` holds the Mac against.
    /// `nil` until one does: an automatic hold begins when the agents do, not
    /// when Sissy launches.
    private var lastAgentActivityAt: Date?
    /// Newest live event any provider has reported, as that provider stamped
    /// it. Held only to tell one turn from the next — the hold itself counts
    /// from when the reading arrived, never from a CLI's own clock.
    private var lastObservedActivityAt: Date?
    /// Wakes when the hold in force is due to end. Owned here so `stop()` has
    /// something to cancel rather than leaving a sleeper against a torn-down
    /// engine.
    private var deadlineTask: Task<Void, Never>?

    init(assertions: KeepAwake, policy: KeepAwakePolicy, powerSource: PowerSourceGauge) {
        self.assertions = assertions
        self.policy = policy
        self.powerSource = powerSource
    }

    /// What the frame carries about the hold.
    func state(mode: KeepAwakeMode) -> KeepAwakeState {
        KeepAwakeState(
            mode: mode, active: active, since: since, coversScreen: coversScreen,
            coversLid: coversLid)
    }

    /// Whether the Mac should be held right now.
    ///
    /// `on` is the switch and `auto` is the evidence: a hold the agents earn
    /// by working, and lose by going quiet for `idleWindow`. Both die with the
    /// lifecycle, because quitting Sissy has to let the Mac sleep again.
    func wanted(config: ServerConfig, running: Bool) -> Bool {
        guard running else { return false }
        switch config.keepAwake {
        case .off: return false
        case .on: return true
        case .auto: return automaticHoldEarned
        }
    }

    var automaticHoldEarned: Bool {
        guard let last = lastAgentActivityAt else { return false }
        return Date().timeIntervalSince(last) < policy.idleWindow
    }

    /// Starts a run from now under the hold in force, if there is one.
    mutating func restartCeiling() {
        if active { ceilingFrom = Date() }
    }

    /// Whether the floor's answer differs from the one the hold was last applied
    /// under, because the notification behind a change of power source fires on
    /// every battery attribute and nearly all of them change nothing.
    func batteryFloorMoved(config: ServerConfig) -> Bool {
        config.lidBatteryFloor.isReached(by: powerSource.read()) != lidReleasedForBattery
    }

    /// The half of an apply ahead of the suspension: takes the stamp, and reads
    /// the floor for what the assertions are about to be asked.
    mutating func begin(
        config: ServerConfig, running: Bool, onPowerChange: @escaping @Sendable () -> Void
    ) -> Apply {
        generation &+= 1
        let wanted = wanted(config: config, running: running)
        let lidAsked = wanted && config.keepAwakeWithLidClosed
        let floorWatched = lidAsked && config.lidBatteryFloor != .never
        watchPowerSource(floorWatched, onChange: onPowerChange)
        let reading = floorWatched ? powerSource.read() : nil
        let floorReached = config.lidBatteryFloor.isReached(by: reading)
        noteBatteryFloor(floorReached, reading: reading, logged: lidAsked, floor: config.lidBatteryFloor)
        return Apply(
            generation: generation, wanted: wanted, lidAsked: lidAsked, floorReached: floorReached)
    }

    /// The half after it: takes what the assertions answered, unless a later
    /// apply has overtaken this one, and answers whether it still speaks for the
    /// engine.
    mutating func settle(_ hold: KeepAwakeHold, for apply: Apply) -> Bool {
        guard apply.generation == generation else { return false }
        active = hold.system && apply.wanted
        coversScreen = hold.screen && apply.wanted
        coversLid = hold.lid && apply.wanted
        since = active ? (since ?? Date()) : nil
        ceilingFrom = active ? (ceilingFrom ?? Date()) : nil
        return true
    }

    /// Records whether the floor is holding the lid back, and logs its release
    /// and its return once each. Not logged when the lid is no longer asked
    /// for at all: a hold that ended is not a lid taken back.
    ///
    /// The reading is taken fresh on every apply rather than cached, because
    /// it is one IPC and a cached one is how a lid would be held on a charge
    /// that had already fallen.
    private mutating func noteBatteryFloor(
        _ reached: Bool, reading: PowerSourceReading?, logged: Bool, floor: LidBatteryFloor
    ) {
        guard reached != lidReleasedForBattery else { return }
        lidReleasedForBattery = reached
        guard logged else { return }
        let charge = reading?.batteryPercent.map { "\($0)%" } ?? "unknown"
        if reached {
            sissyLog(
                "sissy: keep-awake let the lid go: on battery at \(charge), "
                    + "below the \(floor.rawValue)% floor")
        } else {
            sissyLog(
                "sissy: keep-awake takes the lid back: battery at \(charge), "
                    + (reading?.onBattery == true ? "on battery" : "on power"))
        }
    }

    /// Starts or stops listening for power-source changes, which only a lid
    /// hold with a floor needs.
    private mutating func watchPowerSource(
        _ wanted: Bool, onChange: @escaping @Sendable () -> Void
    ) {
        guard wanted != (powerSourceWatch != nil) else { return }
        guard wanted else {
            powerSourceWatch = nil
            return
        }
        powerSourceWatch = PowerSourceWatch(
            fallback: "the battery floor is read only when the hold changes",
            onChange: onChange)
    }

    /// When the hold in force runs out on its own, and `nil` when nothing is
    /// holding or nothing would end it.
    ///
    /// The clock is the wall's, sleep included: the deadline is a `Date`,
    /// and the task waiting on it sleeps on the continuous clock, which keeps
    /// counting while the Mac is asleep, so a ceiling that passed during a
    /// sleep ends the hold at the next wake. That is deliberate. A ceiling is
    /// a bound on how long the user agreed to have the Mac held, and one that
    /// paused while the Mac slept would stretch an hour's hold across a night
    /// of naps; the restarts in `ceilingFrom` are what keep a run the
    /// user asked for from inheriting an older one's clock.
    func deadline(config: ServerConfig) -> Date? {
        guard active, let since else { return nil }
        switch config.keepAwake {
        case .off: return nil
        case .auto: return (lastAgentActivityAt ?? since) + policy.idleWindow
        case .on:
            let from = ceilingFrom ?? since
            return config.keepAwakeCeiling.hours.map {
                from + TimeInterval($0) * policy.ceilingHour
            }
        }
    }

    /// Wakes the engine when the hold is due to end.
    ///
    /// A loop rather than a task per emit: `auto` pushes its deadline forward
    /// on every turn that lands, and re-creating this each time would build a
    /// task several times a second while agents work. Waking at the old
    /// deadline and finding it has moved costs one comparison instead.
    mutating func rearmDeadline(
        config: ServerConfig,
        current: @escaping @Sendable () async -> Date?,
        passed: @escaping @Sendable () async -> Void
    ) {
        cancelDeadline()
        guard deadline(config: config) != nil else { return }
        deadlineTask = Task {
            while !Task.isCancelled {
                guard let deadline = await current() else { return }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    await passed()
                    return
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    mutating func cancelDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    /// Records that agents are working, which in `auto` is what earns the
    /// hold, and answers whether a new turn landed.
    ///
    /// A provider stamps an event as live only once its own cold scan has
    /// finished, so what reaches here is a turn that landed while Sissy was
    /// watching rather than a backfill reporting what happened before it was
    /// launched. That distinction cannot be drawn from the day total: the
    /// scan emits its intermediate results, and each of those grew the total
    /// too — which is how a launch on a busy day took a hold with nothing
    /// running. `reemit` and the midnight roll-over reach this path as well,
    /// and neither advances a provider's marker.
    ///
    /// The hold then counts from *now*, not from the stamp: the stamp comes
    /// off a CLI's own log line, whose clock Sissy does not own and whose
    /// precision it does not choose, and an idle window measured against it
    /// would start part-spent on arrival.
    mutating func noteAgentActivity(_ slices: [ProviderSlice]) -> Bool {
        guard let latest = slices.compactMap({ $0.signals.lastActivityAt }).max(),
            latest > lastObservedActivityAt ?? .distantPast
        else { return false }
        lastObservedActivityAt = latest
        lastAgentActivityAt = Date()
        return true
    }
}
