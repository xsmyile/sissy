import SwiftUI

/// Whether Sissy can read the credential a row stands for.
///
/// Two states rather than one per reader: a list of credentials is read to
/// answer "is anything wrong with what I have connected", and a row that is
/// working has nothing to add to the identity it already prints. The sentence
/// on the other branch is the reader's own — `UsageFormat.limitsNotice` for an
/// account, `UsageFormat.forgeFailure` for a forge — so a state either of them
/// learns to word reaches this row without a second vocabulary to keep in step.
enum CredentialHealth: Equatable {
    case ok
    case attention(String)

    var message: String? {
        guard case .attention(let message) = self else { return nil }
        return message
    }
}

/// The one control that recovers a row needing attention, beside the sentence
/// that says what is wrong.
///
/// On the row rather than only on the panel. A credential another signature
/// filed, or one whose grant a re-signing cost, can be read again only by a
/// read that may raise the keychain's dialog, and the only such read used to
/// be `Refresh now` in the context menu of a panel row: measured 2026-09-22,
/// the way back from a lapsed forge grant was a secondary click on a row
/// inside a popover that also eats the first click, and nothing on the tab
/// that lists the connection said it existed.
struct CredentialFix {
    let title: String
    let act: () -> Void
}

/// The disc a credential row leads on, with whatever it is the row's own
/// answer to "which of these is this" drawn in it.
///
/// The badge is drawn only when there is something to report. A tick on every
/// healthy row is a column of ticks, and the one row that needs the eye then
/// has to compete with them.
struct CredentialDisc<Content: View>: View {
    let tint: Color
    let health: CredentialHealth
    let content: Content

    static var diameter: CGFloat { 28 }
    private static var badgeSize: CGFloat { 11 }
    private static var fillOpacity: Double { 0.18 }
    /// How far the badge sits outside the disc. Drawn flush inside it, the
    /// glyph lands on the second initial and neither is then readable.
    private static var badgeOffset: CGFloat { 3 }

    init(
        tint: Color,
        health: CredentialHealth = .ok,
        @ViewBuilder content: () -> Content
    ) {
        self.tint = tint
        self.health = health
        self.content = content()
    }

    var body: some View {
        Circle()
            .fill(tint.opacity(Self.fillOpacity))
            .frame(width: Self.diameter, height: Self.diameter)
            .overlay { content }
            .overlay(alignment: .bottomTrailing) { badge }
            .accessibilityHidden(true)
    }

    /// A filled symbol with its own inner colour rather than a glyph over a
    /// disc: it reads on whatever the form draws behind it without this view
    /// having to guess that colour.
    @ViewBuilder
    private var badge: some View {
        if health != .ok {
            Image(systemName: "exclamationmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .orange)
                .font(.system(size: Self.badgeSize, weight: .bold))
                .offset(x: Self.badgeOffset, y: Self.badgeOffset)
        }
    }
}

/// An account's disc: initials rather than the provider's own mark, which
/// every row under one provider would carry identically. What a reader is
/// looking for in a list of two Claude accounts is which is which, and the
/// organisation is the field two seats of one person differ by.
struct CredentialMonogram: View {
    let name: String
    let tint: Color
    var health: CredentialHealth = .ok

    private static let initialsSize: CGFloat = 11
    private static let glyphSize: CGFloat = 13
    /// The shortest run of letters that reads as a word rather than as a
    /// fragment of something that is not a name.
    private static let shortestWord = 2

