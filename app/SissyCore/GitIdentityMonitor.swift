import Foundation

/// Reads the commit identity of every repository the ledger names, and
/// publishes which of them commit under a name their forge does not expect.
///
/// It is not a `UsageProvider` and does not ride one: an identity belongs to a
/// repository rather than to a log tail, it is the same answer whichever CLI
/// did the work, and it exists for a repository that has spent nothing today.
/// So it publishes its own value and the engine hangs it on the frame beside
/// the slices, exactly as `ProviderStatusMonitor` does.
///
/// **The repositories are the ones Sissy already knows.** `ProjectLedger` is
/// what the tail fills as it attributes work, so this needs no scan of the
/// disk, no folder to configure and no permission — it answers for the
/// repositories the user actually works in, which is the set the question is
/// about. A checkout that has been deleted is skipped rather than reported:
/// measured on one machine, 142 checkouts fold into 26 repositories of which 3
/// are gone.
///
/// **Nothing it publishes outlives it.** `stop` drops the readings, for the
/// reason the status monitor's does: the engine rebuilds every frame from
/// `currentIdentities()`, so a cancelled loop would otherwise leave a warning
/// standing about a repository nobody is reading any more.
actor GitIdentityMonitor {
    /// While there are agents working. Identity changes when someone edits a
    /// config file, which is rare and never urgent — the reading has to be
    /// right when the panel is opened, not within a minute of the edit.
    static let refreshInterval: Duration = .seconds(600)
    /// Once nothing has been seen working for `idleAfter`.
    static let idleRefreshInterval: Duration = .seconds(3600)
    static let idleAfter: TimeInterval = 3600
    /// The whole sweep's budget. Each invocation carries its own timeout, so
    /// without this a machine with unreachable checkouts could spend every
    /// repository's ten seconds in turn. What is read by the deadline is
    /// published; the rest waits for the next round.
    static let sweepBudget: TimeInterval = 30

    /// One value rather than a reading per repository, for the reason the
    /// status monitor's is: the panel reads the whole set while a sweep may be
    /// part way through the next one, and a verdict is a property of the set.
    nonisolated private let published = LockedValue([RepositoryIdentity]())
    /// When the last round finished, whether or not it changed anything: a
    /// page that dates the reading has to move when a press re-read the same
    /// answer, or the press reads as having done nothing.
    nonisolated private let checkedAt = LockedValue<Date?>(nil)
    nonisolated private let lastActivity = LockedValue<Date?>(nil)
    /// The generation the blocking read loop checks between repositories.
    ///
    /// `stop()` cancels `pollTask`, which a loop parked in `waitUntilExit`
    /// cannot observe — so without this a stopped monitor goes on spawning a
    /// `git` per repository for a monitor nothing is listening to, and an
    /// engine torn down because a provider was switched off waits behind it.
    nonisolated private let liveGeneration = LockedValue(0)
    private let ledger: ProjectLedger
    /// The git to read with, injected by a test and otherwise resolved on the
    /// first sweep.
    ///
    /// Not in `init`: finding one costs an `xcode-select -p` on a Mac with no
    /// Homebrew or MacPorts git, and the engine is built on the path that
    /// launches the app. Nil once `didLocate` is set is a Mac with no git that
    /// can be run without putting a dialog on screen, which is the one
    /// condition under which this module does nothing at all.
    private var git: URL?
    private var didLocate: Bool
    private let home: URL?
    private var pollTask: Task<Void, Never>?
    private var generation = 0
    /// The round in flight. The actor is reentrant across the hop the reads
    /// take, so the poll loop and the panel's own refresh can otherwise run
    /// one each — and the slower of the two writes its own `scans` back last,
    /// reinstating a reading the faster one had already replaced. A second
    /// caller waits on this one rather than returning at once, so a press
    /// landing during the poll's round ends when that round does.
    private var inFlight: Task<Void, Never>?
    /// The last reading of each repository, and when each file behind it was
    /// written. A round that finds every stamp where it left it reuses the
    /// reading rather than spawning three processes to arrive at it again.
    private var scans: [String: GitIdentityScan] = [:]
    private var stamps: [String: [String: Date]] = [:]

    init(
        ledger: ProjectLedger, git: URL? = nil, home: URL? = AgentHookInstaller.userHome
    ) {
        self.ledger = ledger
        self.git = git
        self.didLocate = git != nil
        self.home = home
    }

    nonisolated func currentIdentities() -> [RepositoryIdentity] { published.load() }

    nonisolated func currentCheckedAt() -> Date? { checkedAt.load() }

    nonisolated func noteActivity(at when: Date = Date()) {
        lastActivity.update { $0 = when }
    }

    /// Starts the sweep loop. `onRefresh` fires once per finished round, which
    /// is one frame every ten minutes at the most. Idempotent, and a no-op
    /// where there is no git to run.
    func start(onRefresh: @Sendable @escaping () async -> Void) {
        guard pollTask == nil, home != nil else { return }
        pollTask = Task { [weak self] in
            var delay: Duration = .zero
            while !Task.isCancelled {
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
                }
                guard let self else { return }
                await self.sweepOnce(onRefresh: onRefresh)
                delay = await self.nextDelay()
            }
        }
    }

    func stop() {
        generation &+= 1
        liveGeneration.update { $0 &+= 1 }
        pollTask?.cancel()
        pollTask = nil
        inFlight?.cancel()
        inFlight = nil
        scans = [:]
        stamps = [:]
        published.store([])
        checkedAt.store(nil)
    }

    /// One round over every repository the ledger names.
    ///
    /// Internal rather than private so a test can run exactly one round and
    /// assert on what it published, instead of waiting on the scheduler.
    func sweepOnce(onRefresh: @Sendable @escaping () async -> Void) async {
        if let inFlight {
            await inFlight.value
            return
        }
        let round = Task { await sweep(onRefresh: onRefresh) }
        inFlight = round
        await round.value
        inFlight = nil
    }

    private func sweep(onRefresh: @Sendable @escaping () async -> Void) async {
        if !didLocate {
            didLocate = true
            git = GitIdentityReader.locate()
        }
        guard let git, let home else { return }
        let stamp = generation
        let targets = repositories()
        guard !targets.isEmpty else { return }
        let round = await read(targets, git: git, home: home, reusing: scans, stamps: stamps)
        guard stamp == generation, !Task.isCancelled else { return }
        scans = round.scans
        stamps = round.stamps
        let judged = GitIdentityConsensus.judged(round.scans.values.map(\.identity)).sorted {
            $0.repository.localizedStandardCompare($1.repository) == .orderedAscending
        }
        published.store(judged)
        checkedAt.store(Date())
        await onRefresh()
    }

    /// Every repository the ledger names, paired with the forge it is pushed
    /// to. The remote is read through the resolver rather than by this module,
    /// so a row's host is the same string the project row beside it shows.
    ///
    /// A resolver per round rather than one for the monitor's life. Its cache
    /// never expires — which is right for the tail, where it answers a hundred
    /// working directories a second — and wrong here: a repository whose
    /// `origin` has been re-pointed at another forge would go on being judged
    /// against the old one until the engine was rebuilt, and the identity
    /// beside it would already have been re-read, because `.git/config` is
    /// where both of them live. Reading them fresh costs the round a file per
    /// repository and no process at all.
    private func repositories() -> [(String, ProjectRemote?)] {
        let resolver = ProjectResolver(ledger: ledger)
        return Set(ledger.all().map(\.project)).map { ($0, resolver.repositoryRemote(for: $0)) }
    }

    /// What one round ended up holding: every repository still in the ledger,
    /// whether it was re-read or reused.
    private struct Round: Sendable {
        var scans: [String: GitIdentityScan] = [:]
        var stamps: [String: [String: Date]] = [:]
    }

    /// The reads themselves, off the cooperative pool.
    ///
    /// Every one of them blocks — a `Process` is read to end of file and then
    /// waited on — so running them on an executor that owns a handful of
    /// threads would park the actors sharing it. One hop, and the reads run in
    /// sequence behind it: the budget is what bounds a round rather than
    /// concurrency.
    ///
    /// A repository whose files have not been written since the last round
    /// keeps that round's reading. That is the whole of what makes this cheap
    /// at rest — a process costs about 67 ms whatever it runs, so three per
    /// repository per round is the only cost worth removing, and a reading
    /// cannot change unless a file behind it does.
    ///
    /// A repository the budget did not reach keeps its last reading too rather
    /// than falling off the page, and is re-read on the next round: the ledger
    /// still names it, so dropping it would report a repository as gone when
    /// the only thing that happened is that the clock ran out.
    ///
    /// **A stamp is only kept when it predates the read that produced it.**
    /// The files are stat'd after git has already read them, so an edit landing
    /// in between is invisible to the reading and would still be recorded as
    /// the state it was read at — freezing a stale answer until some later,
    /// unrelated edit moved the file again. A source written at or after the
    /// read began therefore leaves the repository unstamped, which is what
    /// makes the next round read it rather than trust it.
    private func read(
        _ targets: [(String, ProjectRemote?)], git: URL, home: URL,
        reusing scans: [String: GitIdentityScan], stamps: [String: [String: Date]]
    ) async -> Round {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let deadline = Date().addingTimeInterval(Self.sweepBudget)
                let live = self.liveGeneration.load()
                var round = Round()
                for (repository, remote) in targets {
                    if let known = scans[repository], let seen = stamps[repository],
                        GitIdentityReader.stamps(of: known.sources) == seen
                    {
                        round.scans[repository] = known
                        round.stamps[repository] = seen
                        continue
                    }
                    guard Date() < deadline, self.liveGeneration.load() == live else {
                        round.scans[repository] = scans[repository]
                        round.stamps[repository] = stamps[repository]
                        continue
                    }
                    let startedAt = Date()
                    guard
                        let scan = GitIdentityReader.read(
                            repository: repository, remote: remote, git: git, home: home)
                    else { continue }
                    round.scans[repository] = scan
                    let taken = GitIdentityReader.stamps(of: scan.sources)
                    if taken.values.allSatisfy({ $0 < startedAt }) {
                        round.stamps[repository] = taken
                    }
                }
                continuation.resume(returning: round)
            }
        }
    }

    private func nextDelay() -> Duration {
        let working = lastActivity.load().map { Date().timeIntervalSince($0) < Self.idleAfter }
        return working == true ? Self.refreshInterval : Self.idleRefreshInterval
    }
}
