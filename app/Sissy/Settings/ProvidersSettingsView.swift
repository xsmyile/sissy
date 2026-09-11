import SwiftUI

/// What one provider's row says. A pure function of the readiness so the
/// wording is testable without a running engine — the same shape
/// `SissyModel.HeaderSnapshot` uses for the panel header.
struct ProviderRowSnapshot: Equatable {
    let name: String
    let state: String
    let detail: String

    static func make(_ readiness: ProviderReadiness) -> Self {
        Self(
            name: UsageFormat.providerName(readiness.id),
            state: state(for: readiness.activation),
            detail: detail(for: readiness)
        )
    }

    private static func state(for activation: ProviderActivation) -> String {
        switch activation {
        case .on: return "On"
        case .autoDetected: return "On, detected"
        case .off: return "Off"
        case .autoNotFound: return "Not found"
        }
    }

    /// The line that answers "why is this provider not in my panel". The two
    /// ways to find nothing are kept apart on purpose: a data dir that is not
    /// there is a different problem from one that is there and empty, and
    /// naming the path is what makes either actionable.
    ///
    /// Exhaustive over the activation on purpose — a state added later has no
    /// sensible line to fall back to, so it has to fail the build here rather
    /// than quietly claim the user switched something off.
    private static func detail(for readiness: ProviderReadiness) -> String {
        let path = (readiness.dataDir.path as NSString).abbreviatingWithTildeInPath
        switch readiness.activation {
        case .off: return "Switched off in server.json"
        case .autoNotFound: return "\(path) does not exist"
        case .on, .autoDetected: return scanned(readiness.scan, at: path)
        }
    }

    private static func scanned(_ scan: ProviderReadiness.ScanProgress?, at path: String) -> String {
        guard let scan, scan.isWarm else { return "Reading your session logs" }
        switch scan.filesWatched {
        case 0: return "No session logs in \(path)"
        case 1: return "1 session file in \(path)"
        default: return "\(scan.filesWatched) session files in \(path)"
        }
    }
}

/// What the Claude Code limits switch says about itself.
///
/// Split because the two halves are not equally urgent. `caption` carries the
/// only two facts that change what someone does — what the switch shows, and
/// that macOS will ask — and stays on screen, because a permission prompt this
/// app did not warn about is the thing Sissy's first-run promise exists to
/// avoid. `detail` is the reassurance and the after-an-update expectation:
/// worth keeping, not worth four permanent lines.
enum ClaudeLimitsCopy {
    static let title = "Show Claude Code limits"

    static let caption =
        "Shows Claude Code's 5-hour and weekly windows next to Codex's. "
        + "macOS will ask for your permission."

    static let detail =
        "Sissy reads the token Claude Code already keeps in your keychain — only ever "
        + "reads it, never writes or refreshes it. macOS asks again whenever Sissy's own "
        + "binary changes, so expect the prompt after an update."

    /// What the button reads as to a screen reader, where the glyph says
    /// nothing — the one reader who cannot see an `info.circle` and guess.
    static let detailButtonLabel = "What Sissy reads"
}

/// Where each provider's numbers come from, and what it is doing about them.
struct ProvidersSettingsView: View {
    let model: SissyModel

    @State private var showingLimitsDetail = false

    private static let tintDotSize: CGFloat = 8
    /// Wide enough that the detail reads as a paragraph rather than a column.
    private static let detailPopoverWidth: CGFloat = 280

    var body: some View {
        Form {
            ForEach(model.engine.providers, id: \.id) { readiness in
                Section {
                    row(readiness)
                    if readiness.id == ProviderID.claudeCode {
                        claudeLimits
                    }
                }
            }
        }
        .formStyle(.grouped)
        // The readiness poll stops once the scan is warm, so a window opened
        // afterwards would render whatever the last tick left behind.
        .task { model.engine.refreshProviders() }
    }

    @ViewBuilder
    private func row(_ readiness: ProviderReadiness) -> some View {
        let snapshot = ProviderRowSnapshot.make(readiness)
        LabeledContent {
            Text(snapshot.state).foregroundStyle(.secondary)
        } label: {
            Label {
                Text(snapshot.name)
            } icon: {
                Circle()
                    .fill(ProviderPalette.tint(for: readiness.id))
                    .frame(width: Self.tintDotSize, height: Self.tintDotSize)
            }
        }
        Text(snapshot.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var claudeLimits: some View {
        LabeledContent {
            Toggle(ClaudeLimitsCopy.title, isOn: claudeLimitsBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            HStack(spacing: 4) {
                Text(ClaudeLimitsCopy.title)
                detailButton
            }
        }
        Text(ClaudeLimitsCopy.caption)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// A button rather than a `help` tooltip: a tooltip is reachable only by
    /// hovering a pointer over it, and this is the one control on the page
    /// whose consequences someone may want to read before flipping it.
    private var detailButton: some View {
        Button {
            showingLimitsDetail = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(ClaudeLimitsCopy.detailButtonLabel)
        .popover(isPresented: $showingLimitsDetail, arrowEdge: .bottom) {
            Text(ClaudeLimitsCopy.detail)
                .font(.callout)
                .frame(width: Self.detailPopoverWidth)
                .padding()
        }
    }

    private var claudeLimitsBinding: Binding<Bool> {
        Binding(
            get: { model.engine.claudeLimits },
            set: { model.setClaudeLimits($0) }
        )
    }
}
