import SwiftUI

/// Which repositories commit under a name their forge does not expect.
///
/// **A page of the panel rather than a tab of Settings.** Settings is where
/// Sissy's switches are — every row in it is a `LabeledContent` carrying a
/// control and its caption, and there is no list anywhere in the window — and
/// this is a reading, with no lever on it at all. Every other reading Sissy
/// takes is in this panel. The height settles it too: Settings has a 600 pt
/// budget and a tab that habitually needs more is a tab that should have
/// split, where 23 repositories at two lines each go past it on the first day.
/// A page is bounded by `PanelMetrics.maxHeight(on:)` and the panel's own
/// scroll view, which is what replaced every per-section ceiling.
///
/// **Only the findings are on the page; the rest is one click behind a
/// disclosure.** The rows that agree are the ones nobody opened this page for,
/// and a page whose single wrong repository sorts to position nineteen has to
/// be read rather than glanced at. Listing them all cost more than the order:
/// measured 2026-09-17 on 23 repositories, the page came to ~975 pt against
/// the 690.5 pt of the tallest page before it, so it filled a 14" screen top
/// to bottom and the panel's own ceiling was the only thing stopping it.
/// Collapsed, the same 23 measure **142 pt**, and 217 pt with a finding on
/// them. That
/// is the second half of the rule a section may be bounded under — *a page
/// being one click away from several times its own height* — which is what
/// the status tree's collapsed groups already do for 34 OpenAI components, and
/// not the half that was removed, which was bounding a section to keep the
/// popover on the display.
///
/// Collapsed it still answers the question: one sentence saying whether
/// anything is wrong, and the count of what was read. The repository a project
/// row was clicked for stays out of the fold, or the click would answer about
/// everything except the row it came from.
///
/// **Nothing here writes anything.** The correction is a command on the
/// clipboard, which is why this page needs no preview, no backup, no refusal
/// of stale writes and no undo — and why it asks for no permission and takes
/// no exception to the rule that nothing Sissy does to the machine outlives
/// it. It is also offered only where it would work: a repository wearing the
/// wrong name because of a global rule has nothing of its own to unset.
struct PanelIdentities: View {
    let rows: [UsagePanelSnapshot.IdentityRow]
    let focus: String?

    /// Local to the page, so leaving it and coming back asks the question
    /// again rather than answering the one before last — the same arrangement
    /// the status tree's groups have.
    @State private var showsAll = false

    private static let labelSpacing: CGFloat = 10
    private static let rowSpacing: CGFloat = 12

    /// What the page shows without being asked: anything that is not a plain
    /// agreement, plus the repository it was opened about.
    private var standing: [UsagePanelSnapshot.IdentityRow] {
        rows.filter { $0.mark != .agrees || $0.id == focus }
    }

    private var shown: [UsagePanelSnapshot.IdentityRow] { showsAll ? rows : standing }

    /// The sentence that answers for the whole list, where the list has
    /// anything to answer for. Nothing read is not everything agreeing: a
    /// project row offers this page before the first sweep has landed, and on
    /// a Mac with no git to read with it never lands.
    private var verdict: String? {
        guard !rows.isEmpty, standing.isEmpty, !showsAll else { return nil }
        return "Every repository commits under the name its forge expects."
    }

    /// The repository the page was opened about, when no reading of it has
    /// been taken yet — so the page answers the row it came from rather than
    /// only the ones around it.
    private var unreadFocus: String? {
        guard let focus, !rows.contains(where: { $0.id == focus }) else { return nil }
        return focus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            HStack(spacing: 6) {
                SectionLabel(text: "Commit identity")
                Spacer(minLength: 0)
                Text(UsageFormat.identityFooter(checked: rows.count))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let verdict {
                Text(verdict)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let unread = UsageFormat.identityUnread(focus: unreadFocus, anyRead: !rows.isEmpty) {
                Text(unread)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(shown) { row in
                        IdentityRowView(row: row, isFocused: row.id == focus)
                    }
                }
            }
            if rows.count > standing.count {
                disclosure
            }
            footer
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    private var disclosure: some View {
        Button {
            showsAll.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showsAll ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(
                    showsAll
                        ? "Hide the rest" : UsageFormat.identityDisclosure(all: rows.count))
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The boundary of the reading.
    ///
    /// Not a disclaimer: `-c user.email=…`, `--author` and `GIT_AUTHOR_EMAIL`
    /// all beat every file git resolves, and a page that claimed to answer for
    /// a commit without saying so would be claiming more than it measured.
    ///
    /// What was read is on the label row instead. It qualifies the heading
    /// rather than the caveat — the same place the provider page puts the
    /// window its limits block is showing — and under the fold it sat below a
    /// control that hides most of what it counted.
    private var footer: some View {
        Text("A commit made with -c, --author or GIT_AUTHOR_EMAIL set is not covered.")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}

/// One repository's reading.
///
/// The mark is a column of its own so every name starts at the same x — the
/// rule the project bars were given a line of their own to keep — and the
/// detail lines hang under the name rather than beside it, because an address
/// is longer than any column a 340 pt panel can spare.
private struct IdentityRowView: View {
    let row: UsagePanelSnapshot.IdentityRow
    let isFocused: Bool

    private static let markWidth: CGFloat = 13
    private static let detailSpacing: CGFloat = 3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            mark
                .frame(width: Self.markWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: Self.detailSpacing) {
                Text(row.name)
                    .font(.system(size: 12, weight: isFocused ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.author)
                    .font(.system(size: 11))
                    .foregroundStyle(row.mark == .unexpected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let expectation = row.expectation {
                    Text(expectation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let origin = row.origin {
                    Text(origin)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let fix = row.fix {
                    Button("Copy the fix") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fix, forType: .string)
                    }
                    .controlSize(.small)
                    .help(fix)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .help(row.path)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.path, forType: .string)
            }
        }
    }

    /// A tick, a warning, or a dash. The dash is the panel's own rule for a
    /// reading that was not taken: an empty mark would be a verdict, and there
    /// is none.
    @ViewBuilder
    private var mark: some View {
        switch row.mark {
        case .agrees:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        case .unexpected:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .unjudged:
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}
