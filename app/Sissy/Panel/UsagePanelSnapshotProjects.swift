import Foundation

extension UsagePanelSnapshot {
    struct ProjectRow: Equatable, Identifiable {
        let id: String
        /// The repository's own name — the last component of its path, which
        /// is what the user calls it.
        let name: String
        /// The account the repository is pushed to, drawn quiet in front of
        /// the name. Nil when the repository names no forge, and on the folded
        /// row, which stands for several.
        ///
        /// It prefixes the name rather than replacing it: two accounts can
        /// hold a `website` each, and without this the panel draws one label
        /// twice. The name still comes from the directory, so a row never
        /// changes what it was already called.
        let owner: String?
        /// The repository as its forge names it, for the card a click on the
        /// row opens. Nil for a row that stands for no repository and for one
        /// whose remote names no forge — both of which have nothing to open,
        /// so the click does nothing rather than opening an empty card.
        let repository: RepositoryLink?
        /// What the row hovers: a repository's full path. Nil on the folded
        /// row, which stands for several. A project path is a client's name as
        /// often as not, so the row shows the name and keeps the rest for a
        /// hover.
        let tooltip: String?
        let tokens: String
        let cost: String
        let share: Double
        /// Which CLIs the money on this row went through, in the panel's own
        /// provider order so the marks and the bar's segments read the same
        /// way down the page.
        ///
        /// Empty on the folded row, which stands for no single repository,
        /// and on every row of a single provider's own list — there the answer
        /// is the page's own name. The shares are of the same day `share` is
        /// of, so they sum to it.
        let providers: [ProviderShare]
    }

    /// One model's share of one provider's day, as its own page prints it.
    struct ModelRow: Equatable, Identifiable {
        /// The model id as the vendor spells it, which is also what the pill
        /// is keyed by.
        let id: String
        /// The same id with its release date and its vendor prefix taken off,
        /// which is the pill's first line.
        let name: String
        /// The pill's second line: the share of the day and what it cost.
        /// The share is of the money while there is any, and of the tokens
        /// when the whole day priced at nothing.
        let reading: String
        /// The four token counters apart, with the raw id. The pill's hover
        /// and its accessibility label, which are the same sentence: anything
        /// only a pointer can reach does not exist for VoiceOver.
        let detail: String
    }

    /// One model's day split by the effort it ran at, as a row of the provider
    /// page's `By effort` block.
    struct EffortRow: Equatable, Identifiable {
        /// The model id as the vendor spells it, which is what the row is
        /// keyed by.
        let id: String
        /// The same id the pills above spell, so the two blocks name one model
        /// one way.
        let name: String
        /// What each effort cost and how many turns it took. The row's hover
        /// and its accessibility label, which are the same sentence — the bar
        /// has no room for either, and anything only a pointer can reach does
        /// not exist for VoiceOver.
        let detail: String
        /// A segment per effort, dearest first: the vendor's word and that
        /// effort's share of what this model spent, which is what the effort
        /// page draws the model's bar and its legend from.
        let segments: [EffortSegment]
        /// What the model spent over the window and in how many turns.
        let total: String
    }

    /// One effort's share of one model's window, as a segment of its bar.
    struct EffortSegment: Equatable, Identifiable {
        /// The vendor's word, or nil for spend whose lines named no effort.
        let effort: String?
        let share: Double
        /// The word and the share, as the legend under the bar prints them.
        let label: String

        var id: String { effort ?? UsageFormat.effortUnattributed }
    }

    /// What the provider page's `By effort` row says, and whether it is a door.
    struct EffortSummary: Equatable {
        /// The provider's leading effort and its share of the window's spend.
        let lead: String
        /// False when every model ran almost wholly at the effort the lead
        /// names. The page would then draw one full bar per model, which says
        /// nothing the row has not, so the row answers for itself instead.
        let opens: Bool
    }

    /// The effort splits of the window the strip draws, and how many of its
    /// days named an effort at all.
    struct EffortWindow: Equatable {
        let splits: [EffortSplit]
        let covered: Int
    }

    /// What one provider spent on one project, as a share of the day.
    ///
    /// Derived rather than carried on `ProjectTotals`: the combined list sums
    /// the CLIs into one row per repository by design, and the frame still
    /// holds both halves on its own slices.
    struct ProviderShare: Equatable, Identifiable {
        /// The provider id, which is what the mark and the tint are keyed by.
        let id: String
        let share: Double
    }

