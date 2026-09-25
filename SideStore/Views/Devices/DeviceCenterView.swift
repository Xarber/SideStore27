//
//  DeviceCenterView.swift
//  SideStore
//

import SwiftUI

#if !os(tvOS)
@MainActor
struct DeviceCenterView: View {
    @StateObject private var targets = CommandTargetManager.shared
    @StateObject private var stikServer = StikServerDeviceConnection.shared

    @State private var serverAddress = UserDefaults.standard.string(forKey: "StikServerAddress") ?? ""
    @State private var serverToken = Keychain.shared.stikServerAccessToken ?? ""
    @State private var importTarget: CommandTarget?
    @State private var isImportingPairing = false
    @State private var alertMessage: String?

    var body: some View {
        List {
            selectedSection
            nearbySection
            stikServerSection
            pairingSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    targets.startDiscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh Devices")
            }
        }
        .onAppear { targets.startDiscovery() }
        .onDisappear { targets.stopDiscovery() }
        .fileImporter(
            isPresented: $isImportingPairing,
            allowedContentTypes: PairingFileManager.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handlePairingImport(result)
        }
        .alert("Device Pairing", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var selectedSection: some View {
        Section {
            deviceRow(CommandTarget.local, selectable: true)
        } header: {
            Text("Install and Refresh On")
        } footer: {
            Text("The selected device is captured when an install or refresh starts. Changing it does not redirect an operation already in progress.")
        }
    }

    private var nearbySection: some View {
        Section {
            if targets.nearbyTargets.isEmpty {
                HStack(spacing: 12) {
                    if targets.isDiscovering { ProgressView() }
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    Text(targets.isDiscovering ? "Searching the local network…" : "No nearby devices found")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(targets.nearbyTargets) { target in
                    deviceRow(target, selectable: target.pairingFileURL != nil)
                }
            }
        } header: {
            HStack {
                Text("Nearby Devices")
                Spacer()
                if targets.isDiscovering { ProgressView().controlSize(.small) }
            }
        } footer: {
            Text("Unpaired devices remain visible. Import the pairing file from that device's row so SideStore can bind it to the correct network service.")
        }
    }

    private var stikServerSection: some View {
        Section {
            TextField("StikServer address or copied link", text: $serverAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Access token (optional)", text: $serverToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                switch stikServer.state {
                case .connected, .connecting:
                    stikServer.disconnect()
                case .disconnected, .failed:
                    connectStikServer()
                }
            } label: {
                HStack {
                    Image(systemName: stikServerButtonIcon)
                    Text(stikServerButtonTitle)
                    Spacer()
                    if case .connecting = stikServer.state { ProgressView() }
                }
            }

            if case .failed(let message) = stikServer.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            ForEach(targets.relayTargets) { target in
                deviceRow(target, selectable: target.supportsSideStoreOperations)
            }
        } header: {
            Text("StikServer")
        } footer: {
            if stikServer.state == .connected && targets.relayTargets.isEmpty {
                Text("Connected. No device currently advertises SideStore install support through this server.")
            } else {
                Text("A copied StikServer link can include its token; the separate token field may be left empty.")
            }
        }
    }

    private var pairingSection: some View {
        Section {
            NavigationLink {
                WirelessPairView(automaticallyPresentClient: true)
            } label: {
                Label("Pair a New Device", systemImage: "link.badge.plus")
            }

            NavigationLink {
                PairingFileManagementView()
            } label: {
                Label("Manage Pairing Files", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Device Pairing")
        }
    }

    @ViewBuilder
    private func deviceRow(_ target: CommandTarget, selectable: Bool) -> some View {
        Button {
            if selectable {
                targets.select(target)
            } else if target.kind == .nearby {
                importTarget = target
                isImportingPairing = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: deviceIcon(for: target))
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(targets.selectedTarget.id == target.id ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.name)
                        .foregroundStyle(.primary)
                    Text(deviceDetail(for: target, selectable: selectable))
                        .font(.caption)
                        .foregroundStyle(selectable ? Color.secondary : Color.orange)
                    if target.kind == .nearby,
                       let identifier = target.pairingIdentifier ?? target.advertisedServiceIdentifier,
                       identifier.caseInsensitiveCompare(target.name) != .orderedSame {
                        Text(identifier)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()
                if targets.selectedTarget.id == target.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                } else if target.kind == .nearby && !selectable {
                    Label("Import", systemImage: "doc.badge.plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .labelStyle(.titleAndIcon)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target.kind == .stikServer && !selectable)
    }

    private func connectStikServer() {
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            alertMessage = "Enter the address shown by StikServer."
            return
        }
        let token = StikServerDeviceConnection.accessToken(from: address, explicitToken: serverToken)
        UserDefaults.standard.set(address, forKey: "StikServerAddress")
        Keychain.shared.stikServerAccessToken = token
        serverToken = token
        targets.connectStikServer(address: address, token: token)
    }

    private func handlePairingImport(_ result: Result<[URL], Error>) {
        guard let target = importTarget else { return }
        importTarget = nil
        do {
            guard let url = try result.get().first else { return }
            let pairing = try PairingFileManager.shared.importRemotePairingFile(from: url, for: target)
            alertMessage = "\(pairing.displayName) is now paired with \(target.name)."
            targets.startDiscovery()
        } catch {
            alertMessage = "The pairing file could not be imported: \(error.localizedDescription)"
        }
    }

    private var stikServerButtonTitle: String {
        switch stikServer.state {
        case .disconnected, .failed: return "Connect"
        case .connecting: return "Cancel Connection"
        case .connected: return "Disconnect"
        }
    }

    private var stikServerButtonIcon: String {
        switch stikServer.state {
        case .disconnected, .failed: return "network.badge.shield.half.filled"
        case .connecting: return "xmark.circle"
        case .connected: return "network.slash"
        }
    }

    private func deviceIcon(for target: CommandTarget) -> String {
        let value = (target.deviceKind ?? target.name).lowercased()
        if target.kind == .stikServer { return "network" }
        if value.contains("ipad") { return "ipad" }
        return target.kind == .local ? "iphone" : "iphone.radiowaves.left.and.right"
    }

    private func deviceDetail(for target: CommandTarget, selectable: Bool) -> String {
        switch target.kind {
        case .local:
            return "This device"
        case .nearby:
            if selectable { return target.deviceKind ?? "Paired nearby device" }
            return "Pairing file required — tap to import"
        case .stikServer:
            if target.supportsSideStoreOperations { return target.deviceKind ?? "Connected through StikServer" }
            return "Visible in StikServer, but install relay is unavailable"
        }
    }
}
#endif
