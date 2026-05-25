import SwiftUI

struct PairingView: View {
    @EnvironmentObject var model: SissyModel
    @StateObject private var viewModel = PairingViewModel()
    @State private var showOtherNetworkField: Bool = false
    @State private var showLocationDeniedAlert: Bool = false

    private let labelWidth: CGFloat = 112

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Provision Wi-Fi, server, token, and OTA settings over USB serial.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    deviceSection
                    wifiSection
                    serverSection
                    advancedSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(
            minWidth: 560,
            idealWidth: 660,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 660,
            maxHeight: .infinity
        )
        .onAppear {
            viewModel.applyPreferences(model.preferences)
        }
        .alert("Location access is off", isPresented: $showLocationDeniedAlert) {
            Button("Open System Settings") {
                WiFiScanner.openSystemLocationSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "macOS requires Location access to read Wi-Fi network names. Enable Sissy in System Settings > Privacy & Security > Location Services, then scan again."
            )
        }
    }

    private var deviceSection: some View {
        pairingSection("Device") {
            pairingRow("Serial port", alignment: .center) {
                HStack(spacing: 8) {
                    if viewModel.availablePorts.isEmpty {
                        Text("No USB serial device detected")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Picker("Serial port", selection: selectedPortBinding) {
                            ForEach(viewModel.availablePorts) { port in
                                Text(port.displayName).tag(port as SerialPort?)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        viewModel.refreshPorts()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Refresh serial devices")
                    .frame(width: 28, height: 28)
                }
            }

            if viewModel.availablePorts.isEmpty {
                pairingRow("Status") {
                    Text("Plug in the ESP32, then refresh.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var wifiSection: some View {
        pairingSection("Wi-Fi") {
            pairingRow("Network", alignment: .top) {
                networkControl
            }

            pairingRow("Password", alignment: .center) {
                SecureField("Wi-Fi password", text: $viewModel.wifiPassword)
                    .textFieldStyle(.roundedBorder)
            }

            if hasWiFiStatus {
                pairingRow("Status") {
                    wifiStatusCaption
                }
            }
        }
    }

    private var networkControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if showsNetworkPicker {
                    Picker("Network", selection: networkBinding) {
                        ForEach(viewModel.wifiScanner.networks, id: \.self) { ssid in
                            Text(ssid).tag(NetworkChoice.named(ssid))
                        }
                        Divider()
                        Text("Other Network...").tag(NetworkChoice.other)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Network name", text: $viewModel.ssid)
                        .textFieldStyle(.roundedBorder)
                }

                scanButton
            }

            if showsManualNetworkField && showsNetworkPicker {
                TextField("Network name", text: $viewModel.ssid)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var scanButton: some View {
        Button {
            Task { await handleScanTap() }
        } label: {
            if viewModel.wifiScanner.isScanning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning")
                }
            } else {
                Label("Scan", systemImage: "wifi")
            }
        }
        .frame(minWidth: 92)
        .disabled(viewModel.wifiScanner.isScanning)
    }

    private var hasWiFiStatus: Bool {
        let scanner = viewModel.wifiScanner
        return scanner.errorMessage != nil
            || scanner.permissionState == .denied
            || scanner.permissionState == .awaitingUser
            || !scanner.networks.isEmpty
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
            case .authorized:
                if !scanner.networks.isEmpty {
                    Text("\(scanner.networks.count) Wi-Fi networks found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    EmptyView()
                }
            case .unknown:
                EmptyView()
            }
        }
    }

    private var serverSection: some View {
        pairingSection("Server") {
            pairingRow("Host", alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Host or IP", text: $viewModel.serverHost)
                        .textFieldStyle(.roundedBorder)

                    if let hostErr = viewModel.hostValidationMessage,
                        !viewModel.serverHost.isEmpty
                    {
                        Text(hostErr)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            pairingRow("Port", alignment: .center) {
                TextField("Port", value: $viewModel.serverPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90, alignment: .leading)
            }

            pairingRow("Auth token", alignment: .top) {
                tokenField
            }
        }
    }

    private var advancedSection: some View {
        pairingSection("Advanced") {
            DisclosureGroup("OTA firmware updates") {
                VStack(alignment: .leading, spacing: 8) {
                    pairingRow("Password", alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                TextField("OTA password", text: $viewModel.otaPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))

                                Button {
                                    viewModel.generateOTAPassword()
                                } label: {
                                    Label("Regenerate", systemImage: "arrow.clockwise")
                                }
                            }

                            if !viewModel.isOtaPasswordValid {
                                Text("Use at least \(Preferences.minimumSecretLength) characters.")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    pairingRow("Security") {
                        Text(
                            "Required by ArduinoOTA for wireless firmware flashes. Anyone on your network with this password can push code to the device."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if viewModel.revealToken {
                    TextField("Auth token", text: $viewModel.authToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                } else {
                    SecureField("Auth token", text: $viewModel.authToken)
                        .textFieldStyle(.roundedBorder)
                }

                Button {
                    viewModel.revealToken.toggle()
                } label: {
                    Label(
                        viewModel.revealToken ? "Hide token" : "Show token",
                        systemImage: viewModel.revealToken ? "eye.slash" : "eye"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(viewModel.revealToken ? "Hide token" : "Show token")
                .frame(width: 28, height: 28)

                Button {
                    viewModel.copyTokenToPasteboard()
                } label: {
                    Label("Copy token", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy token")
                .disabled(viewModel.authToken.isEmpty)
                .frame(width: 28, height: 28)

                Button {
                    viewModel.generateToken()
                } label: {
                    Label("Generate", systemImage: "wand.and.sparkles")
                }
            }

            if let info = viewModel.lastInfo {
                Text(info)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow

            HStack {
                Spacer()
                Button("Cancel") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)

                Button("Pair Device") {
                    let serverConfigurationChanged =
                        model.preferences.authToken != viewModel.authToken
                        || model.preferences.serverPort != viewModel.serverPort

                    model.preferences.authToken = viewModel.authToken
                    model.preferences.serverPort = viewModel.serverPort
                    model.savePreferences()
                    viewModel.send(serverConfigurationChanged: serverConfigurationChanged)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canSend)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch viewModel.status {
        case .idle:
            EmptyView()
        case .sendingConfiguration:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Sending configuration to the device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .waitingForDevice(let serverConfigurationChanged):
            VStack(alignment: .leading, spacing: 8) {
                if model.currentFrame?.devicePresent == true {
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
                    ? "The token or port changed. Apply the saved server configuration before the device connects."
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

    private func pairingSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
    }

    private func pairingRow<Content: View>(
        _ label: String,
        alignment: VerticalAlignment = .firstTextBaseline,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: behaviour

    private func handleScanTap() async {
        if viewModel.wifiScanner.permissionPermanentlyDenied {
            showLocationDeniedAlert = true
            return
        }
        await viewModel.scanWiFi()
    }

    private var selectedPortBinding: Binding<SerialPort?> {
        Binding(
            get: { viewModel.selectedPort },
            set: { viewModel.selectedPort = $0 }
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
                if !viewModel.ssid.isEmpty,
                    viewModel.wifiScanner.networks.contains(viewModel.ssid)
                {
                    return .named(viewModel.ssid)
                }
                return .other
            },
            set: { choice in
                switch choice {
                case .named(let s):
                    showOtherNetworkField = false
                    viewModel.pickSSID(s)
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
