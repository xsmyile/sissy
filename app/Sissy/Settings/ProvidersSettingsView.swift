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
    private static func detail(for readiness: ProviderReadiness) -> String {
        let path = (readiness.dataDir.path as NSString).abbreviatingWithTildeInPath
        guard readiness.activation.isMetering else {
            switch readiness.activation {
            case .autoNotFound: return "\(path) does not exist"
            default: return "Switched off in server.json"
            }
        }
        guard let scan = readiness.scan, scan.isWarm else {
            return "Reading your session logs"
        }
        switch scan.filesWatched {
        case 0: return "No session logs in \(path)"
        case 1: return "1 session file in \(path)"
        default: return "\(scan.filesWatched) session files in \(path)"
        }
    }
}

/// Where each provider's numbers come from, and what it is doing about them.
struct ProvidersSettingsView: View {
    let model: SissyModel

    private static let tintDotSize: CGFloat = 8

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
        Toggle("Show Claude Code limits", isOn: claudeLimitsBinding)
        Text(
            "Reads the token Claude Code already keeps in your keychain to show its "
                + "5-hour and weekly windows next to Codex's. macOS asks for your "
                + "permission, and asks again whenever Sissy's own binary changes; "
                + "Sissy only ever reads the token, never writes or refreshes it."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var claudeLimitsBinding: Binding<Bool> {
        Binding(
            get: { model.engine.claudeLimits },
            set: { model.setClaudeLimits($0) }
        )
    }
}