    /// What a day spent that no repository can be named for: the line under
    /// the list rather than the last row of it.
    ///
    /// It is not a project, so it gets no rank among them, no bar, no path and
    /// no forge — it is the arithmetic that lets the rows above it reach the
    /// total beside them, which is a sentence rather than a reading. It has no
    /// `share` for the same reason: a bar invites a comparison with the rows,
    /// and the one thing this line is not is a project that happened to be
    /// small.
    struct ProjectsResidue: Equatable {
        let tokens: String
        let cost: String
        /// Which CLIs it went through, where more than one is metered. Empty
        /// on a provider's own page, whose title has named the CLI already.
        let providers: [ProviderCost]
    }

    /// One provider's share of a figure, in money rather than in a fraction of
    /// a bar — the residue has no bar for the fraction to be of.
    struct ProviderCost: Equatable, Identifiable {
        let id: String
        let cost: String
    }

    /// A repository on the forge it is pushed to.
    ///
    /// `label` is the forge's own name for it, which is not always the
    /// directory's: a clone renamed on disk keeps the row the name the user
    /// gave it and the card the name the forge answers to.
    struct RepositoryLink: Equatable {
        let label: String
        let host: String
        /// Nil for a remote that names no page — the card then says where the
        /// repository lives without claiming a way there.
        let page: URL?
    }

    /// Every project a day names, unfolded, for the page behind the section's
    /// own row.
    ///
    /// Built on demand rather than carried on the snapshot: the panel makes a
    /// snapshot per frame while it is open, and the full list is wanted on one
    /// page that is usually closed.
    ///
    /// **The panel's window, on the combined page.** `window` is the archive's
    /// rollup for the period the Overview reads over, which carries the
    /// window's split by repository and what named none, so the page lists
    /// what the Overview's block folded. The `Today` preset passes none and
    /// keeps the live day buckets, which run ahead of the archive's copy of
    /// today by the tail's flush. A window's rows carry no split by CLI: the
    /// archive sums a repository across providers before it reaches here.
    ///
    /// **Today on a provider's own page.** The archive keeps no split by
    /// repository per provider, and that page is about the provider's day.
    ///
    /// `provider` nil sums every CLI and gives each row its split; naming one
    /// takes that provider's own day, where the split would repeat the page's
    /// title on every row.
    static func projectsPage(
        frame: FrameData, provider: String?, period: UsageRange = .preset(.today),
        window: UsageHistoryRollup? = nil
    ) -> ProjectsPage {
        if provider == nil, let window {
            let unattributed = window.unattributed
            return ProjectsPage(
                provider: nil,
                rows: makeProjects(window.projects, totalCost: window.cost, limit: nil),
                residue: unattributed.tokens > 0
                    ? ProjectsResidue(
                        tokens: UsageFormat.tokens(unattributed.tokens),
                        cost: UsageFormat.cost(unattributed.cost), providers: [])
                    : nil,
                subtitle: UsageFormat.projectsSubtitle(
                    count: window.projects.count, cost: window.cost, period: period))
        }
        let slices =
            provider.map { id in frame.providers.filter { $0.id == id } } ?? frame.providers
        let projects = provider == nil ? frame.projects : slices.first?.projects ?? []
        let cost = slices.reduce(Decimal(0)) { $0 + $1.cost }
        return ProjectsPage(
            provider: provider,
            rows: makeProjects(
                projects, totalCost: cost, limit: nil,
                contributors: provider == nil ? contributors(frame.providers) : [:]),
            residue: makeResidue(slices, split: provider == nil),
            subtitle: UsageFormat.projectsSubtitle(count: projects.count, cost: cost)
        )
    }

    /// The projects page: every repository of the day, and the line that dates
    /// and totals them.
    struct ProjectsPage: Equatable {
        /// Whose day this is, or nil for every provider summed.
        let provider: String?
        /// Unfolded, so the page is the one place the whole list exists.
        let rows: [ProjectRow]
        /// What named no repository, which is the only surface that says so.
        /// The rows are read against the total in the subtitle and cannot
        /// reach it without this, so the line carries the figure rather than
        /// only the fact.
        let residue: ProjectsResidue?
        /// When, how many, and how much: the window the rows are over and
        /// their own total.
        let subtitle: String
    }

