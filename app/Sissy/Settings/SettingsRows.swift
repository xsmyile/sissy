import SwiftUI

/// One on/off row, in the shape `docs/DECISIONS.md`'s height-budget entry
/// asks every control for: a `LabeledContent` whose label carries the
/// heading and the caption under it, beside a switch.
///
/// A switch rather than the checkbox a `Toggle` renders as by default in a
/// grouped `Form`, because every row in this window says whether something is
/// on and a window that answered that two ways would be asking the reader
/// which one meant what. The title goes to the `Toggle` and is then hidden,
/// so the control the pointer lands on is still named for a reader who cannot
/// see the heading beside it.
struct SettingsSwitchRow<Heading: View>: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool
    let heading: Heading

    init(
        _ title: String, caption: String, isOn: Binding<Bool>,
        @ViewBuilder heading: () -> Heading
    ) {
        self.title = title
        self.caption = caption
        _isOn = isOn
        self.heading = heading()
    }

    var body: some View {
        LabeledContent {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            heading
            Text(caption)
        }
    }
}

extension SettingsSwitchRow where Heading == Text {
    init(_ title: String, caption: String, isOn: Binding<Bool>) {
        self.init(title, caption: caption, isOn: isOn) { Text(title) }
    }
}

extension View {
    /// A removal asked about before it runs: raised while `item` holds what
    /// the row's menu chose, and dropped by either button.
    ///
    /// One shape for every destructive press in Settings, because each of
    /// them deletes something the user cannot read back and never typed, and
    /// a dialog that drifted from the others in which button is the default
    /// would be the one somebody confirms by reflex.
    func confirmRemoval<Item>(
        of item: Binding<Item?>,
        title: @escaping (Item) -> String,
        message: String,
        confirm: String,
        action: @escaping (Item) -> Void
    ) -> some View {
        confirmationDialog(
            item.wrappedValue.map(title) ?? "",
            isPresented: Binding(
                get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            presenting: item.wrappedValue
        ) { value in
            Button(confirm, role: .destructive) { action(value) }
            Button(DialogCopy.cancel, role: .cancel) {}
        } message: { _ in
            Text(message)
        }
    }
}
