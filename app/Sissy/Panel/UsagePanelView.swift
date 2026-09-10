import AppKit
import SwiftUI

/// Usage panel shown on a left-click of the status item. Reads the live
/// frame through `SissyModel`; every number it prints comes from
/// `UsagePanelSnapshot` so the panel and the pull-down menu cannot disagree.
struct UsagePanelView: View {
    let model: SissyModel

    private static let width: CGFloat = 340
    private static let footerTick: TimeInterval = 1
    private static let secondaryWindowOpacity: Double = 0.55
    private static let powerButtonSize: CGFloat = 26
    private static let mascotSize: CGFloat = 24

    private static var dateLine: String {
        "Today · "
            + Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func makeSnapshot(_ frame: DisplayFrame) -> UsagePanelSnapshot {
        UsagePanelSnapshot.make(frame: frame)
    }

    var body: some View {
        let live = model.liveFrame
        let snapshot = live.map { makeSnapshot($0.frame) }
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let snapshot {
                headline(snapshot)
                if !snapshot.providers.isEmpty {
                    Divider()
                    providers(snapshot.providers)
                }
            } else {
                placeholder
            }
            Divider()
            footer(live)
        }
        .frame(width: Self.width)
    }

    // MARK: Header

    private var header: some View {
        let menuHeader = model.menuSnapshot.header
        return HStack(spacing: 10) {
            PanelMascot(
                isAsleep: menuHeader.isAsleep,
                lastFrameAt: model.lastFrameAt,
                motionEnabled: model.preferences.mascotMotion,
                size: Self.mascotSize
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(menuHeader.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(menuHeader.subtitle ?? Self.dateLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            powerButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Starts and stops the background daemon. It replaces the old "server"
    /// dot: the state it reported was the same state this button now shows,
    /// and one control beats an indicator plus a button hidden in a
    /// placeholder that only appeared when the daemon was already missing.
    private var powerButton: some View {
        let server = model.menuSnapshot.server
        return Button {
            model.toggleServer()
        } label: {
            Group {
                if model.serverIsBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .frame(width: Self.powerButtonSize, height: Self.powerButtonSize)
            .foregroundStyle(server.isOn ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .glassEffect(
            server.isOn ? .regular.tint(.green.opacity(0.22)) : .regular,
            in: .circle
        )
        .disabled(!server.isEnabled)
        .help(server.isOn ? "Stop the server" : "Start the server")
    }

    // MARK: Headline

    private func headline(_ snapshot: UsagePanelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.tokens)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("tokens")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let delta = snapshot.delta {
                    deltaChip(delta)
                }
            }
            Text(subline(snapshot))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .animation(.default, value: snapshot.tokens)
    }

    private func subline(_ snapshot: UsagePanelSnapshot) -> String {
        snapshot.burn == FrameDecoder.placeholder
            ? snapshot.cost : "\(snapshot.cost) · \(snapshot.burn)/h"
    }

    private func deltaChip(_ delta: UsagePanelSnapshot.TokenDelta) -> some View {
        HStack(spacing: 3) {
            Image(systemName: deltaSymbol(delta.direction))
                .font(.system(size: 9, weight: .bold))
            Text("\(delta.percent)%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
            Text("vs yesterday")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(deltaTint(delta.direction))
    }

    private func deltaSymbol(_ direction: UsagePanelSnapshot.DeltaDirection) -> String {
        switch direction {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "equal"
        }
    }

    private func deltaTint(_ direction: UsagePanelSnapshot.DeltaDirection) -> Color {
        switch direction {
        case .up: return .green
        case .down: return .red
        case .flat: return .secondary
        }
    }

    // MARK: Providers

    private func providers(_ rows: [UsagePanelSnapshot.ProviderRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                providerRow(row)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// A provider shows its subscription windows when the CLI reports them,
    /// and its share of the day when it does not. Never both: the two bars
    /// carry percentages of different things, and side by side neither reads.
    private func providerRow(_ row: UsagePanelSnapshot.ProviderRow) -> some View {
        let tint = ProviderPalette.tint(for: row.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                if let plan = row.plan {
                    planBadge(plan)
                }
                Spacer(minLength: 0)
                Text("\(row.tokens) · \(row.cost)")
                    .font(.system(size: 12))
                    .monospacedDigit()
            }

            if row.windows.isEmpty {
                shareBar(row.share, tint: tint)
                Text("\(Int((row.share * 100).rounded()))% of today")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ForEach(Array(row.windows.enumerated()), id: \.element.id) { index, window in
                    windowRow(window, tint: tint)
                        .opacity(index == 0 ? 1 : Self.secondaryWindowOpacity)
                }
            }
        }
    }

    /// The account's plan, badged rather than set as plain text beside the
    /// name: "Codex Plus" reads as a product OpenAI sells, and the pill is
    /// what says the word is an attribute of the account instead. It yields
    /// its width first — of the three things on this line, the plan is the
    /// one a reader can still infer once it is gone.
    private func planBadge(_ plan: String) -> some View {
        Text(plan)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .layoutPriority(-1)
    }

    private func windowRow(
        _ window: UsagePanelSnapshot.WindowRow,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            shareBar(window.fraction, tint: tint)

            Text("\(window.percent)%")
                .font(.system(size: 11))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)

            Text("\(window.label) · \(UsageFormat.resetLabel(window.resetsAt))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 74, alignment: .trailing)
        }
    }

    private func shareBar(_ share: Double, tint: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(geometry.size.width * share, share > 0 ? 3 : 0))
            }
        }
        .frame(height: 5)
        .animation(.default, value: share)
    }

    // MARK: Placeholder

    private var placeholder: some View {
        let isOn = model.menuSnapshot.server.isOn
        return VStack(alignment: .leading, spacing: 3) {
            Text(isOn ? "Waiting for the daemon" : "Server is off")
                .font(.system(size: 12, weight: .medium))
            Text(
                isOn
                    ? "It reports the day's first frame within a few seconds."
                    : "Switch it on with the power button above."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: Footer

    /// Carries the age of the frame only while one is live: the panel body
    /// already says what it is waiting for, and repeating it in the footer
    /// read as two problems.
    private func footer(_ live: SissyModel.LiveFrame?) -> some View {
        HStack(spacing: 6) {
            if let live {
                TimelineView(.periodic(from: .now, by: Self.footerTick)) { context in
                    Text("updated " + UsageFormat.age(context.date.timeIntervalSince(live.at)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            settingsLink("gearshape", help: "Settings", tab: .general)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// `SettingsLink` is the only public way to open the `Settings` scene, and
    /// it takes no action closure — the simultaneous gesture is what lets a
    /// footer button aim the window at its own tab.
    private func settingsLink(_ symbol: String, help: String, tab: SettingsTab) -> some View {
        SettingsLink {
            footerIcon(symbol)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .simultaneousGesture(TapGesture().onEnded { model.settingsTab = tab })
    }

    private func footerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .frame(width: 16, height: 16)
    }
}