    /// Rows a popover can hold. Past this the answer is a report, and a
    /// report needs more than the two days the tail retains.
    ///
    /// Three: two repositories and the fold. The label above the list is the
    /// door to all of it, so a fourth and fifth row bought the Overview and
    /// every provider page 48 pt for readings one click away.
    private static let projectRowLimit = 3

    /// The busiest projects, with everything below them folded into one row.
    ///
    /// **Every row here is a repository**, which is what lets the section's
    /// own label count them: the fold stands for repositories too, and what
    /// named none is not a row at all but the line `makeResidue` builds for
    /// the page. It used to be the last row of this list, which put a reading
    /// that is not a project under a label counting projects, and gave the one
    /// thing on the list with nothing to open a bar, a hover and a rank.
    ///
    /// Ordered here rather than taken on trust, because this is the function
    /// that *drops* rows: a prefix over an order nobody established folds the
    /// day's largest project into "3 more projects" as readily as its
    /// smallest. A provider folds its own day out of a dictionary, whose key
    /// order is arbitrary, so the Overview's list came out ordered — it is
    /// summed through `combinedProjects` — and a provider's own page did not.
    static func makeProjects(
        _ unordered: [ProjectTotals],
        totalCost: Decimal,
        limit: Int? = projectRowLimit,
        contributors: [String: [String: Decimal]] = [:]
    ) -> [ProjectRow] {
        let projects = FrameBuilder.orderedProjects(unordered)
        guard !projects.isEmpty else { return [] }
        let share = { (cost: Decimal) -> Double in
            guard totalCost > 0 else { return 0 }
            return NSDecimalNumber(decimal: cost).doubleValue
                / NSDecimalNumber(decimal: totalCost).doubleValue
        }
        let kept =
            limit.map { projects.count <= $0 ? projects.count : $0 - 1 }
            ?? projects.count
        var rows = projects.prefix(kept).map { project in
            ProjectRow(
                id: project.path,
                name: UsageFormat.projectName(project.path),
                owner: project.remote?.owner,
                repository: project.remote.map {
                    RepositoryLink(
                        label: "\($0.owner)/\($0.repository)", host: $0.host, page: $0.page)
                },
                tooltip: project.path,
                tokens: UsageFormat.tokens(project.tokens),
                cost: UsageFormat.cost(project.cost),
                share: share(project.cost),
                providers: providerShares(contributors[project.path] ?? [:], share: share)
            )
        }
        if kept < projects.count {
            let rest = projects.dropFirst(kept)
            let restCost = rest.reduce(Decimal(0)) { $0 + $1.cost }
            rows.append(
                ProjectRow(
                    id: Self.foldedProjectRowID,
                    name: UsageFormat.projectsFolded(count: rest.count),
                    owner: nil,
                    repository: nil,
                    tooltip: nil,
                    tokens: UsageFormat.tokens(rest.reduce(0) { $0 + $1.tokens }),
                    cost: UsageFormat.cost(restCost),
                    share: share(restCost),
                    providers: []
                ))
        }
        return rows
    }

