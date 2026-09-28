import SwiftUI

/// A module of the panel with a page of its own, in the order the tab bar
/// draws them.
///
/// **A module earns a tab when it has more than a line to say.** The sessions
/// always have one: what ran over a window and what is running now is a page
/// whichever day it is, and a tab that came and went with the processes
/// would not be a destination. The Mac and the disks each have a page whenever
/// there is a reading to put on it, and repositories have one once a forge is
/// connected: without one, what is left of them is the identity line, which
/// stays under the projects it is about rather than becoming a tab holding a
/// single row.
///
/// **A tab is named for what it reads.** Usage is the vendors' own word for
/// spend against a plan's limits, Sessions the CLIs somebody started, Mac the
/// machine's memory, Disk its volumes and Forge the accounts Settings connects
/// under that same name.
///
/// Only the selected tab is ever built: the panel switches on it the way it
/// switches on its pages, so a module nobody is looking at costs nothing.
enum PanelTab: CaseIterable, Hashable {
    case usage
    case sessions
    case mac
    case disk
    case forge

    static func visible(in snapshot: UsagePanelSnapshot) -> [Self] {
        allCases.filter { $0.isVisible(in: snapshot) }
    }

    private func isVisible(in snapshot: UsagePanelSnapshot) -> Bool {
        switch self {
        case .usage, .sessions: true
        case .mac: snapshot.mac != nil
        case .disk: snapshot.disk != nil
        case .forge: !snapshot.forge.isEmpty
        }
    }

    var title: String {
        switch self {
        case .usage: "Usage"
        case .sessions: "Sessions"
        case .mac: "Mac"
        case .disk: "Disk"
        case .forge: "Forge"
        }
    }

    var symbol: String {
        switch self {
        case .usage: "gauge.with.dots.needle.33percent"
        case .sessions: "terminal"
        case .mac: "memorychip"
        case .disk: "internaldrive"
        case .forge: "arrow.triangle.branch"
        }
    }

    /// ⌘1 onwards, by position in the full list rather than in the visible
    /// one, so a key names the same module whichever are switched on. Read
    /// from `allCases` rather than written out per case, so Disk and Network
    /// landing between Mac and Forge renumber the tabs after them without a
    /// table to edit.
    var shortcut: KeyEquivalent {
        guard let index = Self.allCases.firstIndex(of: self) else { return "1" }
        return KeyEquivalent(Character("\(index + 1)"))
    }

    /// What a tab says about its page while another one is open.
    ///
    /// The one thing on that page worth leaving the current one for: the
    /// kernel's memory pressure once it is past normal on Mac, the disk's
    /// grade past normal on Disk, and a repository committing under an
    /// unexpected name. The menu bar's dot wears the worse of the first two,
    /// since it has one mark for the whole machine and the bar has a tab for
    /// each. Usage carries none, because it is the page the panel opens on,
    /// and Sessions none either: a session running is the ordinary state, and
    /// what the sessions hold becomes worth leaving a page for through the
    /// Mac's badge.
    func badge(in snapshot: UsagePanelSnapshot) -> PanelTabBadge? {
        switch self {
        case .usage, .sessions:
            return nil
        case .mac:
            guard let level = snapshot.mac?.memory.level, level > .normal else { return nil }
            return .memory(level)
        case .disk:
            guard let level = snapshot.disk?.free.level, level > .normal else { return nil }
            return .disk(level)
        case .forge:
            return snapshot.identityLine.state == .findings ? .findings : nil
        }
    }
}

enum PanelTabBadge: Equatable {
    case memory(MacHealthLevel)
    case disk(MacHealthLevel)
    case findings

    /// One mark for every badge, told apart by colour alone: a level in the
    /// colour it wears everywhere else, a finding in the orange the identity
    /// line warns in.
    var tint: Color {
        switch self {
        case .memory(let level), .disk(let level): MacLevelStyle.tint(level)
        case .findings: .orange
        }
    }

