import AppKit
import SwiftUI

/// About's "Acknowledgements" sheet: what Sissy owes whom.
///
/// It used to carry the licence text too, because SwiftNIO shipped compiled
/// into the daemon and Apache-2.0 asks its NOTICE to travel with the binary.
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
            url: URL(string: "https://github.com/ryoppippi/ccusage")!
        ),
        Credit(
            name: "LiteLLM",
            detail:
                "The model price table the daemon fetches at runtime, which is what ccusage prices from too.",
            url: URL(string: "https://github.com/BerriAI/litellm")!
        ),
    ]

    private static let creditsURL = URL(
        string: "https://github.com/xsmyile/sissy/blob/master/CREDITS.md")!

    private static let sheetWidth: CGFloat = 520
    /// Shorter than it was: the licence text it used to scroll is gone, and
    /// a sheet sized for it would be mostly empty space.
    private static let sheetHeight: CGFloat = 280

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
