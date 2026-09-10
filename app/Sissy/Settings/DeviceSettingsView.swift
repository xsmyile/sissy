import SwiftUI

/// Everything that concerns the ESP32 companion: whether one is on the
/// network, what it renders in its big slot, the bearer token both sides must
/// share, and the USB provisioning flow that installs all of it.
///
/// The provisioning fields are a draft owned by `PairingViewModel` — nothing
/// here reaches `Preferences` or the device until Pair Device is pressed, so a
/// half-typed SSID never breaks a working pairing.
struct DeviceSettingsView: View {
    let model: SissyModel

    @State private var viewModel = PairingViewModel()
    @State private var showOtherNetworkField = false
    @State private var showLocationDeniedAlert = false
    @State private var showRepair = false

    private static let portFieldWidth: CGFloat = 72

    private var isConnected: Bool { model.currentFrame?.devicePresent ?? false }

    var body: some View {
        Form {
            Section {
                statusCard
            }

            Section {
                Picker("OLED metric", selection: metricBinding) {
                    ForEach(Preferences.PrimaryMetric.allCases) { metric in
                        Text(metric.label).tag(metric)
                    }
                }
                tokenRow
                Text(
                    "The device must carry the same token as the server or its handshake is "
                        + "rejected with no visible error. Pair Device writes both."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section(isExpanded: $showRepair) {
                serialRow
                networkRow
                settingsRow("Password") {
                    SecureField("Wi-Fi password", text: $viewModel.wifiPassword)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                serverRow
                otaDisclosure
                pairFooter
            } header: {
                Text("Provision over USB")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            viewModel.applyPreferences(model.preferences)
            showRepair = !isConnected
        }
        .onDisappear {
            viewModel.cancelProvisioning()
        }
        .alert("Location access is off", isPresented: $showLocationDeniedAlert) {
            Button("Open System Settings") { WiFiScanner.openSystemLocationSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "macOS requires Location access to read Wi-Fi network names. Enable Sissy in "
                    + "System Settings > Privacy & Security > Location Services, then scan again."
            )
        }
    }

    // MARK: Status

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: isConnected ? "wifi" : "wifi.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isConnected ? Color.green : .secondary)
                .frame(width: 34, height: 34)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(isConnected ? "Device connected" : "No device on Wi-Fi")
                    .font(.body.weight(.medium))
                Text(
                    isConnected
                        ? "The daemon is pushing frames to the OLED."
                        : "Provision it over USB below; it joins Wi-Fi on its own afterwards."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: Token

    private var tokenRow: some View {
        settingsRow("Token") {
            HStack(spacing: 6) {
                Group {
                    if viewModel.revealToken {
                        TextField("Token", text: $viewModel.authToken)
                            .font(.system(size: 12, design: .monospaced))
                    } else {
                        SecureField("Token", text: $viewModel.authToken)
                    }
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)

                iconButton(
                    viewModel.revealToken ? "eye.slash" : "eye",
                    help: viewModel.revealToken ? "Hide token" : "Show token"
                ) {
                    viewModel.revealToken.toggle()
                }

                iconButton("doc.on.doc", help: "Copy token") {
                    viewModel.copyTokenToPasteboard()
                }
                .disabled(viewModel.authToken.isEmpty)

                iconButton("arrow.trianglehead.2.clockwise", help: "Generate a new token") {
                    viewModel.generateToken()
                }
            }
        }
    }

    // MARK: Provisioning rows

    private var serialRow: some View {
        settingsRow("Serial port") {
            HStack(spacing: 6) {
                if viewModel.availablePorts.isEmpty {
                    Text("No ESP32 detected")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("Serial port", selection: $viewModel.selectedPort) {
                        ForEach(viewModel.availablePorts) { port in
                            Text(port.displayName).tag(port as SerialPort?)
                        }
                    }
                    .labelsHidden()
                }

                iconButton("arrow.clockwise", help: "Refresh serial devices") {
                    viewModel.refreshPorts()
                }
            }
        }
    }

    private var networkRow: some View {
        settingsRow("Wi-Fi") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if showsNetworkPicker {
                        Picker("Network", selection: networkBinding) {
                            ForEach(viewModel.wifiScanner.networks, id: \.self) { ssid in
                                Text(ssid).tag(NetworkChoice.named(ssid))
                            }
                            Divider()
                            Text("Other Network...").tag(NetworkChoice.other)
                        }
                        .labelsHidden()
                    } else {
                        TextField("Network name", text: $viewModel.ssid)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }

                    scanButton
                }

                if showsManualNetworkField && showsNetworkPicker {
                    TextField("Network name", text: $viewModel.ssid)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }

                wifiStatusCaption
            }
        }
    }

    private var scanButton: some View {
        Button {
            Task { await handleScanTap() }
        } label: {
            if viewModel.wifiScanner.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning")
                }
            } else {
                Label("Scan", systemImage: "wifi")
            }
        }
        .labelStyle(.iconOnly)
        .help("Scan for Wi-Fi networks")
        .disabled(viewModel.wifiScanner.isScanning)
    }

