//
//  WirelessPairViewModel.swift
//  SideStore
//
//  Created by Magesh K on 04/07/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SwiftUI
import Combine
import Network
import Minimuxer

enum SelectedEndpointOption: Equatable {
    case discovered(WirelessPairTarget)
    case nearby(CommandTarget)
    case configuredFallback
}

enum PairingMode: String {
    case server
    case client
}

struct WirelessPairTarget: Identifiable, Hashable {
    var id: String { service.id }
    let service: DiscoveredService
    var ipv4: String?
    var ipv6: String?
    var port: UInt16

    private var txt: [String: String] {
        guard case .bonjour(let record) = service.result.metadata else { return [:] }
        return record.dictionary.reduce(into: [String: String]()) {
            $0[$1.key.lowercased()] = $1.value
        }
    }
    
    var name: String {
        if let customName = txt["name"] ?? txt["devicename"], !customName.isEmpty {
            return customName
        }
        return service.name
            .replacingOccurrences(of: "._remotepairing-pairable-host._tcp.local.", with: "")
            .replacingOccurrences(of: "._remotepairing-manual-pairing._tcp.local.", with: "")
    }
    
    var rawType: String { service.type }
    
    var model: String? {
        txt["model"] ?? txt["modelidentifier"]
    }
    
    var uuid: String? {
        txt["uuid"] ?? txt["deviceid"] ?? txt["identifier"]
    }
    
    var typeBadge: String {
        if service.type.contains("manual-pairing") { return "Apple TV / Manual" }
        if service.type.contains("pairable-host") { return "Pairable Host" }
        if service.type.contains("remotepairing") { return "Remote Device" }
        return BonjourDiscoveryManager.friendlyName(for: service.type) ?? service.type
    }
    
    var iconName: String {
        if service.type.contains("manual-pairing") { return "appletv.fill" }
        if service.type.contains("pairable-host") { return "macbook.and.iphone" }
        return "antenna.radiowaves.left.and.right"
    }
}

@MainActor
final class WirelessPairViewModel: ObservableObject {
    // Server Advertising State
    @Published var statusText = "Ready to pair"
    @Published var subStatusText = "Tap Start to advertise this device on the local network."
    @Published var pinCode: String? = nil
    @Published var isAdvertising = false
    @Published var pairedDevice: MinimuxerPairedDevice? = nil
    @Published var errorMessage: String? = nil
    @Published var serviceID: String? = nil
    @Published var port: Int? = nil
    
    // Sheet / Dialog State
    @Published var isTargetDialogPresented = false
    @Published var dialogMode: PairingMode = .server
    @Published var selectedServerInterfaceId: String? = nil
    @Published var selectedOption: SelectedEndpointOption = .configuredFallback
    
    // Discovery State
    @Published var discoveredTargets: [WirelessPairTarget] = []
    @Published var nearbyTargets: [CommandTarget] = []
    @Published var isScanning = false
    @Published var activeInterfaces: [LocalInterfaceInfo] = []
    
    // Client PIN Prompt State
    @Published var isPinPromptPresented = false
    @Published var enteredPin = ""
    private var pinPromptCallback: ((String) -> Void)?
    
    // Share Sheet State
    @Published var shareSheetURL: URL? = nil
    @Published var isShareSheetPresented = false   
    
    private let pairingServiceTypes = [
        // A pairable-host advertisement is another computer/app waiting for
        // an iOS device to connect to it. Treating it as the target produces
        // an immediate EOF because both peers are acting as the host.
        "_remotepairing-manual-pairing._tcp"
    ]
    
    private let bonjour = BonjourDiscoveryManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var resolvingTasks: [String: Task<Void, Never>] = [:]
    
