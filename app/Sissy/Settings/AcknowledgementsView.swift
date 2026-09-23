import AppKit
import SwiftUI

/// The bundled copy of the repository's `THIRD-PARTY-NOTICES.md`.
///
/// It ships as an app resource, not only as a file on GitHub, because Sparkle
/// is embedded in the app and the BSD terms among its licences ask for the
/// notice to travel with the binary. A missing resource is a packaging mistake
/// rather than a runtime condition, so the sheet falls back to the GitHub copy
/// and `AboutTests` guards the bundling.
enum ThirdPartyNotices {
    static let resourceName = "THIRD-PARTY-NOTICES"
    static let resourceExtension = "md"

    static func text(in bundle: Bundle = .main) -> String? {
        guard
            let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// About's "Acknowledgements" sheet: what Sissy owes whom, then the licence
/// text of the one thing it embeds. The credits are the short answer and the
/// notices the long one, which is why the sheet leads with the first and
/// scrolls the second.
///
/// The list mixes the two kinds on purpose: Sparkle ships inside Sissy, the
/// rest are projects Sissy reads from, and each is owed a credit whether or
/// not a licence demands one.
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
            name: "Sparkle",
            detail: "Checks for, downloads and installs Sissy's updates. Ships inside Sissy under MIT.",
            url: URL(string: "https://github.com/sparkle-project/Sparkle")!
        ),
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

    private static let noticesURL = URL(
        string: "https://github.com/xsmyile/sissy/blob/master/THIRD-PARTY-NOTICES.md")!

    /// Read once per process rather than per body evaluation: the file is a
    /// fixed app resource that cannot change while the app runs.
    private static let notices: String? = ThirdPartyNotices.text()

    private static let sheetWidth: CGFloat = 520
    /// Tall enough for the credits and a pane of the licence text under them;
    /// the text scrolls rather than sizing the sheet.
    private static let sheetHeight: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            creditList
            Divider()
            noticeText
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
    private var noticeText: some View {
        if let notices = Self.notices {
            ScrollView {
                Text(verbatim: notices)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Third-party notices")
                    .font(.callout.weight(.semibold))
                Button("Read them on GitHub") { NSWorkspace.shared.open(Self.noticesURL) }
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
    }

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
