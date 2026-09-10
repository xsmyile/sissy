import AppKit
import SwiftUI

/// About tab: identity, version, and the two links worth having.
/// Reads `CFBundleShortVersionString` + `CFBundleVersion` from the running
/// bundle so the page stays accurate without any extra build wiring.
struct AboutView: View {
    private static let githubURL = URL(string: "https://github.com/xsmyile/sissy")!
    private static let issuesURL = URL(string: "https://github.com/xsmyile/sissy/issues/new")!

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

    @State private var starBounce = 0

    var body: some View {
        VStack(spacing: 22) {
            icon

            VStack(spacing: 6) {
                Text("Sissy")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("\(Self.shortVersion) (\(Self.buildNumber))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("Tracks Claude Code and Codex spend\nfrom your Mac menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            VStack(spacing: 10) {
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

                Button("Report an issue") {
                    NSWorkspace.shared.open(Self.issuesURL)
                }
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 34)
    }

    private var icon: some View {
        ZStack {
            Circle()
                .fill(Self.haloGradient)
                .frame(width: 132, height: 132)
                .blur(radius: 28)
                .opacity(0.55)

            appIcon
                .frame(width: 104, height: 104)
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

    private static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "..."
    }

    private static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "..."
    }
}
