import AppKit
import SwiftUI

/// Standalone About panel. Ghostty-style layout: large app icon, app name,
/// two-line tagline, version/build grid, single GitHub button.
/// Reads `CFBundleShortVersionString` + `CFBundleVersion` from the running
/// bundle so the panel stays accurate without any extra build wiring.
struct AboutView: View {
    private static let githubURL = URL(string: "https://github.com/xsmyile/sissy")!

    var body: some View {
        VStack(spacing: 20) {
            appIcon
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Sissy")
                    .font(.system(size: 22, weight: .bold))
                Text("Tracks Claude Code and Codex\nspend from your Mac menu bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 200)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Version")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(Self.shortVersion)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                GridRow {
                    Text("Build")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(Self.buildNumber)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }

            Button {
                NSWorkspace.shared.open(Self.githubURL)
            } label: {
                Text("GitHub")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(width: 280)
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