    /// One pill per model, dearest first, or none at all.
    ///
    /// **Folded past four, which is what the width holds.** Measured
    /// 2026-09-22 at `PanelMetrics.width`: three pills want 210 pt of the 312
    /// a page has, four want 277, five want 344 and six 419. Past four the row
    /// does not degrade gracefully — both of a pill's lines shrink, and it was
    /// the money that went first, rendering `62% · $…` and `9% · $0.…`, where
    /// a truncated currency figure cannot be read at all. Pinning the figures
    /// to their ideal width only moved the damage: the row then overflowed and
    /// was clipped at both ends, losing the leading pill's first glyphs.
    ///
    /// Four is therefore the limit and it is a measurement rather than a
    /// guess: it is every model Claude ships in a day (opus, sonnet, haiku,
    /// fable) and it holds Codex's longest ids at 291 pt. The docstring here
    /// used to say **no fold**, on the grounds that the archive's busiest day
    /// held 3; that was true of the rows it described and of a block with a
    /// floor of two under it, and neither is the case any more.
    ///
    /// The fold is `modelPillLimit`'s, one pill standing for the rest, and it
    /// takes the **cheapest** because the list is dearest first — the models
    /// folded away are the ones the day did least on. It carries their summed
    /// share and their summed cost rather than a bare count, which is what
    /// `makeResidue` does for the spend no repository claims.
    ///
    /// **The percentage is a share of the money, and of the tokens as soon as
    /// any model has none.** A model the pricing sources do not know books
    /// tokens at a cost of zero, and zero is what it is *not*: the rate is
    /// unknown, which is the distinction `ProviderCredits` already holds for
    /// money and the strip holds for a day with no file. Sharing cost on a day
    /// that holds one would print that model at `0% · $0.00` beside millions
    /// of tokens — a measurement of nothing where there was a measurement, and
    /// the failure this paragraph used to claim to prevent while covering only
    /// the day where *every* model was unpriced. So the denominator is the
    /// tokens whenever a model has tokens and no cost, not only when the whole
    /// day prices at zero. The money stays on the pill either way.
    /// `FrameBuilder.orderedModels` falls back the same way, so the order and
    /// the percentages cannot disagree.
    ///
    /// **A share that rounds to nothing is worded, not rounded away.** A model
    /// worth 0.4% of the day would print `0%` beside a cost that is not zero,
    /// which is the same lie in smaller type; `<1%` is what the bar's own
    /// `BarGeometry.fillWidth` does for the identical case, where a share too
    /// small to draw still draws a stub. The percentages are therefore **not**
    /// renormalised to sum to 100 — three equal models read 33% each and sum
    /// to 99. Nobody adds four pills up, and the alternative is worse: largest
    /// remainder makes a model's own displayed share depend on which other
    /// models happen to sit beside it, so the same day could read 33% or 34%
    /// for the same money.
    ///
    /// **One model is one pill, and there is no floor.** There was, of two,
    /// for as long as the split was a list of rows under the `Today` figure:
    /// a row reading `claude-opus-5  8.1M · $8.17` under a headline reading
    /// `8.3M · $8.46` printed the same numbers twice, so a day with one model
    /// was better off silent. The pill answers a different question. It sits
    /// under the strip and what it carries that nothing else on the page does
    /// is the model's **name** — so a day spent entirely on one model is
    /// exactly the day the block is needed, because there is otherwise no
    /// surface in Sissy that says which one it was. Only the percentage is
    /// redundant at 100%, and a percentage is not what the pill is for.
    ///
    /// Empty therefore means one thing again: a provider that has read
    /// nothing.
    static func makeModels(
        _ unordered: [ModelTotals], provider: String, totalCost: Decimal, totalTokens: Int
    ) -> [ModelRow] {
        let unpriced = unordered.contains { $0.cost == 0 && $0.tokens > 0 }
        let byCost = totalCost > 0 && !unpriced
        let total =
            byCost
            ? NSDecimalNumber(decimal: totalCost).doubleValue : Double(totalTokens)
        guard total > 0 else { return [] }
        let ordered = FrameBuilder.orderedModels(unordered)
        let rows = ordered.map { model -> ModelRow in
            let part =
                byCost
                ? NSDecimalNumber(decimal: model.cost).doubleValue : Double(model.tokens)
            return ModelRow(
                id: model.model,
                name: UsageFormat.modelName(model.model, on: provider),
                reading: UsageFormat.modelReading(
                    share: part / total,
                    cost: UsageFormat.cost(model.cost)),
                detail: UsageFormat.modelTokenDetail(
                    id: model.model,
                    input: model.totals.inputTokens,
                    output: model.totals.outputTokens,
                    cacheRead: model.totals.cacheReadTokens,
                    cacheCreation: model.totals.cacheCreationTokens)
            )
        }
        return folded(rows, of: ordered, byCost: byCost, total: total)
    }

    /// How many pills the page's width holds whole. `makeModels` carries the
    /// measurement.
    private static let modelPillLimit = 4

