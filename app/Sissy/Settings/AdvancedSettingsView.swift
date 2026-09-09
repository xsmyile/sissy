import AppKit
import SwiftUI

/// Settings that reach the daemon's `server.json` — the ones that used to be
/// editable only by hand.
struct AdvancedSettingsView: View {
    let model: SissyModel

    @State private var revealToken = false
    @State private var thresholds = ThresholdDraft()
    @State private var didLoadThresholds = false

    /// Editable mirror of the four `stateThresholds` values. Held as a draft
    /// so a half-typed number never reaches the daemon: it is committed on
    /// Apply, which is also what restarts the server — `sissy-serverd` reads
    /// `server.json` at boot, so an unrestarted daemon keeps the old moods.
    private struct ThresholdDraft: Equatable {
        var code: Double = 20
        var glow: Double = 100
        var angry: Double = 200
        var trendRatio: Double = 1.3
    }

    var body: some View {
        Form {
            Section("Bearer token") {
                HStack(spacing: 8) {
                    if revealToken {
                        TextField("Token", text: .constant(model.preferences.authToken))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                    } else {
                        SecureField("Token", text: .constant(model.preferences.authToken))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                    }
                    Button(revealToken ? "Hide" : "Reveal") { revealToken.toggle() }
                    Button("Copy") { copyToken() }
                }
                Text(
                    "The paired device must carry the same token or its handshake is rejected "
                        + "without a visible error. Rotate it from the Device tab, which "
                        + "reprovisions the device in the same step."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Mood thresholds") {
                thresholdRow("Code", value: $thresholds.code, unit: "$")
                thresholdRow("Glow", value: $thresholds.glow, unit: "$")
                thresholdRow("Angry", value: $thresholds.angry, unit: "$")
                LabeledContent("Trend") {
                    HStack(spacing: 6) {
                        TextField("", value: $thresholds.trendRatio, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                        Text("× yesterday's spend")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Where the mascot changes mood, on both the menubar icon and the device.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Reset") { thresholds = ThresholdDraft() }
                    Button("Apply and restart") { applyThresholds() }
                        .disabled(!model.canRunPairingServerAction)
                }
            }

            Section("Files") {
                HStack {
                    Button("Open logs") { model.openLogs() }
                    Button("Reveal config in Finder") { revealConfig() }
                    Spacer(minLength: 0)
                }
                Text(verbatim: SissyPaths.appSupportDir.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadThresholds)
    }

    private func thresholdRow(_ label: String, value: Binding<Double>, unit: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(unit).foregroundStyle(.secondary)
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                Spacer(minLength: 0)
            }
        }
    }

    private func loadThresholds() {
        guard !didLoadThresholds else { return }
        didLoadThresholds = true
        thresholds = ThresholdDraft(
            code: model.preferences.costThresholdCode,
            glow: model.preferences.costThresholdGlow,
            angry: model.preferences.costThresholdAngry,
            trendRatio: model.preferences.costThresholdTrendRatio
        )
    }

    private func applyThresholds() {
        model.preferences.costThresholdCode = thresholds.code
        model.preferences.costThresholdGlow = thresholds.glow
        model.preferences.costThresholdAngry = thresholds.angry
        model.preferences.costThresholdTrendRatio = thresholds.trendRatio
        model.applyPairingServerConfiguration()
    }

    private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.preferences.authToken, forType: .string)
    }

    private func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([SissyPaths.appSupportDir])
    }
}
