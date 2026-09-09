import AppKit
import SwiftUI

/// Usage panel shown on a left-click of the status item. Reads the live
/// frame through `SissyModel`; every number it prints comes from
/// `UsagePanelSnapshot` so the panel and the pull-down menu cannot disagree.
struct UsagePanelView: View {
    let model: SissyModel

    private static let width: CGFloat = 340
    private static let footerTick: TimeInterval = 1

    private static var dateLine: String {
        "Today · "
            + Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var snapshot: UsagePanelSnapshot? {
        model.currentFrame.map {
            UsagePanelSnapshot.make(frame: $0, milestoneFrequency: model.preferences.milestoneFrequency)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let snapshot {
                headline(snapshot)
                if let milestone = snapshot.milestone {
                    milestoneBar(milestone)
                }
                if !snapshot.providers.isEmpty {
                    Divider()
                    providers(snapshot.providers)
                }
            } else {
                placeholder
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
    }

    // MARK: Header

    private var header: some View {
        let menuHeader = model.menuSnapshot.header
        return HStack(spacing: 10) {
            Image(menuHeader.imageName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(menuHeader.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(Self.dateLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                statusPill(label: "server", isOn: model.serverHealth.status.isReachable)
                statusPill(label: "device", isOn: model.currentFrame?.devicePresent ?? false)
            }
        }
        .opacity(menuHeader.isDimmed ? 0.6 : 1)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func statusPill(label: String, isOn: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
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

    // MARK: Milestone

    private func milestoneBar(_ milestone: UsagePanelSnapshot.MilestoneProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("next milestone $\(milestone.nextDollars)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(UsageFormat.cost(milestone.remaining)) to go")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: milestone.fraction)
                .progressViewStyle(.linear)
                .tint(.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .animation(.default, value: milestone.fraction)
    }

    // MARK: Providers

    private func providers(_ rows: [UsagePanelSnapshot.ProviderRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(ProviderPalette.tint(for: row.id))
                            .frame(width: 7, height: 7)
                        Text(row.name)
                            .font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        Text(row.cost)
                            .font(.system(size: 12))
                            .monospacedDigit()
                    }
                    shareBar(row.share, tint: ProviderPalette.tint(for: row.id))
                    Text("\(Int((row.share * 100).rounded()))% · \(row.tokens) tokens")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for the daemon")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button(model.menuSnapshot.server.title) {
                model.toggleServer()
            }
            .disabled(!model.menuSnapshot.server.isEnabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: Self.footerTick)) { context in
                Text(updatedLine(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            settingsLink("gearshape", help: "Settings", tab: .general)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func updatedLine(now: Date) -> String {
        guard let last = model.lastFrameAt else { return "waiting for the daemon" }
        return "updated " + UsageFormat.age(now.timeIntervalSince(last))
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
