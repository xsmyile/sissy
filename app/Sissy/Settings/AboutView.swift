import AppKit
import SwiftUI

/// About tab: identity, version, and the links worth having.
/// Reads `CFBundleShortVersionString`, `CFBundleVersion` and
/// `NSHumanReadableCopyright` from the running bundle so the page stays
/// accurate without any extra build wiring.
///
/// The controls descend in weight rather than sharing one: a `.glassProminent`
/// call to action, a pair of `.glass` buttons for the two things a user does
/// *with* Sissy when something is wrong, then the destinations as links, then
/// the copyright. It was one prominent button over four `.link`s on two rows,
/// which gave `Copy diagnostics` — the only one of the five that opens nothing
/// — the same blue as the four that do.
struct AboutView: View {
    let model: SissyModel

    private static let githubURL = URL(string: "https://github.com/xsmyile/sissy")!
    private static let issuesURL = URL(string: "https://github.com/xsmyile/sissy/issues/new")!
    /// The author's own site rather than their GitHub profile, which the star
    /// button already reaches: `github.com/xsmyile/sissy` carries its owner in
    /// its own breadcrumb, so a second link to `github.com/xsmyile` was one
    /// destination spelled twice. The label is the bare domain, because a link
    /// that leaves the app should say where it goes, and the name it used to
    /// carry is on the copyright line below it either way.
    private static let siteURL = URL(string: "https://smyile.com")!

    /// What the page says Sissy is, in the words the README opens with. It
    /// described the spend of two CLIs until the Forge module landed and made
    /// that one module's description rather than the app's.
    private static let tagline = "The numbers you keep checking, in the macOS menu bar."

    private static let copyTitle = "Copy diagnostics"
    private static let copiedTitle = "Copied"

    /// Smaller than the 104 pt it was, with its halo brought in to match, which
    /// is what bought the update check under the version its room.
    /// Measured 2026-09-18 against a harness reproducing this layout at the
    /// tab's own 560 pt: the page this replaced came to 457.0 pt of
    /// `SettingsRootView.maxContentHeight`'s 600, this one comes to 412.0, and
    /// the same page carrying an update card to 523.0.
    private static let iconSize: CGFloat = 96
    private static let haloSize: CGFloat = 120

    private static let starGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.84, blue: 0.25), Color(red: 0.98, green: 0.62, blue: 0.11)],
        startPoint: .top,
        endPoint: .bottom
    )

    private static let haloGradient = AngularGradient(
        colors: [
            Color(red: 0.85, green: 0.47, blue: 0.34),
            Color(red: 0.98, green: 0.75, blue: 0.35),
            Color(red: 0.36, green: 0.72, blue: 0.60),
            Color(red: 0.85, green: 0.47, blue: 0.34),
        ],
        center: .center
    )

    /// How long "Copy diagnostics" says "Copied" before it offers to do it
    /// again. Long enough to be read, short enough that the button is back
    /// before anyone reaches for it twice.
    private static let copyFeedbackDuration: Duration = .seconds(2)

    @State private var starBounce = 0
    @State private var didCopyDiagnostics = false
    @State private var showsAcknowledgements = false

    var body: some View {
        VStack(spacing: 20) {
            icon
            identity
            actions
            credit
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .sheet(isPresented: $showsAcknowledgements) { AcknowledgementsView() }
        .task(id: didCopyDiagnostics) {
            guard didCopyDiagnostics else { return }
            do {
                try await Task.sleep(for: Self.copyFeedbackDuration)
            } catch {
                return
            }
            didCopyDiagnostics = false
        }
    }

    private var identity: some View {
        VStack(spacing: 6) {
            Text("Sissy")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if model.updates.isRunning {
                Button(UpdateController.menuTitle(pendingVersion: model.updates.pendingVersion)) {
                    model.updates.checkForUpdates()
                }
                .buttonStyle(.link)
                .font(.callout)
                .disabled(!model.updates.canCheckForUpdates)
            }
            Text(Self.tagline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            starButton

            HStack(spacing: 10) {
                Button("Report an issue") {
                    NSWorkspace.shared.open(Self.issuesURL)
                }
                copyDiagnosticsButton
            }
            .buttonStyle(.glass)
        }
    }

    private var starButton: some View {
        Button {
            NSWorkspace.shared.open(Self.githubURL)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundStyle(Self.starGradient)
                    .symbolEffect(.bounce, value: starBounce)
                Text("Star Sissy on GitHub")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .onHover { hovering in
            if hovering { starBounce += 1 }
        }
    }

    /// The confirmation is laid over a hidden copy of the longer title, so the
    /// button keeps one width across both. A bordered button that shrinks to
    /// "Copied" drags the pair beside it sideways under the pointer, which the
    /// link this replaced got away with only because a link has no edges.
    private var copyDiagnosticsButton: some View {
        Button {
            DiagnosticsReport.copyToClipboard(model: model)
            didCopyDiagnostics = true
        } label: {
            Text(Self.copyTitle)
                .hidden()
                .overlay {
                    Text(didCopyDiagnostics ? Self.copiedTitle : Self.copyTitle)
                }
        }
        .accessibilityLabel(Self.copyTitle)
    }

    private var credit: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button("smyile.com") {
                    NSWorkspace.shared.open(Self.siteURL)
                }
                .buttonStyle(.link)

                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)

                Button("Acknowledgements") { showsAcknowledgements = true }
                    .buttonStyle(.link)
            }
            .font(.callout)

            Text(Bundle.main.humanReadableCopyright)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    private var icon: some View {
        ZStack {
            Circle()
                .fill(Self.haloGradient)
                .frame(width: Self.haloSize, height: Self.haloSize)
                .blur(radius: 28)
                .opacity(0.55)

            appIcon
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
        .accessibilityHidden(true)
    }

    private var appIcon: some View {
        // `NSImage.applicationIconName` resolves to the running app's icon
        // without depending on a specific asset-catalog name, so this keeps
        // working if the catalog entry is renamed later.
        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable()
            .interpolation(.high)
    }
}