    /// What the mark stands for, on the hover and to VoiceOver, since a dot
    /// has no words of its own.
    var reason: String {
        switch self {
        case .memory(let level): "Memory at \(UsageFormat.macLevel(level))"
        case .disk(let level): "Disk at \(UsageFormat.macLevel(level))"
        case .findings: "A repository commits under an unexpected name"
        }
    }
}

/// The panel's modules, on a row of their own under the header.
///
/// **Its own row rather than the header's**, where it was drawn first: beside
/// Sissy and the two round controls, segments on the same glass read as more
/// controls, and navigation that looks like a switch is not
/// found as navigation. A row costs the panel its height and keeps the bar
/// at the same y on every tab, near where the pointer arrives from the menu
/// bar. At the bottom it would move under the pointer on every switch, since
/// each tab is a different height and the popover grows downward.
///
/// **Glass, because it is navigation.** Apple's materials guidance keeps
/// Liquid Glass for the controls and navigation floating above content, and
/// the tab bar is exactly that. The selection is a fill inside it rather
/// than glass on glass.
///
/// A plain row of buttons rather than a segmented `Picker`: a segment cannot
/// carry the badge, and the badge is the only thing a tab says about the page
/// it is not showing.
///
/// **The badge tints the tab's own symbol, as of 2026-09-28.** A triangle
/// hung off the title's corner was the first drawing, and it read as an alert
/// detached from the tab and pressed against the bar's edge; a dot after the
/// title followed, in line with the word it followed and costing the segment
/// no height. The colour moved onto the symbol because it costs the segment
/// no width either, and because it lands on the module's own mark — the rule
/// the panel already keeps for a reading, rather than a mark drawn beside one.
///
/// **Icon only, as of 2026-09-28.** A title beside the symbol is what the bar
/// drew through Disk and Network landing beside Mac and Forge: measured with
/// AppKit at the bar's own fonts, an icon-and-title segment fits four tabs in
/// the panel's 332 pt width — "Sessions" alone needs 72.6 pt, five tabs leave
/// 66.4 pt each, six leave 55.3 — so the bar had to drop the title before a
/// fifth tab existed to prove it. The name and the shortcut stay in `.help`,
/// and the name becomes the accessibility label a sighted title used to give
/// for free.
struct PanelTabBar: View {
    let tabs: [PanelTab]
    @Binding var selection: PanelTab
    let badge: (PanelTab) -> PanelTabBadge?

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let height: CGFloat = 30
    private static let inset: CGFloat = 2
    private static let symbolSize: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                button(tab)
            }
        }
        .padding(Self.inset)
        .frame(height: Self.height)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, PanelMetrics.platterInset)
        .padding(.bottom, PanelMetrics.platterInset)
    }

    private func button(_ tab: PanelTab) -> some View {
        let isSelected = tab == selection
        let badge = badge(tab)
        return Button {
            withAnimation(reduceMotion ? nil : .snappy) { selection = tab }
        } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: Self.symbolSize, weight: .medium))
                .foregroundStyle(
                    badge.map { AnyShapeStyle($0.tint) } ?? AnyShapeStyle(symbolStyle(isSelected))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Self.selectedFill)
                            .matchedGeometryEffect(id: Self.indicatorID, in: indicator)
                    }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(tab.shortcut, modifiers: .command)
        .help(help(tab))
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The hierarchical style rather than `Color.primary` or `Color.secondary`,
    /// which are not the vibrant ones the bar's glass draws a symbol in.
    private func symbolStyle(_ isSelected: Bool) -> HierarchicalShapeStyle {
        isSelected ? .primary : .secondary
    }

    private func help(_ tab: PanelTab) -> String {
        let name = "\(tab.title) (⌘\(tab.shortcut.character))"
        guard let badge = badge(tab) else { return name }
        return name + "\n" + badge.reason
    }

    private static let indicatorID = "selection"

    private nonisolated static let darkSelectedAlpha: CGFloat = 0.16
    private nonisolated static let lightSelectedAlpha: CGFloat = 0.9

    /// Lighter than the bar in both appearances, the way the system's own
    /// segmented control draws its selection.
    private static let selectedFill = Color(
        nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(white: 1, alpha: isDark ? darkSelectedAlpha : lightSelectedAlpha)
        })
}