    var fallbackConfigEndpoint: (ip: String, port: UInt16) {
        let config = ConnectionConfig.shared
        let port = remotePairingPortCache != 0 ? remotePairingPortCache : AppConstants.Minimuxer.remotePairingPort

        guard config.useLocalVPN else {
            let remote = config.remoteServerIp.trimmingCharacters(in: .whitespacesAndNewlines)
            return (ip: !remote.isEmpty ? remote : AppConstants.Connection.defaultRemoteServerIP, port: port)
        }

        guard let ip = [config.overrideTunnelPeerIp, config.tunnelPeerIp]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return (ip: AppConstants.Connection.defaultOverrideIP, port: port)
        }

        return (ip: ip, port: port)
    }
    
    init() {
        debugLog("[WirelessPairViewModel] init() initializing...")
        activeInterfaces = minimuxer.network.activeInterfaces
        CommandTargetManager.shared.$nearbyTargets
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.nearbyTargets = $0 }
            .store(in: &cancellables)
        
        // Setup closures once
        wirelessPairing.onReadyToPair = { [weak self] (serviceID: String, port: Int) in
            debugLog("[WirelessPairViewModel] onReadyToPair callback received: serviceID='\(serviceID)', port=\(port)")
            Task { @MainActor in
                guard let self = self else { return }
                self.serviceID = serviceID
                self.port = port
                self.statusText = "Advertising server..."
                self.subStatusText = "Ensure both devices are on the same Wi-Fi."
            }
        }
        
        wirelessPairing.onPinReceived = { [weak self] (pin: String) in
            debugLog("[WirelessPairViewModel] onPinReceived callback received: pin='\(pin)'")
            Task { @MainActor in
                guard let self = self else { return }
                self.pinCode = pin
                self.statusText = "Device Connected"
                self.subStatusText = "Enter the pairing code shown below on your other device settings screen."
            }
        }
        
        wirelessPairing.onRequestPin = { [weak self] (submitPin: @escaping (String) -> Void) in
            debugLog("[WirelessPairViewModel] onRequestPin callback received from wirelessPairing")
            Task { @MainActor in
                guard let self = self else { return }
                self.pinPromptCallback = submitPin
                self.enteredPin = ""
                self.isPinPromptPresented = true
                self.statusText = "Enter Pairing PIN"
                self.subStatusText = "Enter the 6-digit code shown on your Apple TV / device screen."
            }
        }
    }
    
    func submitEnteredPin() {
        let pin = enteredPin.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalPin = pin.isEmpty ? "000000" : pin
        debugLog("[WirelessPairViewModel] submitEnteredPin() sending PIN '\(finalPin)' to gateway")
        pinPromptCallback?(finalPin)
        pinPromptCallback = nil
        isPinPromptPresented = false
        enteredPin = ""
    }
    
    func cancelPinPrompt() {
        debugLog("[WirelessPairViewModel] cancelPinPrompt() cancelling PIN prompt")
        pinPromptCallback?("000000")
        pinPromptCallback = nil
        isPinPromptPresented = false
        enteredPin = ""
    }
    
    private var discoveryTask: Task<Void, Never>?
    
    func refreshInterfaces() {
        debugLog("[WirelessPairViewModel] refreshInterfaces() scanning active interfaces...")
        activeInterfaces = minimuxer.network.activeInterfaces
        debugLog("[WirelessPairViewModel] refreshInterfaces() scan completed, found \(activeInterfaces.count) active interfaces:")
        for iface in activeInterfaces {
            debugLog("[WirelessPairViewModel]  -> \(iface.name) [\(iface.type.rawValue)]: ip=\(iface.ip), ipv6=\(iface.ipv6 ?? "none"), subnet=\(iface.subnet)")
        }
    }
    
    func selectDefaultServerInterface() {
        selectedServerInterfaceId = activeInterfaces
            .first(where: { $0.type == .wifi })?.id 
            ?? activeInterfaces
            .first(where: { $0.type.isVPN })?.id 
            ?? activeInterfaces.first?.id
        debugLog("[WirelessPairViewModel] selectDefaultServerInterface() selected: \(selectedServerInterfaceId ?? "none")")
    }
    
    func selectServerInterface(id: String) {
        debugLog("[WirelessPairViewModel] selectServerInterface(id: '\(id)')")
        selectedServerInterfaceId = id
    }
    
    func selectTarget(_ target: WirelessPairTarget) {
        debugLog("[WirelessPairViewModel] selectTarget() selected: '\(target.name)' (\(target.rawType)) -> v4=\(target.ipv4 ?? "none"), v6=\(target.ipv6 ?? "none"), port=\(target.port)")
        selectedOption = .discovered(target)
    }

    func selectNearbyTarget(_ target: CommandTarget) {
        selectedOption = .nearby(target)
    }

    func isNearbyTargetSelected(_ target: CommandTarget) -> Bool {
        if case .nearby(let selected) = selectedOption { return selected.id == target.id }
        return false
    }
    
    func selectFallbackEndpoint() {
        let fallback = fallbackConfigEndpoint
        debugLog("[WirelessPairViewModel] selectFallbackEndpoint() selected fallback: \(fallback.ip):\(fallback.port)")
        selectedOption = .configuredFallback
    }
    
    func isTargetSelected(_ target: WirelessPairTarget) -> Bool {
        if case .discovered(let selected) = selectedOption {
            return selected.id == target.id
        }
        return false
    }
    
    var isFallbackSelected: Bool {
        if case .configuredFallback = selectedOption {
            return true
        }
        return false
    }
    
    func openClientDialog() {
        debugLog("[WirelessPairViewModel] openClientDialog() opening client target pairing sheet")
        dialogMode = .client
        selectedOption = .configuredFallback
        startDiscovery()
        isTargetDialogPresented = true
    }
    
    func openServerDialog() {
        debugLog("[WirelessPairViewModel] openServerDialog() opening server interface selection sheet")
        if isAdvertising {
            debugLog("[WirelessPairViewModel] openServerDialog() already advertising, stopping pairing instead")
            stopPairing()
        } else {
            dialogMode = .server
            refreshInterfaces()
            selectDefaultServerInterface()
            isTargetDialogPresented = true
        }
    }
    
    func onDialogAppear() {
        debugLog("[WirelessPairViewModel] onDialogAppear (mode=\(dialogMode.rawValue), isPresented=\(isTargetDialogPresented))")
        if dialogMode == .server {
            refreshInterfaces()
            if selectedServerInterfaceId == nil {
                selectDefaultServerInterface()
            }
        } else {
            if discoveredTargets.isEmpty && !isScanning {
                debugLog("[WirelessPairViewModel] onDialogAppear discoveredTargets is empty and not scanning -> triggering startDiscovery()")
                startDiscovery()
            }
        }
    }
    
    func onDialogDisappear() {
        debugLog("[WirelessPairViewModel] onDialogDisappear (mode=\(dialogMode.rawValue))")
        if dialogMode == .client {
            stopDiscovery()
        }
    }
    
    func refreshDialog() {
        debugLog("[WirelessPairViewModel] refreshDialog (pull-to-refresh invoked for mode=\(dialogMode.rawValue))")
        if dialogMode == .client {
            startDiscovery()
        } else {
            refreshInterfaces()
        }
    }
    
    func dismissDialog() {
        debugLog("[WirelessPairViewModel] dismissDialog (mode=\(dialogMode.rawValue))")
        if dialogMode == .client {
            stopDiscovery()
        }
        isTargetDialogPresented = false
    }
    
    func confirmSelection() {
        debugLog("[WirelessPairViewModel] confirmSelection() invoked (mode=\(dialogMode.rawValue), option=\(selectedOption))")
        dismissDialog()
        
        if dialogMode == .client {
            switch selectedOption {
            case .discovered(let target):
                guard let targetIp = target.ipv4 ?? target.ipv6, target.port > 0 else {
                    errorMessage = "The selected device did not publish a reachable network address. Refresh while its pairing screen remains open."
                    statusText = "Device Unreachable"
                    subStatusText = "SideStore will not use a device identifier as a network address."
                    return
                }
                let targetPort = target.port
                debugLog("[WirelessPairViewModel] confirmSelection -> Connecting to target '\(target.name)' at \(targetIp):\(targetPort)")
                triggerPairing(targetIp: targetIp, targetPort: targetPort, targetName: target.name)
            case .nearby(let target):
                // _remotepairing._tcp is a paired device's service, not its
                // manual-pairing listener. Connecting a pairing client to it
                // closes the socket immediately with UnexpectedEof.
                if target.pairingFileURL != nil {
                    CommandTargetManager.shared.select(target)
                    statusText = "Already Paired"
                    subStatusText = "\(target.name) is already paired. It is now the selected device for SideStore commands."
                } else {
                    statusText = "Pairing Required"
                    subStatusText = "To pair \(target.name), use Start Pairing Server here and connect from the other device, or open that device's manual pairing screen. Its normal Nearby Devices endpoint cannot accept a new pairing."
                }
            case .configuredFallback:
                let fallback = fallbackConfigEndpoint
                debugLog("[WirelessPairViewModel] confirmSelection -> Connecting to configured fallback at \(fallback.ip):\(fallback.port)")
                triggerPairing(targetIp: fallback.ip, targetPort: fallback.port, targetName: "configured_host")
            }
        } else {
            debugLog("[WirelessPairViewModel] confirmSelection -> Starting server advertising (selectedInterfaceId=\(selectedServerInterfaceId ?? "none"))")
            startPairing()
        }
    }
    
    private func resolveEndpoint(for service: DiscoveredService) async -> (ipv4: String?, ipv6: String?, port: UInt16) {
        debugLog("[WirelessPairViewModel] resolveEndpoint() starting for '\(service.name)' (\(service.type))...")
        guard let resolved = await BonjourDiscoveryManager.resolveEndpointWithoutConnecting(service) else {
            debugLog("[WirelessPairViewModel] resolveEndpoint() passive resolution failed for '\(service.name)'")
            return (nil, nil, 0)
        }
        let ipv4 = resolved.addresses.first { !$0.contains(":") && $0 != "0.0.0.0" }
        let ipv6 = resolved.addresses.first { $0.contains(":") }
        debugLog("[WirelessPairViewModel] resolveEndpoint() resolved '\(service.name)': v4=\(ipv4 ?? "none"), v6=\(ipv6 ?? "none"), port=\(resolved.port)")
        return (ipv4, ipv6, resolved.port)
    }
    
    func startDiscovery() {
        discoveryTask?.cancel()
        isScanning = true
        discoveredTargets.removeAll()
        CommandTargetManager.shared.startDiscovery()
        
        discoveryTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            debugLog("[WirelessPairViewModel] startDiscovery() one-shot pass starting for types: \(self.pairingServiceTypes)")
            
            self.bonjour.discoverInstances(ofTypes: self.pairingServiceTypes, inDomain: "local.", clearExisting: true)
            
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else {
                debugLog("[WirelessPairViewModel] startDiscovery() Task was cancelled before instance snapshot")
                return
            }
            
            let instancesSnapshot = self.bonjour.instances
            debugLog("[WirelessPairViewModel] one-shot: gathered \(instancesSnapshot.count) Bonjour instances from BonjourDiscoveryManager:")
            for s in instancesSnapshot {
                debugLog("[WirelessPairViewModel]  -> instance: name='\(s.name)', type='\(s.type)', domain='\(s.domain)', id='\(s.id)'")
            }
            
            self.bonjour.stopInstanceSearch()
            debugLog("[WirelessPairViewModel] Bonjour search stopped, resolving \(instancesSnapshot.count) endpoints in parallel...")
            
            var finalTargets: [WirelessPairTarget] = []
            await withTaskGroup(of: WirelessPairTarget.self) { group in
                for service in instancesSnapshot {
                    group.addTask {
                        let (ipv4, ipv6, port) = await self.resolveEndpoint(for: service)
                        return WirelessPairTarget(service: service, ipv4: ipv4, ipv6: ipv6, port: port)
                    }
                }
                for await target in group {
                    finalTargets.append(target)
                }
            }
            
            guard !Task.isCancelled else {
                debugLog("[WirelessPairViewModel] startDiscovery() Task was cancelled during endpoint resolution")
                return
            }
            let grouped = Dictionary(grouping: finalTargets) { target in
                let identifier = target.uuid ?? target.name
                return identifier.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .unicodeScalars
                    .filter { CharacterSet.alphanumerics.contains($0) }
                    .map(String.init)
                    .joined()
            }
            self.discoveredTargets = grouped.values.compactMap { matches in
                matches.sorted { lhs, rhs in
                    if (lhs.ipv4 != nil) != (rhs.ipv4 != nil) { return lhs.ipv4 != nil }
                    if (lhs.port > 0) != (rhs.port > 0) { return lhs.port > 0 }
                    return lhs.rawType.contains("manual-pairing")
                }.first
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.isScanning = false
            debugLog("[WirelessPairViewModel] one-shot pass complete: \(self.discoveredTargets.count) targets ready:")
            for t in self.discoveredTargets {
                debugLog("[WirelessPairViewModel]  -> Target: '\(t.name)' [\(t.rawType)] - IPv4: \(t.ipv4 ?? "none"), IPv6: \(t.ipv6 ?? "none"), Port: \(t.port)")
            }
        }
    }
    
    func stopDiscovery() {
        debugLog("[WirelessPairViewModel] stopDiscovery() invoked")
        discoveryTask?.cancel()
        discoveryTask = nil
        isScanning = false
        bonjour.stopInstanceSearch()
    }
    
    func togglePairing() {
        debugLog("[WirelessPairViewModel] togglePairing() invoked (currently isAdvertising=\(isAdvertising))")
        if isAdvertising {
            stopPairing()
        } else {
            // binds to all ie, 0.0.0.0
            startPairing()
        }
    }
    
    func startPairing() {
        let docsPath = FileManager.default.documentsDirectory.path
        debugLog("[WirelessPairViewModel] startPairing() starting advertisement with base path: '\(docsPath)'")
        isAdvertising = true
        pinCode = nil
        errorMessage = nil
        serviceID = nil
        port = nil
        statusText = "Waiting for connection..."
        subStatusText = "Open Remote Pairing on your Apple TV / Vision Pro / host device to discover this server."
        
        wirelessPairing.start(
            outPath: docsPath,
            resolveFileName: { name, model in
                Self.pairingFileName(for: name, model: model)
            }
        ) { [weak self] (result: Result<MinimuxerPairedDevice, Swift.Error>) in
            Task { @MainActor in
                guard let self = self else { return }
                debugLog("[WirelessPairViewModel] startPairing() completion received: result=\(result), wasAdvertising=\(self.isAdvertising)")
                guard self.isAdvertising else { return }
                self.isAdvertising = false
                self.pinCode = nil
                self.serviceID = nil
                self.port = nil
                
                switch result {
                case .success(let device):
                    debugLog("[WirelessPairViewModel] startPairing() SUCCESS with device: name='\(device.name)', model='\(device.model)'")
                    self.pairedDevice = device
                    self.statusText = "Success!"
                    self.subStatusText = "Successfully paired with \(device.name) (\(device.model))!\nPairing file saved to documents."
                    self.shareSheetURL = URL(fileURLWithPath: device.pairingFilePath)
                    self.isShareSheetPresented = true
                    try? PairingFileManager.shared.registerGeneratedRemotePairingFile(
                        at: URL(fileURLWithPath: device.pairingFilePath),
                        displayName: device.name,
                        modelIdentifier: device.model
                    )
                    CommandTargetManager.shared.startDiscovery()
                case .failure(let error):
                    debugLog("[WirelessPairViewModel] startPairing() FAILURE: error='\(error.localizedDescription)'")
                    self.errorMessage = error.localizedDescription
                    self.statusText = "Pairing Failed"
                    self.subStatusText = "An error occurred during pairing."
                }
            }
        }
    }

    func stopPairing() {
        debugLog("[WirelessPairViewModel] stopPairing() stopping advertisement and tearing down session")
        wirelessPairing.stop()
        
        isAdvertising = false
        statusText = "Ready to pair"
        subStatusText = "Tap Start to advertise this device on the local network."
        pinCode = nil
        errorMessage = nil
        serviceID = nil
        port = nil
    }
    
    func triggerPairing(
        targetIp: String,
        targetPort: UInt16,
        targetName: String? = nil,
        completion: ((Result<MinimuxerPairedDevice, Swift.Error>) -> Void)? = nil
    ) {
        let docsPath = FileManager.default.documentsDirectory.path
        debugLog("[WirelessPairViewModel] triggerPairing() initiating handshake to \(targetIp):\(targetPort), base path: '\(docsPath)'")
        isAdvertising = true
        pinCode = nil
        errorMessage = nil
        serviceID = nil
        port = nil
        statusText = "Connecting to device..."
        subStatusText = "Initiating pairing handshake on \(targetIp):\(targetPort)..."
        
        wirelessPairing.trigger(
            targetIp: targetIp,
            targetPort: targetPort,
            outPath: docsPath,
            resolveFileName: { name, model in
                Self.pairingFileName(for: name.isEmpty ? targetName : name, model: model)
            }
        ) { [weak self] (result: Result<MinimuxerPairedDevice, Swift.Error>) in
            Task { @MainActor in
                guard let self = self else { return }
                debugLog("[WirelessPairViewModel] triggerPairing() completion received: result=\(result)")
                self.isAdvertising = false
                self.pinCode = nil
                self.serviceID = nil
                self.port = nil
                
                switch result {
                case .success(let device):
                    debugLog("[WirelessPairViewModel] triggerPairing() SUCCESS with device: name='\(device.name)', model='\(device.model)'")
                    self.pairedDevice = device
                    self.statusText = "Success!"
                    self.subStatusText = "Successfully paired with \(device.name) (\(device.model))!\nPairing file saved to documents."
                    self.shareSheetURL = URL(fileURLWithPath: device.pairingFilePath)
                    self.isShareSheetPresented = true
                    try? PairingFileManager.shared.registerGeneratedRemotePairingFile(
                        at: URL(fileURLWithPath: device.pairingFilePath),
                        displayName: device.name,
                        modelIdentifier: device.model
                    )
                    CommandTargetManager.shared.startDiscovery()
                case .failure(let error):
                    debugLog("[WirelessPairViewModel] triggerPairing() FAILURE: error='\(error.localizedDescription)'")
                    let detail = error.localizedDescription
                    self.errorMessage = detail.localizedCaseInsensitiveContains("UnexpectedEof")
                        ? "This endpoint closed the pairing handshake. Choose a device advertising manual pairing, or use Start Pairing Server and connect from the other device."
                        : detail
                    self.statusText = "Pairing Failed"
                    self.subStatusText = self.errorMessage ?? detail
                }
                completion?(result)
            }
        }
    }
    
    nonisolated static func pairingFileName(for deviceName: String? = nil, model: String? = nil) -> String {
        let namePart = deviceName ?? ""
        let modelPart = model ?? ""
        let combined = [namePart, modelPart].filter { !$0.isEmpty }.joined(separator: "_")
        if !combined.isEmpty {
            let spaceReplaced = combined
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
            let sanitized = spaceReplaced.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
            let finalName = sanitized.isEmpty ? "device" : sanitized
            return "\(finalName)_\(UUID().uuidString)\(AppConstants.Minimuxer.rpPairingFileSuffix)"
        }
        return "SideStoreRemote_\(UUID().uuidString)\(AppConstants.Minimuxer.rpPairingFileSuffix)"
    }

    private func pairingFilePath(for deviceName: String? = nil, model: String? = nil) -> String {
        let docs = FileManager.default.documentsDirectory
        let fileName = Self.pairingFileName(for: deviceName, model: model)
        return docs.appendingPathComponent(fileName).path
    }
}
