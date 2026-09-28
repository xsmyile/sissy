import SwiftUI

/// The Disk tab's "Taking room" platter: each regenerable cache that takes
/// room, what it would free, and a `Clean…` that asks before it removes.
///
/// **A press proposes and the confirmation commits**, on the rules the Codex
/// reset keeps: the question is asked in the page itself, it names the
/// directory and the size, Escape cancels, and nothing is the default action,
/// so a removal is reached by aiming at it and never by a return key pressed
/// at a panel. It says *permanently* because nothing goes to the Trash: these
/// are caches their tools rebuild, and a Trash holding 9 GB of them frees
/// nothing until it is emptied.
///
/// Sizing takes seconds, so the rows land one at a time under a sizing line
/// rather than holding the page; a cache that is not there or takes no room
/// has no row, and a platter with none is not drawn once sizing is done. The
/// sizing is started by `PanelDisk`, whose page is always drawn, rather than
/// here, since this platter can have no view to appear.
struct DiskCleanupPlatter: View {
    let cleanup: DiskCleanupModel

    /// The cache whose removal the page is asking about.
    @State private var confirming: CleanupTarget?

    private static let rowSize: CGFloat = 12
    private static let captionSize: CGFloat = 11
    private static let rowSpacing: CGFloat = 7

    var body: some View {
        if !cleanup.measured || !cleanup.rows.isEmpty {
            PanelGroup {
                SectionLabel(text: DiskCleanupCopy.section)
            } content: {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(cleanup.rows) { target in
                        row(target)
                    }
                    if !cleanup.measured {
                        progress(DiskCleanupCopy.sizing)
                    }
                }
            }
        }
    }

    private func row(_ target: CleanupTarget) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(target.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(UsageFormat.storage(UInt64(cleanup.sizes[target] ?? 0)))
                    .monospacedDigit()
                    .lineLimit(1)
                if cleanup.cleaning == nil, confirming != target, (cleanup.sizes[target] ?? 0) > 0 {
                    Button(DiskCleanupCopy.clean) { confirming = target }
                        .controlSize(.small)
                        .help(DiskCleanupCopy.cleanHelp(target))
                }
            }
            .font(.system(size: Self.rowSize))
            if confirming == target, cleanup.cleaning == nil {
                confirmation(target)
            }
            if cleanup.cleaning == target {
                progress(DiskCleanupCopy.cleaning)
            } else if let outcome = cleanup.outcomes[target] {
                caption(DiskCleanupCopy.outcome(outcome, target: target))
            }
        }
    }

    private func confirmation(_ target: CleanupTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DiskCleanupCopy.confirmTitle(target))
                .font(.system(size: 12, weight: .medium))
            caption(DiskCleanupCopy.confirmBody(target, bytes: cleanup.sizes[target] ?? 0))
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(DiskCleanupCopy.confirmCancel) { confirming = nil }
                    .keyboardShortcut(.cancelAction)
                Button(DiskCleanupCopy.confirmAction) {
                    confirming = nil
                    cleanup.clean(target)
                }
            }
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            caption(text)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Self.captionSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What the "Taking room" platter says, from a row's button to what a removal
/// did.
///
/// The outcome says `up to` for the confirmation's reason, and it is its own
/// sentence for each way a removal can end short,
/// because each asks something different: an entry another user owns is left
/// on purpose, and one the filesystem refused is worth knowing about.
enum DiskCleanupCopy {
    static let section = "Taking room"
    static let sizing = "Sizing caches…"
    static let clean = "Clean…"
    static let cleaning = "Removing…"
    static let confirmAction = "Clean"
    static let confirmCancel = "Cancel"

    static func cleanHelp(_ target: CleanupTarget) -> String {
        "Permanently remove what \(target.displayPath) holds"
    }

    static func confirmTitle(_ target: CleanupTarget) -> String { "Clean \(target.name)?" }

    /// The directory, the size and what rebuilds it. `up to` because the size
    /// counts blocks APFS clones share with files outside the cache.
    static func confirmBody(_ target: CleanupTarget, bytes: Int64) -> String {
        let size = UsageFormat.storage(UInt64(max(0, bytes)))
        return "Permanently removes everything inside \(target.displayPath), up to \(size). "
            + rebuilds(target)
    }

    static func rebuilds(_ target: CleanupTarget) -> String {
        switch target {
        case .derivedData: "Xcode rebuilds it on the next build."
        case .npm: "npm downloads packages again as it needs them."
        case .uv: "uv downloads packages again as it needs them."
        case .deviceSupport: "Xcode copies it again from each device the next time it connects."
        }
    }

    static func outcome(_ outcome: DiskCleanupModel.Outcome, target: CleanupTarget) -> String {
        let report: CleanupReport
        switch outcome.result {
        case .success(let counted): report = counted
        case .failure(let refusal): return refused(refusal, target: target)
        }
        var parts = ["Freed up to \(UsageFormat.storage(UInt64(max(0, report.removedBytes))))"]
        if report.failed > 0 { parts.append("\(items(report.failed)) could not be removed") }
        if report.skipped > 0 {
            parts.append("\(items(report.skipped)) left as another user's or another volume's")
        }
        return parts.joined(separator: " · ")
    }

    static func refused(_ refusal: CleanupRefusal, target: CleanupTarget) -> String {
        switch refusal {
        case .unsafeRoot:
            "Nothing was removed: \(target.displayPath) could not be opened safely."
        case .walkInProgress:
            "Nothing was removed: Sissy was still reading \(target.displayPath)."
        case .toolRunning(let tool): toolAtWork(tool)
        }
    }

    static func toolAtWork(_ tool: CleanupTool) -> String {
        "\(tool.name) is at work on it · try again once it finishes"
    }

    private static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }
}
