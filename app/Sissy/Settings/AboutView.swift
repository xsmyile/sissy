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
///
/// Updates are a band of their own under a divider rather than one more tier
/// of that stack: the page above is about Sissy, the band about this copy of
/// it, and stacked in one column the switches read as one more button.
struct AboutView: View {
    let model: SissyModel

    private static let githubURL = URL(string: "https://github.com/xsmyile/sissy")!
    private static let issuesURL = URL(string: "https://github.com/xsmyile/sissy/issues/new")!
    /// The author's own site rather than their GitHub profile, which the star
    /// button already reaches: `github.com/xsmyile/sissy` carries its owner in
    /// its own breadcrumb, so a second link to `github.com/xsmyile` was one
    /// destination spelled twice. It rides the author's name on the copyright
    /// line, which already says who, and the tooltip says where: a bare
    /// `smyile.com` of its own named a domain and nobody behind it.
    private static let siteURL = URL(string: "https://smyile.com")!

    /// The name in `NSHumanReadableCopyright` that carries `siteURL`.
    static let copyrightHolder = "Smyile"

    /// What the page says Sissy is, in the words the README opens with. It
    /// described the spend of two CLIs until the Forge module landed and made
    /// that one module's description rather than the app's.
    private static let tagline = "The numbers you keep checking, in the macOS menu bar."

    /// The room above and below the divider, and above the copyright line
    /// that closes the page.
    private static let bandSpacing: CGFloat = 24

    private static let devBuildStatus = "Off in development builds"

    private static let copyTitle = "Copy diagnostics"
    private static let copiedTitle = "Copied"

    /// Smaller than the 104 pt it was, with its halo brought in to match, which
    /// is what bought the update band its room under
    /// `SettingsRootView.maxContentHeight`.
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
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                icon
                identity
                actions
                acknowledgementsLink
            }
            Divider()
                .padding(.vertical, Self.bandSpacing)
            updates
            copyrightLine
                .padding(.top, Self.bandSpacing)
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
            Text(Self.tagline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// The switches on the left and the check on the right, with when it last
    /// ran under it. The two switches are Sparkle's own settings, read and
    /// written through `UpdateController`, which keeps no copy of them.
    /// Checks are on by default and asked about nowhere: the Info.plist
    /// declares them, which is what keeps the first launches silent.
    /// Installs are off, and the update alert offers the same switch beside
    /// the version it is about. Sparkle allows them only while checks are on.
    ///
    /// A development build draws the band with its controls off rather than
    /// leaving it out: the updater never runs there, and hiding the band made
    /// a notarized build the only way to see the page as it ships.
    private var updates: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Check for updates automatically", isOn: updateChecksBinding)
                    .disabled(!model.updates.isRunning)
                Toggle("Install updates automatically", isOn: updateInstallsBinding)
                    .disabled(!model.updates.allowsAutomaticInstalls)
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                if let feedHost = model.updates.feedHost {
                    checkButton.help("Reads the update feed at \(feedHost).")
                } else {
                    checkButton
                }

                if let status = updateStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var updateStatus: String? {
        guard !model.updates.isDevBuild else { return Self.devBuildStatus }
        return model.updates.lastCheck.map {
            "Last checked \($0.formatted(.relative(presentation: .named)))"
        }
    }

    private var checkButton: some View {
        Button(UpdateController.menuTitle(pendingVersion: model.updates.pendingVersion)) {
            model.updates.checkForUpdates()
        }
        .buttonStyle(.glass)
        .disabled(!model.updates.canCheckForUpdates)
    }

    private var updateChecksBinding: Binding<Bool> {
        Binding(
            get: { model.updates.automaticallyChecks },
            set: { model.updates.setAutomaticallyChecks($0) }
        )
    }

    private var updateInstallsBinding: Binding<Bool> {
        Binding(
            get: { model.updates.automaticallyInstalls },
            set: { model.updates.setAutomaticallyInstalls($0) }
        )
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

    private var acknowledgementsLink: some View {
        Button("Acknowledgements") { showsAcknowledgements = true }
            .buttonStyle(.link)
            .font(.callout)
    }

    /// The last line of the page and nothing beside it. The grey is the line's
    /// own, so the author's name keeps the link colour its run carries; a
    /// `.link` button in the same row took the grey as well and read as text.
    private var copyrightLine: some View {
        Text(copyright)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .help(Self.siteURL.absoluteString)
    }

    private var copyright: AttributedString {
        var line = AttributedString(Bundle.main.humanReadableCopyright)
        if let holder = line.range(of: Self.copyrightHolder) {
            line[holder].link = Self.siteURL
        }
        return line
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
