import SwiftUI

/// What the lid switch says before it is switched on.
///
/// It is the one part of the hold that outlives Sissy, so it is the one that
/// asks: the confirmation says what changes, what it costs on battery and in
/// a bag, and what a crash leaves behind, which is the admission the rule it
/// is an exception to asks for.
enum KeepAwakeLidCopy {
    static let confirmTitle = "Keep the Mac working with the lid closed?"

    /// Names the battery floor in force, because it is the one way a closed
    /// Mac on battery sleeps that the user chose rather than macOS.
    static func confirmMessage(floor: LidBatteryFloor) -> String {
        let battery =
            floor.percent.map {
                "Below \($0)% on battery it will, which Settings can change. Overheating will "
                    + "still sleep it"
            } ?? "Only a nearly empty battery or overheating will"
        return "While Sissy holds the Mac awake, closing the lid will not put it to sleep, on battery too. "
            + battery + ", and so can unplugging an external "
            + "display or the charger once the lid is already closed: unplug first, then close it. A "
            + "closed Mac in a bag cannot shed its heat, so leave it somewhere open. If Sissy quits normally the lid works as usual again; "
            + "if it crashes, the Mac keeps ignoring the lid until Sissy is opened again or the Mac "
            + "restarts."
    }
}

/// Everything about holding the Mac awake: the mode, how long `Always` lasts,
/// and what a hold covers besides the Mac itself.
///
/// A tab of its own as of 2026-10-03, by the rule that a module earns one: four
/// controls and a confirmation had become the longest block on General, and
/// they answer one question that nothing else there does. The cup's menu in
/// the panel carries the same switches for the moment they are changed, and
/// this tab is where each says what it costs.
struct AwakeSettingsView: View {
    let model: SissyModel

    @State private var confirmingLid = false

    var body: some View {
        Form {
            Section {
                mode
                ceiling
            }

            Section(Self.coversSection) {
                screen
                if SissyModel.machineHasLid {
                    lid
                    batteryFloor
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            KeepAwakeLidCopy.confirmTitle,
            isPresented: $confirmingLid,
            titleVisibility: .visible
        ) {
            Button(UsageFormat.keepAwakeWithLidClosedTitle) { model.confirmKeepAwakeWithLidClosed() }
            Button(DialogCopy.cancel, role: .cancel) {}
        } message: {
            Text(KeepAwakeLidCopy.confirmMessage(floor: model.engine.lidBatteryFloor))
        }
        .task(id: model.lidConfirmationRequested) { await presentRequestedConfirmation() }
    }

    /// Takes the model's request and presents it a turn later, rather than
    /// binding the dialog to the request directly: the request is usually
    /// already true when this tab is first built, from the cup's menu, and a
    /// presentation whose binding starts true is one SwiftUI is free to skip.
    /// Taking the request here also retires it, so a request whose window
    /// never opened is answered the next time the tab does, and only once.
    private func presentRequestedConfirmation() async {
        guard model.lidConfirmationRequested else { return }
        await Task.yield()
        model.lidConfirmationRequested = false
        confirmingLid = true
    }

    private static let coversSection = "What a hold covers"

    private static let ceilingLabel = "\(UsageFormat.keepAwakeTitle(.on)) stops after"

    private static let batteryFloorLabel = "On battery, stop the closed-lid hold below"

    /// What the automatic mode costs. The name and the bound are read rather
    /// than written out: a caption that says ten minutes while the shipped
    /// policy waits fifteen, or that calls a mode by a name the picker beside
    /// it no longer uses, is worse than no caption. This and the ceiling row
    /// under it are the only places the app says when a hold ends.
    private var modeCaption: String {
        let idle = UsageFormat.countdown(KeepAwakePolicy.default.idleWindow)
        return "\(UsageFormat.keepAwakeTitle(.auto)) lets go \(idle) after the last turn."
    }

    /// What happens when the chosen ceiling is reached, and for `never` that
    /// nothing will: the two ways such a hold still ends are named, because
    /// both are the user's.
    private var ceilingCaption: String {
        model.engine.keepAwakeCeiling.hours == nil
            ? "It holds until you switch it off or quit Sissy."
            : "Then it switches itself off."
    }

    /// Both positions say what a closed lid does, because off is the answer
    /// macOS gives and on is the one a user has to have asked for.
    private var lidCaption: String {
        model.engine.keepAwakeWithLidClosed
            ? "While a hold is in force, closing the lid does not sleep the Mac, on battery too."
            : "Off, closing the lid sleeps the Mac whatever the mode."
    }

    /// What the floor does, and for `never` what is left to stop a closed Mac
    /// on battery, which is macOS alone.
    private var batteryFloorCaption: String {
        model.engine.lidBatteryFloor.percent == nil
            ? "A closed Mac on battery runs until macOS sleeps it nearly empty."
            : "Then closing the lid sleeps the Mac again, until it is back on power."
    }

    private var mode: some View {
        LabeledContent {
            Picker("Keep awake", selection: modeBinding) {
                ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                    Text(UsageFormat.keepAwakeTitle(mode)).tag(mode)
                }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text("Keep awake")
            Text(modeCaption)
        }
    }

    private var ceiling: some View {
        LabeledContent {
            Picker(Self.ceilingLabel, selection: ceilingBinding) {
                ForEach(KeepAwakeCeiling.allCases, id: \.self) { ceiling in
                    Text(UsageFormat.keepAwakeCeilingTitle(ceiling)).tag(ceiling)
                }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text(Self.ceilingLabel)
            Text(ceilingCaption)
        }
    }

    private var screen: some View {
        SettingsSwitchRow(
            UsageFormat.keepScreenAwakeTitle,
            caption: "Off lets the display sleep while the Mac stays awake underneath for the agents.",
            isOn: Binding(
                get: { model.engine.keepScreenAwake },
                set: { model.engine.setKeepScreenAwake($0) }))
    }

    private var lid: some View {
        SettingsSwitchRow(
            UsageFormat.keepAwakeWithLidClosedTitle,
            caption: lidCaption,
            isOn: Binding(
                get: { model.engine.keepAwakeWithLidClosed },
                set: { model.setKeepAwakeWithLidClosed($0) }))
    }

    /// Greyed out with the lid switch off rather than hidden, so the floor can
    /// be read before the lid is ever held.
    private var batteryFloor: some View {
        LabeledContent {
            Picker(Self.batteryFloorLabel, selection: batteryFloorBinding) {
                ForEach(LidBatteryFloor.allCases, id: \.self) { floor in
                    Text(UsageFormat.lidBatteryFloorTitle(floor)).tag(floor)
                }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text(Self.batteryFloorLabel)
            Text(batteryFloorCaption)
        }
        .disabled(!model.engine.keepAwakeWithLidClosed)
    }

    private var batteryFloorBinding: Binding<LidBatteryFloor> {
        Binding(
            get: { model.engine.lidBatteryFloor },
            set: { model.engine.setLidBatteryFloor($0) }
        )
    }

    private var modeBinding: Binding<KeepAwakeMode> {
        Binding(
            get: { model.keepAwake.mode },
            set: { model.setKeepAwake($0) }
        )
    }

    private var ceilingBinding: Binding<KeepAwakeCeiling> {
        Binding(
            get: { model.engine.keepAwakeCeiling },
            set: { model.engine.setKeepAwakeCeiling($0) }
        )
    }
}
