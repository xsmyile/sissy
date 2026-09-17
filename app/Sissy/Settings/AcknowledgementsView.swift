import AppKit
import SwiftUI

/// About's "Acknowledgements" sheet: what Sissy owes whom.
///
/// It used to carry the licence text too, because SwiftNIO shipped compiled
/// into the binary and Apache-2.0 asks its NOTICE to travel with it.
/// No third-party code ships in Sissy any more, so there is nothing left to
/// reproduce — only the projects Sissy reads from, which are owed a credit
/// whether or not a licence demands one.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Credit: Identifiable {
        let name: String
        let detail: String
        let url: URL

        var id: String { name }
    }

    private static let credits: [Credit] = [
        Credit(
            name: "ccusage",
            detail:
                "The cost oracle Sissy measures itself against, and where it learned to read the CLIs' logs.",
            url: URL(string: "https://github.com/ccusage/ccusage")!
        ),
        Credit(
            name: "LiteLLM",
            detail:
                "The model price table Sissy fetches at runtime, which is what ccusage prices from too.",
            url: URL(string: "https://github.com/BerriAI/litellm")!
        ),
        Credit(
            name: "Simple Icons",
            detail:
                "Where the GitHub and GitLab marks on the panel's repository card come from, released under CC0.",
            url: URL(string: "https://github.com/simple-icons/simple-icons")!
        ),
    ]

    /// Not a credit, and deliberately not in the list above: that list is for
    /// projects, and this is about four pictures. The marks identify which CLI
    /// a row is about and where a repository is pushed, which is nominative
    /// use; saying so out loud is cheaper than leaving a reader to wonder
    /// whether Sissy is something one of those vendors made. Simple Icons is
    /// credited above for two of the four drawings, which is a separate thing
    /// from the marks they draw: CC0 covers a drawing and never a trademark.
    private static let trademarkNotice =
        "The Claude and OpenAI marks identify which CLI a row is about, and the GitHub and "
        + "GitLab marks where a repository is pushed. They are the trademarks of Anthropic, "
        + "OpenAI, GitHub and GitLab, who have nothing to do with Sissy."

    private static let creditsURL = URL(
        string: "https://github.com/xsmyile/sissy/blob/master/CREDITS.md")!

    private static let sheetWidth: CGFloat = 520
    /// Shorter than it was: the licence text it used to scroll is gone, and
    /// a sheet sized for it would be mostly empty space.
    private static let sheetHeight: CGFloat = 330

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            creditList
            Divider()
            footer
        }
        .frame(width: Self.sheetWidth, height: Self.sheetHeight)
    }

    private var creditList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Acknowledgements")
                .font(.headline)

            ForEach(Self.credits) { credit in
                VStack(alignment: .leading, spacing: 2) {
                    Button(credit.name) { NSWorkspace.shared.open(credit.url) }
                        .buttonStyle(.link)
                        .font(.callout.weight(.semibold))
                    Text(credit.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(Self.trademarkNotice)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Open on GitHub") { NSWorkspace.shared.open(Self.creditsURL) }
                .buttonStyle(.link)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
