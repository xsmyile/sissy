import SwiftUI

/// Settings for what Sissy reads off the machine itself, as opposed to a
/// provider's own usage.
///
/// `macHealth`, moved off General onto a tab of its own as of 2026-09-28 so
/// Disk and Network land beside it rather than inside General's own height
/// budget, `disk` beside it, and `network`, the Network tab's switch. Every
/// row is a `LabeledContent` whose label carries its own caption, the shape
/// `docs/DECISIONS.md`'s height-budget entry asks for.
struct MacSettingsView: View {
    let model: SissyModel

    var body: some View {
        Form {
            Section {
                macHealth
                disk
                network
            }
        }
        .formStyle(.grouped)
    }

    private var macHealth: some View {
        SettingsSwitchRow(
            "Mac health",
            caption: "Memory, swap and load in the panel and the menu bar. Asks for nothing.",
            isOn: Binding(get: { model.engine.macHealth }, set: { model.engine.setMacHealth($0) }))
    }

    private var disk: some View {
        SettingsSwitchRow(
            "Disk",
            caption: "Free space and volumes in the panel, and a low disk in the menu bar. "
                + "Asks for nothing.",
            isOn: Binding(get: { model.engine.disk }, set: { model.engine.setDisk($0) }))
    }

    private var network: some View {
        SettingsSwitchRow(
            "Network",
            caption: "A tab with the rate, the link and the Wi-Fi signal. Asks for nothing.",
            isOn: Binding(get: { model.engine.network }, set: { model.engine.setNetwork($0) }))
    }
}
