import AppKit
import SwiftUI

/// Settings that change what the menubar and the device show.
struct GeneralSettingsView: View {
    let model: SissyModel

    private static let autoMascotTag = "auto"

    private var server: SissyModel.ServerItemSnapshot { model.menuSnapshot.server }

    var body: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    HStack(spacing: 8) {
                        if !server.isEnabled && model.serverIsBusy {
                            ProgressView().controlSize(.small)
                        }
                        if server.requiresApproval {
                            Button("Approve in Login Items") { model.toggleServer() }
                        } else {
                            Toggle("Server", isOn: serverBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!server.isEnabled)
                        }
                    }
                }
                Text(serverCaption)
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

            Section {
                LabeledContent("Files") {
                    HStack(spacing: 14) {
                        Button("Open logs") { model.openLogs() }
                            .buttonStyle(.link)
                        Button("Show in Finder") { revealConfig() }
                            .buttonStyle(.link)
                    }
                }
                Text(verbatim: (SissyPaths.appSupportDir.path as NSString).abbreviatingWithTildeInPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var serverCaption: String {
        let endpoint = "\(model.preferences.serverHost):\(model.preferences.serverPort)"
        return "\(server.subtitle) · \(endpoint). Runs as a background agent and keeps counting "
            + "after you quit Sissy."
    }

    private var serverBinding: Binding<Bool> {
        Binding(
            get: { server.isOn },
            set: { _ in model.toggleServer() }
        )
    }

    private var milestoneBinding: Binding<Preferences.MilestoneFrequency> {
        Binding(
            get: { model.preferences.milestoneFrequency },
            set: { model.selectMilestoneFrequency($0) }
        )
    }

    private var mascotBinding: Binding<String> {
        Binding(
            get: { model.pinnedMascot ?? Self.autoMascotTag },
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

    private func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([SissyPaths.appSupportDir])
    }
}