    var body: some View {
        CredentialDisc(tint: tint, health: health) {
            let initials = Self.initials(of: name)
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: Self.glyphSize))
                    .foregroundStyle(tint)
            } else {
                Text(initials)
                    .font(.system(size: Self.initialsSize, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
    }

    /// Two letters at most, off whatever names the row.
    ///
    /// An address is read to its local part first, because the domain is the
    /// vendor's rather than the person's: an address monogrammed off its
    /// whole spelling names the mail provider rather than the person.
    ///
    /// A word has to be letters all through, which is what keeps a uuid out of
    /// the disc: an account filed before anything could name it is titled by
    /// one, and splitting on letters alone left the letter runs inside it
    /// looking like initials — measured, the uuid this repo's tests carry
    /// monogrammed itself `C`. A hex group is a word with digits in it, so
    /// reading the groups whole is what tells the two apart.
    ///
    /// It answers empty for a name that has none, and the view draws a glyph.
    static func initials(of name: String) -> String {
        let named = name.split(separator: "@").first.map(String.init) ?? name
        let words = named.split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= shortestWord && $0.allSatisfy(\.isLetter) }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

/// One credential Sissy holds: who it is, what it is on, what it has to report
/// and the actions that belong to it.
///
/// A row of its own rather than another `LabeledContent`, which is the shape
/// every control in this window takes: those are a title and a caption beside
/// the switch they explain, where this is a list item whose whole substance is
/// the identity on it. Drawn as one it read as a setting called "Davide".
///
/// The actions sit in a menu rather than as bare glyphs. One naked trash is
/// the only thing the row used to offer, so the single visible action was the
/// destructive one; a menu names what it does before it is opened and leaves
/// room for the actions a row grows later. The forge row is what that room was
/// for: `Reconnect…` is a verb no glyph can carry — the circular arrow already
/// means `Refresh now` on the panel's own forge row — and macOS draws no icon
/// inside a SwiftUI menu item, so the menu's items are words by construction.
struct CredentialRow<Leading: View, Actions: View>: View {
    let title: String
    let badge: String?
    let badgeTier: String?
    let subtitle: String?
    let health: CredentialHealth
    let fix: CredentialFix?
    let leading: Leading
    let actions: Actions

    private static var spacing: CGFloat { 10 }

    init(
        title: String,
        badge: String? = nil,
        badgeTier: String? = nil,
        subtitle: String? = nil,
        health: CredentialHealth = .ok,
        fix: CredentialFix? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.badge = badge
        self.badgeTier = badgeTier
        self.subtitle = subtitle
        self.health = health
        self.fix = fix
        self.leading = leading()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let badge {
                        PlanBadge(plan: badge, tier: badgeTier)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let message = health.message {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let fix {
                            Spacer(minLength: 0)
                            Button(fix.title, action: fix.act)
                                .font(.callout)
                                .buttonStyle(.borderless)
                                .layoutPriority(1)
                        }
                    }
                }
            }
            actions
        }
    }
}

/// The words a credential row's own menu uses, which do not differ by vendor:
/// what it copies is an identifier the row prints but a form will not let you
/// select, and what it removes is a credential.
enum CredentialRowCopy {
    static let copyAddress = "Copy address"
    static let copyHost = "Copy host"
}

/// The last row of a list of credentials, which is where the control that
/// lengthens it belongs: it used to be a button in the trailing slot of a
/// caption two rows above the list it added to.
struct CredentialAddRow: View {
    let title: String
    let act: () -> Void

    init(_ title: String, act: @escaping () -> Void) {
        self.title = title
        self.act = act
    }

    var body: some View {
        Button(action: act) {
            Label(title, systemImage: "plus.circle")
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Puts an identifier a row prints on the clipboard, which is the one thing a
/// `Form` row cannot otherwise give up: its text is not selectable, and an
/// address is what someone reads such a list to find.
struct CredentialCopyButton: View {
    let title: String
    let value: String

    init(_ title: String, of value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
    }
}

/// The menu a credential row's actions live in.
///
/// It is never disabled and never hidden behind a hover: a row whose only
/// control appears when the pointer is over it is a row a keyboard cannot
/// reach, and this one carries the only way to remove the credential.
struct CredentialRowMenu<Content: View>: View {
    let label: String
    /// What this row's menu is for, on the hover. Where removing is all it
    /// does, that is what removing costs — the sentence the trash this menu
    /// replaced carried, which stays here rather than moving into the
    /// confirmation, since by then the user has already decided.
    let help: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The ⓘ beside a heading, which is where the paragraph that used to sit under
/// it now lives.
///
/// The prose is not the problem and deleting it is not the fix: what a reader
/// needs before they link an account is the same sentence it always was, and
/// what the tab could not afford was printing all of it at once. Measured at
/// 560 pt, the two account captions and the limits-source row came to 149 pt of
/// a 600 pt budget the tab was already 32 pt over.
struct SettingsInfoButton: View {
    let title: String
    let detail: String

    @State private var showing = false

    private static let width: CGFloat = 280

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(title)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(detail)
                .font(.callout)
                .frame(width: Self.width)
                .padding()
        }
    }
}
