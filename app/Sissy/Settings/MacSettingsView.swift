import SwiftUI

/// Settings for what Sissy reads off the machine itself, as opposed to a
/// provider's own usage.
///
/// One row today: `macHealth`, moved off General onto a tab of its own as of
/// 2026-09-28 so Disk and Network land beside it rather than inside General's
/// own height budget. Every row is a `LabeledContent` whose label carries its
/// own caption, the shape `docs/DECISIONS.md`'s height-budget entry asks for.
struct MacSettingsView: View {
    let model: SissyModel

    var body: some View {
        Form {
            Section {
                macHealth
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
            Text("Memory, swap and disk in the panel and the menu bar. Asks for nothing.")
        }
    }

    private var macHealthBinding: Binding<Bool> {
        Binding(
            get: { model.engine.macHealth },
            set: { model.engine.setMacHealth($0) }
        )
    }
}