    /// The list as it is drawn: every pill while they fit, and otherwise the
    /// dearest few with one standing for the rest.
    private static func folded(
        _ rows: [ModelRow], of models: [ModelTotals], byCost: Bool, total: Double
    ) -> [ModelRow] {
        guard rows.count > modelPillLimit else { return rows }
        let kept = modelPillLimit - 1
        let rest = models.dropFirst(kept)
        let part = rest.reduce(0.0) {
            $0
                + (byCost
                    ? NSDecimalNumber(decimal: $1.cost).doubleValue : Double($1.tokens))
        }
        let cost = rest.reduce(Decimal(0)) { $0 + $1.cost }
        let more = ModelRow(
            id: rest.map(\.model).joined(separator: " "),
            name: UsageFormat.pillsFolded(rest.count),
            reading: UsageFormat.modelReading(
                share: total > 0 ? part / total : 0, cost: UsageFormat.cost(cost)),
            detail: rest.map(\.model).joined(separator: " · "))
        return Array(rows.prefix(kept)) + [more]
    }

    /// One row per model, each carrying how its spend split by effort over the
    /// window the strip above it draws.
    ///
    /// **A block of its own under the day, not a tier inside the model pill
    /// and not a pill per pair.** A third tier could name only the busiest
    /// effort, which on a real Codex model throws away the half that makes the
    /// reading interesting — measured 2026-09-22, `gpt-6-astra` ran
    /// `medium 49% · high 38% · ultra 11% · xhigh 3%`, so the top word alone
    /// says 49% of nothing in particular. A pill per `(model, effort)` pair is
    /// six or seven pills on a page that folds at four, and the fold would
    /// take exactly the tail that carries the answer.
    ///
    /// **The window is the strip's, and it is named beside the heading.** A
    /// single day cannot carry this reading: measured the same day, 98.7% of
    /// this machine's Claude turns were one model at one effort, so a day's
    /// split is a word repeated. Over the strip's week it becomes an
    /// allocation — which model the high-effort turns are going to — and the
    /// days are already decoded, because `UsageHistoryStore.series` is what
    /// draws the bars.
    ///
    /// **It does not follow the strip's pointer.** The pills under the bars
    /// answer for the day being pointed at, which is their whole contract;
    /// this answers for the window, and a block that changed under the pointer
    /// while its own heading named a week would be two readings in one place.
    ///
    /// **Each row's shares are of its own model.** They sum to 100 across the
    /// row and never across the block, because the question is how *this*
    /// model's spend splits — a share of the provider's whole day would make
    /// every row but the busiest read as noise. Of the money, or of the tokens
    /// as soon as any pair has tokens and no cost, which is `makeModels`' rule
    /// for `makeModels`' reason.
    ///
    /// **Spend the lines named no effort for is the bar's last segment, never
    /// its first.** It is in the denominator, because leaving it out would let
    /// a model with nine tagged turns and one untagged read `high 100%` under
    /// a pill counting all ten; and it is pinned last however large it is,
    /// because it is not an effort and ranking it among them would give an
    /// absence the standing of a setting — the rule `makeResidue` already
    /// holds for spend no repository claims. A model whose split is *only*
    /// unattributed gets no row at all, since a row reading `unattributed
    /// 100%` is an absent reading dressed as one.
    ///
    /// **Uncapped, and the pills' own fold is not an argument for one.** They
    /// fold at four because four is what 312 pt holds *side by side* —
    /// measured 2026-09-22, five pills want 344 pt — and these rows are
    /// stacked, so width bounds nothing here. What bounds them is that a
    /// vendor ships a handful of models where a user touches any number of
    /// repositories, which is why `By project` folds and this does not:
    /// measured 2026-09-22 across 90 days of this archive, the widest 7-day
    /// window held 3 models on Claude Code and 2 on Codex. A cap here would
    /// drop a model's row without saying so, on the one block whose whole
    /// subject is which model ran at what.
    static func makeEffort(_ splits: [EffortSplit], provider: String) -> [EffortRow] {
        guard !splits.isEmpty else { return [] }
        let weight = effortWeight(splits)
        var byModel: [String: [EffortSplit]] = [:]
        for split in splits { byModel[split.model, default: []].append(split) }
        var models: [(model: String, splits: [EffortSplit], weight: Double)] = []
        for (model, splits) in byModel {
            let total: Double = splits.reduce(0) { $0 + weight($1) }
            let named = splits.filter { $0.effort != nil }
            guard total > 0, !named.isEmpty else { continue }
            var ordered = named.sorted { left, right in
                let a = weight(left)
                let b = weight(right)
                return a == b ? (left.effort ?? "") < (right.effort ?? "") : a > b
            }
            ordered.append(contentsOf: splits.filter { $0.effort == nil })
            models.append((model: model, splits: ordered, weight: total))
        }
        models.sort { $0.weight == $1.weight ? $0.model < $1.model : $0.weight > $1.weight }
        return models.map { model, ordered, total in
            let segments: [EffortSegment] = ordered.map {
                let share = weight($0) / total
                return EffortSegment(
                    effort: $0.effort, share: share,
                    label: UsageFormat.effortShare($0.effort, share: share))
            }
            let detail: [(effort: String?, cost: String, turns: Int)] = ordered.map {
                (effort: $0.effort, cost: UsageFormat.cost($0.cost), turns: $0.turns)
            }
            return EffortRow(
                id: model,
                name: UsageFormat.modelName(model, on: provider),
                detail: UsageFormat.effortDetail(detail),
                segments: segments,
                total: UsageFormat.effortTotal(
                    cost: UsageFormat.cost(ordered.reduce(Decimal(0)) { $0 + $1.cost }),
                    turns: ordered.reduce(0) { $0 + $1.turns }))
        }
    }

