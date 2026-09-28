import SwiftUI

/// Settings for what Sissy reads off the machine itself, as opposed to a
/// provider's own usage.
///
/// `macHealth`, moved off General onto a tab of its own as of 2026-09-28 so
/// Disk and Network land beside it rather than inside General's own height
/// budget, and `disk` beside it. Every row is a `LabeledContent` whose label carries its
/// own caption, the shape `docs/DECISIONS.md`'s height-budget entry asks for.
struct MacSettingsView: View {
    let model: SissyModel

    var body: some View {
        Form {
            Section {
                macHealth
                disk
            }
        }
        .formStyle(.grouped)
    }

    private var macHealth: some View {
        LabeledContent {
            Toggle("Mac health", isOn: macHealthBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            Text("Mac health")
            Text("Memory, swap and load in the panel and the menu bar. Asks for nothing.")
        }
    }

    private var disk: some View {
        LabeledContent {
            Toggle("Disk", isOn: diskBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            Text("Disk")
            Text("Free space and volumes in the panel, and a low disk in the menu bar. Asks for nothing.")
        }
    }

    private var diskBinding: Binding<Bool> {
        Binding(
            get: { model.engine.disk },
            set: { model.engine.setDisk($0) }
        )
    }

    private var macHealthBinding: Binding<Bool> {
        Binding(
            get: { model.engine.macHealth },
            set: { model.engine.setMacHealth($0) }
        )
    }
}
