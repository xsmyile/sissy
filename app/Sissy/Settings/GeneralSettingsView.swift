import SwiftUI

/// Settings that change what the menubar and the device show.
struct GeneralSettingsView: View {
    let model: SissyModel

    private var mascotSelection: String {
        model.pinnedMascot ?? Self.autoMascotTag
    }

    private static let autoMascotTag = "auto"

    var body: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(
                                model.serverHealth.status.isReachable
                                    ? Color.green : Color.secondary.opacity(0.4)
                            )
                            .frame(width: 7, height: 7)
                        Text(model.menuSnapshot.server.subtitle)
                        Spacer(minLength: 0)
                        Button(model.menuSnapshot.server.title) {
                            model.toggleServerFromMenu()
                        }
                        .disabled(!model.menuSnapshot.server.isEnabled)
                    }
                }
                Text("The server runs as a background agent and keeps counting after you quit Sissy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Milestones", selection: milestoneBinding) {
                    ForEach(Preferences.MilestoneFrequency.allCases) { preset in
                        Text("every \(preset.detail)").tag(preset)
                    }
                }
                Text("How often Sissy celebrates a spend threshold.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Mascot", selection: mascotBinding) {
                    Text("Auto").tag(Self.autoMascotTag)
                    Divider()
                    ForEach(SissyModel.mascotStates, id: \.wire) { state in
                        Text(state.label).tag(state.wire)
                    }
                }
                .disabled(!model.menuSnapshot.canPickMascot && model.pinnedMascot == nil)

                Toggle("Show mood pop-ups", isOn: notifyBinding)

                Text(
                    "Auto follows today's spend. Pinning a mood freezes both the menubar icon "
                        + "and the device."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var milestoneBinding: Binding<Preferences.MilestoneFrequency> {
        Binding(
            get: { model.preferences.milestoneFrequency },
            set: { model.selectMilestoneFrequency($0) }
        )
    }

    private var mascotBinding: Binding<String> {
        Binding(
            get: { mascotSelection },
            set: { wire in
                if wire == Self.autoMascotTag {
                    model.clearMascotPin()
                } else {
                    model.pinMascot(wire)
                }
            }
        )
    }

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { model.preferences.notifyOnMascotChange },
            set: { _ in model.toggleNotifications() }
        )
    }
}