    /// How one pair weighs in a share: its money, or its tokens as soon as any
    /// pair in the window has tokens and no cost, which is `makeModels`' rule
    /// for `makeModels`' reason.
    private static func effortWeight(_ splits: [EffortSplit]) -> (EffortSplit) -> Double {
        let unpriced = splits.contains { $0.cost == 0 && $0.tokens > 0 }
        return { split in
            unpriced
                ? Double(split.tokens) : NSDecimalNumber(decimal: split.cost).doubleValue
        }
    }

    /// The share at which a model's leading effort is the whole of its reading.
    ///
    /// Measured 2026-09-22 over 14 days of this machine: `claude-opus-5` ran
    /// `xhigh 99%` and `claude-fable-5-1` `xhigh 100%`, while the lowest
    /// informative lead was `gpt-6-astra`'s `medium 49%`.
    private static let effortWholeShare = 0.9

    /// The one line the provider page gives the effort reading.
    ///
    /// **A row rather than a block**, because it answers how a week was worked
    /// on a page about what an account is doing now, and the block it replaced
    /// cost that page a heading and two lines a model for a question most
    /// visits do not ask. The row names the provider's leading effort over the
    /// window and its share of the spend — summed across this provider's
    /// models only, which share one vendor's vocabulary, and never across
    /// providers.
    ///
    /// **It opens the page only when the page has more to say.** On Claude the
    /// reading is usually one word per model, and a door onto a page of full
    /// bars would be a click that answers what the row already did. So the row
    /// is a door exactly when some model either leads on another effort or
    /// leads on this one by less than `effortWholeShare`.
    static func effortSummary(_ splits: [EffortSplit], provider: String) -> EffortSummary? {
        let rows = makeEffort(splits, provider: provider)
        guard !rows.isEmpty else { return nil }
        let weight = effortWeight(splits)
        var byEffort: [String: Double] = [:]
        var total = 0.0
        for split in splits {
            let part = weight(split)
            total += part
            if let effort = split.effort { byEffort[effort, default: 0] += part }
        }
        let lead = byEffort.max {
            $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
        }
        guard total > 0, let lead else { return nil }
        let opens = rows.contains { row in
            guard let first = row.segments.first else { return false }
            return first.effort != lead.key || first.share < effortWholeShare
        }
        return EffortSummary(
            lead: UsageFormat.effortShare(lead.key, share: lead.value / total), opens: opens)
    }

