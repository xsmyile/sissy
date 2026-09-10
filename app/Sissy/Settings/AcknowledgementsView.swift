import AppKit
import SwiftUI

/// The bundled copy of the repository's `THIRD-PARTY-NOTICES.md`.
///
/// It ships as an app resource, not just as a file on GitHub, because
/// SwiftNIO is compiled into `sissy-serverd` and Apache-2.0 asks for its
/// NOTICE to travel with the binary. A missing resource is a packaging
/// mistake rather than a runtime condition, so the sheet falls back to the
/// GitHub copy and `AcknowledgementsTests` guards the bundling.
struct ThirdPartyNotices {
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

/// About's "Acknowledgements" sheet: what Sissy owes whom, then the license
/// text itself. The credits are the short answer and the notices are the
/// long one, which is why the sheet leads with the first and scrolls the
/// second.
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
            name: "SwiftNIO",
            detail: "The daemon's HTTP and WebSocket server. Ships inside Sissy under Apache 2.0.",
            url: URL(string: "https://github.com/apple/swift-nio")!
        ),
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

    private static let noticesURL = URL(
        string: "https://github.com/xsmyile/sissy/blob/master/THIRD-PARTY-NOTICES.md")!

    /// Read once per process rather than per body evaluation: the file is a
    /// fixed 25 KB of app resource, and a `static let` is the cheapest place
    /// for something that can never change while the app runs.
    private static let notices: String? = ThirdPartyNotices.text()

    private static let sheetWidth: CGFloat = 520
    private static let sheetHeight: CGFloat = 470

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
            Button("Open on GitHub") { NSWorkspace.shared.open(Self.noticesURL) }
                .buttonStyle(.link)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