    @ViewBuilder
    private var wifiStatusCaption: some View {
        let scanner = viewModel.wifiScanner
        if let err = scanner.errorMessage {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            switch scanner.permissionState {
            case .denied:
                Label(
                    "Location access is off. Open System Settings to enable Wi-Fi scanning.",
                    systemImage: "location.slash"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            case .awaitingUser:
                Label("Waiting for the permission prompt.", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .authorized, .unknown:
                EmptyView()
            }
        }
    }

    private var serverRow: some View {
        settingsRow("Server") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("Host or IP", text: $viewModel.serverHost)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("Port", value: $viewModel.serverPort, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: Self.portFieldWidth)
                }
                if let hostErr = viewModel.hostValidationMessage, !viewModel.serverHost.isEmpty {
                    Text(hostErr)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !viewModel.isPortValid {
                    Text("Port must be between 1 and 65535.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var otaDisclosure: some View {
        DisclosureGroup("OTA firmware updates") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("OTA password", text: $viewModel.otaPassword)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    iconButton(
                        "arrow.trianglehead.2.clockwise",
                        help: "Generate a new OTA password"
                    ) {
                        viewModel.generateOTAPassword()
                    }
                }
                if !viewModel.isOtaPasswordValid {
                    Text("Use at least \(Preferences.minimumSecretLength) characters.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(
                    "Required by ArduinoOTA for wireless flashes. Anyone on your network with "
                        + "this password can push code to the device."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    // MARK: Footer

    private var pairFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow

            HStack {
                Spacer(minLength: 0)
                Button("Pair Device") { pair() }
                    .buttonStyle(.glassProminent)
                    .disabled(!viewModel.canSend)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch viewModel.status {
        case .idle:
            EmptyView()
        case .sendingConfiguration:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending configuration to the device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .waitingForDevice(let serverConfigurationChanged):
            VStack(alignment: .leading, spacing: 8) {
                if isConnected {
                    Label("Sissy sees a device on Wi-Fi.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "Configuration sent. The device is rebooting.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        Text("Waiting for a device connection over Wi-Fi.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if serverConfigurationChanged || !model.serverHealth.status.isReachable {
                    serverActionRow(serverConfigurationChanged: serverConfigurationChanged)
                }
            }
        case .failure(let msg):
            Label("Pairing failed: \(msg)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func serverActionRow(serverConfigurationChanged: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(
                serverConfigurationChanged
                    ? "The token or port changed. Apply the saved server configuration before "
                        + "the device connects."
                    : model.pairingServerStatusText
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(model.pairingServerActionTitle) {
                model.applyPairingServerConfiguration()
            }
            .disabled(!model.canRunPairingServerAction)
        }
    }

    // MARK: Behaviour

    private func pair() {
        let serverConfigurationChanged =
            model.preferences.authToken != viewModel.authToken
            || model.preferences.serverPort != viewModel.serverPort

        model.preferences.authToken = viewModel.authToken
        model.preferences.serverPort = viewModel.serverPort
        model.savePreferences()
        viewModel.send(serverConfigurationChanged: serverConfigurationChanged)
    }

    private func handleScanTap() async {
        if viewModel.wifiScanner.permissionPermanentlyDenied {
            showLocationDeniedAlert = true
            return
        }
        await viewModel.scanWiFi()
    }

    /// Every control column starts at the same x and runs to the trailing
    /// edge. `LabeledContent` on its own right-aligns each control to its own
    /// width, which is what left the provisioning fields in a ragged column.
    private func settingsRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LabeledContent(label) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func iconButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .help(help)
        .frame(width: 24, height: 24)
    }

    private var metricBinding: Binding<Preferences.PrimaryMetric> {
        Binding(
            get: { model.preferences.primaryMetric },
            set: { model.selectMetric($0) }
        )
    }

    private var showsNetworkPicker: Bool {
        !viewModel.wifiScanner.networks.isEmpty
    }

    private var showsManualNetworkField: Bool {
        showOtherNetworkField
            || viewModel.wifiScanner.networks.isEmpty
            || viewModel.ssid.isEmpty
            || !viewModel.wifiScanner.networks.contains(viewModel.ssid)
    }

    private var networkBinding: Binding<NetworkChoice> {
        Binding(
            get: {
                if !viewModel.ssid.isEmpty, viewModel.wifiScanner.networks.contains(viewModel.ssid) {
                    return .named(viewModel.ssid)
                }
                return .other
            },
            set: { choice in
                switch choice {
                case .named(let ssid):
                    showOtherNetworkField = false
                    viewModel.pickSSID(ssid)
                case .other:
                    showOtherNetworkField = true
                }
            }
        )
    }
}

private enum NetworkChoice: Hashable {
    case named(String)
    case other
}