    /// The window's splits: the archived days the strip draws, plus today off
    /// the frame.
    ///
    /// Today is added rather than read back, for the strip's own reason — the
    /// day file is written on the tail's throttle while the frame moves as
    /// events land, so taking it from disk would put a reading under the bars
    /// that disagrees with the bar above it.
    ///
    /// `covered` counts days that **named** an effort, not days the archive
    /// holds. A day can carry its tokens and no effort — one whose logs the
    /// CLI has since pruned, or one the archive refuses to rewrite because
    /// the re-derivation lost a project to a worktree deleted since. Measured
    /// 2026-09-22 on this machine, 4 of 49 archived days. Counting those as
    /// covered would put `7 days` over a reading that answers for four.
    static func effortWindow(
        series: [UsageHistoryDaySummary], today: [EffortSplit], now: Date = Date(),
        calendar: Calendar = .current
    ) -> EffortWindow {
        let startOfToday = calendar.startOfDay(for: now)
        let start =
            calendar.date(byAdding: .day, value: -(dayStripDays - 1), to: startOfToday)
            ?? startOfToday
        let archived = series.filter {
            $0.day >= start && calendar.startOfDay(for: $0.day) < startOfToday
        }
        let named = { (splits: [EffortSplit]) in splits.contains { $0.effort != nil } }
        return EffortWindow(
            splits: archived.flatMap(\.effort).summed(with: today),
            covered: archived.count { named($0.effort) } + (named(today) ? 1 : 0))
    }

    /// What the day spent outside every repository, or nil when there is none
    /// of it.
    ///
    /// Summed off the slices rather than off the combined list, because the
    /// split is per provider and the combined list is the one place that
    /// answer has already been summed away. The two agree on the total by
    /// construction — `combinedProjects` is these same rows added up.
    ///
    /// Both halves or neither. A provider republishes its project split on
    /// every read of its day where the totals beside it only move on an emit,
    /// so a coalesced emit can leave the rows describing a later instant than
    /// the header — and a remainder taken across the two has no sign worth
    /// trusting, since cache reads are most of the tokens and the least of the
    /// money. A reading that disagrees with itself is owed no line rather than
    /// a negative one.
    ///
    /// `split` is false on a provider's own page for the reason its rows carry
    /// no marks: the page's title has already named the CLI, and a mark per
    /// line would say it again.
    private static func makeResidue(_ slices: [ProviderSlice], split: Bool) -> ProjectsResidue? {
        let totalTokens = slices.reduce(0) { $0 + $1.tokens }
        let totalCost = slices.reduce(Decimal(0)) { $0 + $1.cost }
        let namedTokens = slices.reduce(0) { $0 + $1.projects.reduce(0) { $0 + $1.tokens } }
        let namedCost = slices.reduce(Decimal(0)) {
            $0 + $1.projects.reduce(Decimal(0)) { $0 + $1.cost }
        }
        guard totalTokens > namedTokens, totalCost >= namedCost else { return nil }
        let unnamed = slices.compactMap { slice -> ProviderCost? in
            let named = slice.projects.reduce(Decimal(0)) { $0 + $1.cost }
            guard slice.cost > named else { return nil }
            return ProviderCost(id: slice.id, cost: UsageFormat.cost(slice.cost - named))
        }
        return ProjectsResidue(
            tokens: UsageFormat.tokens(totalTokens - namedTokens),
            cost: UsageFormat.cost(totalCost - namedCost),
            providers: split ? unnamed : []
        )
    }

    /// One row's split, in the order the panel draws providers in rather than
    /// by what each spent.
    ///
    /// A fixed order is what lets the marks and the bar be read down a column:
    /// ordering each row by its own dearest provider puts Claude's tint on the
    /// left of one row and on the right of the next, and a reader comparing
    /// two rows has to re-read the marks to know which way round they are.
    private static func providerShares(
        _ costs: [String: Decimal], share: (Decimal) -> Double
    ) -> [ProviderShare] {
        costs
            .map { ProviderShare(id: $0.key, share: share($0.value)) }
            .sorted {
                (FrameBuilder.providerSortOrder($0.id), $0.id)
                    < (FrameBuilder.providerSortOrder($1.id), $1.id)
            }
    }

    /// What each provider spent on each path, which is the half
    /// `FrameBuilder.combinedProjects` sums away.
    private static func contributors(_ slices: [ProviderSlice]) -> [String: [String: Decimal]] {
        var out: [String: [String: Decimal]] = [:]
        for slice in slices {
            for project in slice.projects {
                out[project.path, default: [:]][slice.id, default: 0] += project.cost
            }
        }
        return out
    }

    private static let foldedProjectRowID = "sissy.projects.rest"
}
