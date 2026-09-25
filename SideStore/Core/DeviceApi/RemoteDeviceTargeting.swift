//
//  RemoteDeviceTargeting.swift
//  SideStore
//
//  Device and account selection are intentionally independent. A target is
//  snapshotted when an operation starts so changing the picker cannot retarget
//  an in-flight install or refresh.
//

import Combine
import Foundation
import Minimuxer
import MinimuxerCommon
import Network
import SideSign
import UIKit

enum CommandTargetKind: String, Codable, Sendable {
    case local
    case nearby
    case stikServer
}

struct CommandTarget: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: CommandTargetKind
    var deviceKind: String? = nil
    var pairingIdentifier: String? = nil
    var advertisedServiceIdentifier: String? = nil
    var discoveryServiceID: String? = nil
    var discoveryServiceType: String? = nil
    var host: String?
    var port: UInt16?
    var pairingFilePath: String?
    var serverAddress: String?
    var serverToken: String?
    var relayDeviceID: String?
    var relayCapabilities: Set<String> = []

    static let local = CommandTarget(
        id: "local",
        name: String(format: NSLocalizedString("This %@", comment: "Local command target"), UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"),
        kind: .local,
        deviceKind: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    )

    var pairingFileURL: URL? {
        pairingFilePath.map { URL(fileURLWithPath: $0) }
    }

    var supportsSideStoreOperations: Bool {
        kind != .stikServer || relayCapabilities.contains("sidestore.device.v1") || relayDeviceID?.hasPrefix("sidestore-agent|") == true
    }

    var developerPortalDeviceType: ALTDeviceType {
        let value = (deviceKind ?? name).lowercased()
        if value.contains("ipad") { return .ipad }
        if value.contains("appletv") || value.contains("apple tv") || value.contains("tvos") { return .tv }
        if value.contains("watch") { return .watch }
        if value.contains("vision") { return .vision }
        return .iphone
    }
}

extension Notification.Name {
    static let commandTargetDidChange = Notification.Name("SideStore.commandTargetDidChange")
    static let commandTargetsDidChange = Notification.Name("SideStore.commandTargetsDidChange")
    static let commandTargetConnectionFailed = Notification.Name("SideStore.commandTargetConnectionFailed")
    static let signingAccountDidChange = Notification.Name("SideStore.signingAccountDidChange")
}

@MainActor
final class CommandTargetManager: ObservableObject {
    static let shared = CommandTargetManager()

    @Published private(set) var selectedTarget: CommandTarget
    @Published private(set) var nearbyTargets: [CommandTarget] = []
    @Published private(set) var relayTargets: [CommandTarget] = []
    @Published private(set) var isDiscovering = false

    private let selectedTargetKey = "SelectedCommandTarget"
    private var cancellables = Set<AnyCancellable>()
    private var resolutionTasks: [String: Task<Void, Never>] = [:]

    private init() {
        // A relaunch always returns to the safe, ordinary SideStore workflow.
        // Remote choices remain explicit for each app session.
        selectedTarget = .local
        UserDefaults.standard.removeObject(forKey: selectedTargetKey)

        BonjourDiscoveryManager.shared.$instances
            .receive(on: RunLoop.main)
            .sink { [weak self] services in self?.updateNearbyTargets(from: services) }
            .store(in: &cancellables)

        StikServerDeviceConnection.shared.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in self?.updateRelayTargets(from: devices) }
            .store(in: &cancellables)
    }

    nonisolated func snapshot() async -> CommandTarget {
        await MainActor.run { selectedTarget }
    }

    func select(_ target: CommandTarget) {
        guard target != selectedTarget else { return }
        selectedTarget = target
        if let data = try? JSONEncoder().encode(target) {
            UserDefaults.standard.set(data, forKey: selectedTargetKey)
        }
        NotificationCenter.default.post(name: .commandTargetDidChange, object: target)
    }

    func startDiscovery() {
        isDiscovering = true
        BonjourDiscoveryManager.shared.discoverInstances(
            // CoreDevice remote pairing is the supported network path on modern
            // iOS. _apple-mobdev2 also exposes this device's loopback lockdown
            // service, which made the local UDID look like a remote IP address.
            ofTypes: ["_remotepairing._tcp."],
            clearExisting: true
        )
    }

    func stopDiscovery() {
        isDiscovering = false
        BonjourDiscoveryManager.shared.stopInstanceSearch()
        resolutionTasks.values.forEach { $0.cancel() }
        resolutionTasks.removeAll()
    }

    func connectStikServer(address: String, token: String) {
        let resolvedToken = StikServerDeviceConnection.accessToken(from: address, explicitToken: token)
        StikServerDeviceConnection.shared.connect(serverAddress: address, token: resolvedToken)
        SideStoreRelayAgentManager.shared.connect(serverAddress: address, token: resolvedToken)
    }

    private func updateNearbyTargets(from services: [DiscoveredService]) {
        let services = services.filter {
            $0.type.contains("_remotepairing._tcp")
                && !$0.type.contains("manual-pairing")
                && !$0.type.contains("pairable-host")
        }
        let pairings = PairingFileManager.shared.remotePairingFiles()
        let visibleServiceIDs = Set(services.map(\.id))
        for serviceID in Array(resolutionTasks.keys) where !visibleServiceIDs.contains(serviceID) {
            resolutionTasks.removeValue(forKey: serviceID)?.cancel()
        }
        let previousCount = nearbyTargets.count
        nearbyTargets.removeAll { target in
            guard let serviceID = target.discoveryServiceID else { return false }
            return !visibleServiceIDs.contains(serviceID)
        }
        if nearbyTargets.count != previousCount {
            NotificationCenter.default.post(name: .commandTargetsDidChange, object: nil)
            updateRelayTargets(from: StikServerDeviceConnection.shared.devices)
        }

        for service in services where resolutionTasks[service.id] == nil {
            resolutionTasks[service.id] = Task { [weak self] in
                guard let self else { return }
                let resolved = await Self.resolve(service)
                guard !Task.isCancelled, let resolved else { return }
                let txt = service.txtRecords.reduce(into: [String: String]()) {
                    $0[$1.key.lowercased()] = $1.value
                }
                // Publish unpaired devices too. The old flow hid them until a
                // pairing file had somehow already been associated, making a
                // successful import appear to do nothing.
                let compatiblePairings = pairings.filter { $0.mode == .rppairing }
                let advertisedIdentifiers = [txt["identifier"], txt["uuid"], txt["deviceid"], txt["udid"]]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let serviceIdentifier = advertisedIdentifiers.first ?? service.name
                let normalizedName = Self.normalizedDeviceName(
                    txt["name"] ?? txt["devicename"] ?? service.name
                )
                let pairing = compatiblePairings.first(where: {
                    $0.serviceIdentifier?.caseInsensitiveCompare(service.id) == .orderedSame
                        || $0.serviceIdentifier?.caseInsensitiveCompare(serviceIdentifier) == .orderedSame
                }) ?? compatiblePairings.first(where: {
                    Self.normalizedDeviceName($0.displayName) == normalizedName
                })
                let displayName = txt["name"]
                    ?? txt["devicename"]
                    ?? pairing?.displayName
                    ?? service.name
                let id = serviceIdentifier.lowercased()
                let target = CommandTarget(
                    id: "nearby|\(id)",
                    name: displayName,
                    kind: .nearby,
                    deviceKind: txt["model"] ?? txt["modelidentifier"] ?? txt["deviceclass"] ?? txt["kind"] ?? pairing?.modelIdentifier,
                    pairingIdentifier: pairing?.deviceIdentifier ?? advertisedIdentifiers.first,
                    advertisedServiceIdentifier: serviceIdentifier,
                    discoveryServiceID: service.id,
                    discoveryServiceType: service.type,
                    host: resolved.host,
                    port: resolved.port,
                    pairingFilePath: pairing?.url.path
                )
                if let index = self.nearbyTargets.firstIndex(where: { $0.id == target.id }) {
                    guard self.nearbyTargets[index] != target else { return }
                    self.nearbyTargets[index] = target
                    if self.selectedTarget.id == target.id {
                        self.select(target)
                    }
                    NotificationCenter.default.post(name: .commandTargetsDidChange, object: nil)
                    self.updateRelayTargets(from: StikServerDeviceConnection.shared.devices)
                } else {
                    self.nearbyTargets.append(target)
                    self.nearbyTargets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    NotificationCenter.default.post(name: .commandTargetsDidChange, object: nil)
                    self.updateRelayTargets(from: StikServerDeviceConnection.shared.devices)
                }
            }
        }
    }

    private func updateRelayTargets(from devices: [StikServerDevice]) {
        let connection = StikServerDeviceConnection.shared
        let directIdentifiers = Set(nearbyTargets.flatMap {
            [$0.pairingIdentifier, $0.advertisedServiceIdentifier].compactMap { $0?.lowercased() }
        })
        var bestRoutes: [String: StikServerDevice] = [:]
        for device in devices {
            let routeKey = device.pairingIdentifier?.lowercased() ?? device.id
            guard !directIdentifiers.contains(routeKey) else { continue }
            if let current = bestRoutes[routeKey] {
                let currentSupported = Self.supportsSideStore(current)
                let candidateSupported = Self.supportsSideStore(device)
                if currentSupported != candidateSupported {
                    if currentSupported { continue }
                } else if Self.routeCost(current) <= Self.routeCost(device) {
                    continue
                }
            }
            bestRoutes[routeKey] = device
        }
        relayTargets = bestRoutes.values.map { device in
            CommandTarget(
                id: "stikserver|\(device.id)",
                name: device.name,
                kind: .stikServer,
                deviceKind: device.kind,
                pairingIdentifier: device.pairingIdentifier,
                serverAddress: connection.serverAddress,
                serverToken: connection.accessToken,
                relayDeviceID: device.id,
                relayCapabilities: Set(device.capabilities ?? [])
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let refreshed = relayTargets.first(where: { $0.id == selectedTarget.id }), refreshed != selectedTarget {
            select(refreshed)
        }
        NotificationCenter.default.post(name: .commandTargetsDidChange, object: nil)
    }

    private static func supportsSideStore(_ device: StikServerDevice) -> Bool {
        device.id.hasPrefix("sidestore-agent|")
            || (device.capabilities ?? []).contains("sidestore.device.v1")
    }

    private static func routeCost(_ device: StikServerDevice) -> Int {
        device.mode == "direct" ? 0 : (device.routeHops ?? Int.max)
    }

    private static func resolve(_ service: DiscoveredService) async -> (host: String, port: UInt16)? {
        guard let resolved = await BonjourDiscoveryManager.resolveEndpointWithoutConnecting(service) else { return nil }
        let host = resolved.addresses.first(where: { !$0.contains(":") }) ?? resolved.addresses.first
        guard let host else { return nil }
        return (host, resolved.port)
    }

    private static func normalizedDeviceName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

struct RemotePairingFile: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    let url: URL
    let identifier: String?
    let mode: PairingProtocol
    let displayName: String
    let deviceIdentifier: String?
    let modelIdentifier: String?
    let serviceIdentifier: String?
    let createdAt: Date
    let lastConnectedAt: Date?
}

private struct RemotePairingMetadata: Codable, Sendable {
    let fileName: String
    var displayName: String
    var deviceIdentifier: String?
    var modelIdentifier: String?
    var serviceIdentifier: String?
    var createdAt: Date
    var lastConnectedAt: Date?
}

extension PairingFileManager {
    private static var remotePairingMetadataKey: String { "SideStoreRemotePairingMetadata.v1" }

    @discardableResult
    func importRemotePairingFile(from sourceURL: URL) throws -> RemotePairingFile {
        let (content, parsed) = try inspectPairingFile(from: sourceURL)
        let identifier: String?
        let deviceIdentifier: String?
        if let remote = parsed as? RPPairingFile {
            identifier = remote.identifier
            deviceIdentifier = nil
        } else if let lockdown = parsed as? LockdownPairingFile {
            identifier = lockdown.udid
            deviceIdentifier = lockdown.udid
        } else {
            throw RemoteDeviceError.missingPairingFile
        }
        if let existing = remotePairingFiles().first(where: {
            (try? String(contentsOf: $0.url)) == content
        }) {
            return existing
        }

        let sourceStem = sourceURL.deletingPathExtension()
        let modelIdentifier = sourceStem.pathExtension.isEmpty ? nil : sourceStem.pathExtension
        let sourceName = sourceStem.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = sourceName.isEmpty ? "Imported Device" : sourceName
        let fileName = "SideStoreRemote_\(UUID().uuidString).plist"
        let destinationURL = FileManager.default.documentsDirectory.appendingPathComponent(fileName)
        try content.write(to: destinationURL, atomically: true, encoding: .utf8)
        var metadata = remotePairingMetadata()
        let record = RemotePairingMetadata(
            fileName: fileName,
            displayName: displayName,
            deviceIdentifier: deviceIdentifier,
            modelIdentifier: modelIdentifier,
            serviceIdentifier: nil,
            createdAt: Date(),
            lastConnectedAt: nil
        )
        metadata.removeAll { $0.fileName == fileName }
        metadata.append(record)
        saveRemotePairingMetadata(metadata)
        return RemotePairingFile(
            url: destinationURL,
            identifier: identifier,
            mode: parsed.mode,
            displayName: displayName,
            deviceIdentifier: deviceIdentifier,
            modelIdentifier: modelIdentifier,
            serviceIdentifier: nil,
            createdAt: record.createdAt,
            lastConnectedAt: nil
        )
    }

    @discardableResult
    func importRemotePairingFile(from sourceURL: URL, for target: CommandTarget) throws -> RemotePairingFile {
        let file = try importRemotePairingFile(from: sourceURL)
        bindRemotePairingFile(file, to: target, deviceIdentifier: file.deviceIdentifier)
        return remotePairingFiles().first(where: { $0.url == file.url }) ?? file
    }

    @discardableResult
    func registerGeneratedRemotePairingFile(
        at url: URL,
        displayName: String,
        modelIdentifier: String?
    ) throws -> RemotePairingFile {
        let content = try String(contentsOf: url)
        let parsed = try parse(content: content)
        let identifier: String?
        let deviceIdentifier: String?
        if let remote = parsed as? RPPairingFile {
            identifier = remote.identifier
            deviceIdentifier = nil
        } else if let lockdown = parsed as? LockdownPairingFile {
            identifier = lockdown.udid
            deviceIdentifier = lockdown.udid
        } else {
            throw RemoteDeviceError.missingPairingFile
        }
        var metadata = remotePairingMetadata()
        let existing = metadata.first(where: { $0.fileName == url.lastPathComponent })
        let createdAt = existing?.createdAt ?? Date()
        let record = RemotePairingMetadata(
            fileName: url.lastPathComponent,
            displayName: displayName.isEmpty ? "Paired Device" : displayName,
            deviceIdentifier: deviceIdentifier,
            modelIdentifier: modelIdentifier,
            serviceIdentifier: existing?.serviceIdentifier,
            createdAt: createdAt,
            lastConnectedAt: existing?.lastConnectedAt
        )
        metadata.removeAll { $0.fileName == url.lastPathComponent }
        metadata.append(record)
        saveRemotePairingMetadata(metadata)
        return RemotePairingFile(
            url: url,
            identifier: identifier,
            mode: parsed.mode,
            displayName: record.displayName,
            deviceIdentifier: deviceIdentifier,
            modelIdentifier: modelIdentifier,
            serviceIdentifier: record.serviceIdentifier,
            createdAt: createdAt,
            lastConnectedAt: record.lastConnectedAt
        )
    }

    nonisolated func remotePairingFiles() -> [RemotePairingFile] {
        let directory = FileManager.default.documentsDirectory
        let localPaths = Set([
            pairingFileURL(for: .rppairing).standardizedFileURL.path,
            pairingFileURL(for: .lockdown).standardizedFileURL.path,
            FileManager.default.documentsDirectory
                .appendingPathComponent(AppConstants.Pairing.legacyPairingFileName)
                .standardizedFileURL.path
        ])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let records = remotePairingMetadata().reduce(into: [String: RemotePairingMetadata]()) {
            $0[$1.fileName] = $1
        }
        return files.compactMap { url in
            guard !localPaths.contains(url.standardizedFileURL.path),
                  AppConstants.Pairing.supportedExtensions.contains(url.pathExtension.lowercased()),
                  let content = try? String(contentsOf: url),
                  let parsed = try? parse(content: content) else { return nil }
            let identifier: String?
            if let rp = parsed as? RPPairingFile { identifier = rp.identifier }
            else if let lockdown = parsed as? LockdownPairingFile { identifier = lockdown.udid }
            else { identifier = nil }
            let record = records[url.lastPathComponent]
            let fallbackName = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "SideStoreRemote_", with: "")
            return RemotePairingFile(
                url: url,
                identifier: identifier,
                mode: parsed.mode,
                displayName: record?.displayName ?? fallbackName,
                deviceIdentifier: record?.deviceIdentifier ?? (parsed as? LockdownPairingFile)?.udid,
                modelIdentifier: record?.modelIdentifier,
                serviceIdentifier: record?.serviceIdentifier,
                createdAt: record?.createdAt ?? ((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast),
                lastConnectedAt: record?.lastConnectedAt
            )
        }.sorted {
            ($0.lastConnectedAt ?? $0.createdAt) > ($1.lastConnectedAt ?? $1.createdAt)
        }
    }

    nonisolated func remotePairingFiles(for target: CommandTarget) -> [RemotePairingFile] {
        let mode: PairingProtocol = target.discoveryServiceType?.contains("apple-mobdev2") == true ? .lockdown : .rppairing
        let files = remotePairingFiles().filter { $0.mode == mode }
        return files.sorted { lhs, rhs in
            let lhsExact = lhs.url.path == target.pairingFilePath || lhs.serviceIdentifier == target.discoveryServiceID
            let rhsExact = rhs.url.path == target.pairingFilePath || rhs.serviceIdentifier == target.discoveryServiceID
            if lhsExact != rhsExact { return lhsExact }
            return (lhs.lastConnectedAt ?? lhs.createdAt) > (rhs.lastConnectedAt ?? rhs.createdAt)
        }
    }

    nonisolated func bindRemotePairingFile(
        _ file: RemotePairingFile,
        to target: CommandTarget,
        deviceIdentifier: String?
    ) {
        var metadata = remotePairingMetadata()
        let now = Date()
        if let index = metadata.firstIndex(where: { $0.fileName == file.url.lastPathComponent }) {
            metadata[index].displayName = target.name
            metadata[index].deviceIdentifier = deviceIdentifier ?? metadata[index].deviceIdentifier
            metadata[index].modelIdentifier = target.deviceKind ?? metadata[index].modelIdentifier
            metadata[index].serviceIdentifier = target.advertisedServiceIdentifier ?? target.discoveryServiceID
            metadata[index].lastConnectedAt = now
        } else {
            metadata.append(RemotePairingMetadata(
                fileName: file.url.lastPathComponent,
                displayName: target.name,
                deviceIdentifier: deviceIdentifier,
                modelIdentifier: target.deviceKind,
                serviceIdentifier: target.advertisedServiceIdentifier ?? target.discoveryServiceID,
                createdAt: file.createdAt,
                lastConnectedAt: now
            ))
        }
        saveRemotePairingMetadata(metadata)
    }

    nonisolated func deleteRemotePairingFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        var metadata = remotePairingMetadata()
        metadata.removeAll { $0.fileName == url.lastPathComponent }
        saveRemotePairingMetadata(metadata)
    }

    private nonisolated func remotePairingMetadata() -> [RemotePairingMetadata] {
        guard let data = UserDefaults.standard.data(forKey: Self.remotePairingMetadataKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RemotePairingMetadata].self, from: data)) ?? []
    }

    private nonisolated func saveRemotePairingMetadata(_ metadata: [RemotePairingMetadata]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return }
        UserDefaults.standard.set(data, forKey: Self.remotePairingMetadataKey)
    }
}

enum DeviceOperationScope {
    @TaskLocal static var scopedTarget: CommandTarget?
    @TaskLocal static var isSessionActive = false
    @TaskLocal static var relayOperationID: String?

    static var target: CommandTarget { scopedTarget ?? .local }

    static var requiresIPA: Bool { target.kind == .stikServer }

    static func resolvedTarget() async -> CommandTarget {
        if let scopedTarget { return scopedTarget }
        return await CommandTargetManager.shared.snapshot()
    }
}

enum RemoteDeviceError: LocalizedError {
    case missingPairingFile
    case missingLocalPairingFile
    case missingEndpoint
    case unsupportedRelay
    case relayDisconnected
    case invalidRelayResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingPairingFile: return "The selected device's pairing file is missing. Pair that device again without replacing this device's main pairing identity."
        case .missingLocalPairingFile: return "SideStore cannot open a remote device session because this device's main pairing identity is unavailable. Pair this device again first."
        case .missingEndpoint: return "The selected nearby device no longer has a reachable endpoint."
        case .unsupportedRelay: return "This relay node does not advertise SideStore device-operation support. Open a compatible SideStore relay on the device's network."
        case .relayDisconnected: return "The StikServer relay disconnected during the operation."
        case .invalidRelayResponse(let reason): return "StikServer returned an invalid response: \(reason)"
        }
    }
}

private actor DeviceSessionSerializer {
    static let shared = DeviceSessionSerializer()
    private var previous: Task<Void, Never>?

    func run<T: Sendable>(
        target: CommandTarget,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let predecessor = previous
        let task = Task<T, Error> {
            _ = await predecessor?.result
            try Task.checkCancellation()
            return try await DeviceOperationScope.$scopedTarget.withValue(target) {
                try await DeviceOperationScope.$isSessionActive.withValue(true) {
                    try await DeviceSessionCoordinator.shared.withSession(for: target, operation: operation)
                }
            }
        }
        previous = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

enum DeviceOperationSession {
    static func run<T: Sendable>(
        target: CommandTarget,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await DeviceSessionSerializer.shared.run(target: target, operation: operation)
    }
}

private actor DeviceSessionCoordinator {
    static let shared = DeviceSessionCoordinator()

    func withSession<T: Sendable>(
        for target: CommandTarget,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        switch target.kind {
        case .local:
            return try await operation()
        case .stikServer:
            guard target.supportsSideStoreOperations else { throw RemoteDeviceError.unsupportedRelay }
            let operationID = UUID().uuidString
            try await StikServerDeviceConnection.shared.beginOperation(target: target, operationID: operationID)
            do {
                let result = try await DeviceOperationScope.$relayOperationID.withValue(operationID) {
                    try await operation()
                }
                await StikServerDeviceConnection.shared.endOperation(
                    target: target,
                    operationID: operationID
                )
                return result
            } catch {
                await StikServerDeviceConnection.shared.endOperation(
                    target: target,
                    operationID: operationID
                )
                throw error
            }
        case .nearby:
            guard let host = target.host, !host.isEmpty else { throw RemoteDeviceError.missingEndpoint }
            let candidateFiles = PairingFileManager.shared.remotePairingFiles(for: target)
            guard !candidateFiles.isEmpty else { throw RemoteDeviceError.missingPairingFile }

            guard let localPairing = PairingFileManager.shared.fetchPairingFile() else {
                throw RemoteDeviceError.missingLocalPairingFile
            }
            let config = ConnectionConfigBinding(
                setTunnelIfaceIp: { _ in }, setTunnelPeerIp: { _ in },
                setTunnelPeerSubnetMask: { _ in }, setTunnelPeerReachable: { _ in },
                setTunnelIfaceSubnetMask: { _ in }, getRemoteServerIp: { host },
                setRemoteReachable: { _ in }, getOverrideTunnelPeerIp: { "" },
                setOverrideTunnelPeerReachable: { _ in }, getConnectionMode: { .remoteServer }
            )
            do {
                await minimuxer.core.bindConnectionConfig(config)
                var connectedFile: RemotePairingFile?
                var lastError: Error?
                for file in candidateFiles {
                    do {
                        let pairing = try String(contentsOf: file.url)
                        let port = target.port ?? file.mode.defaultPort
                        minimuxer.gateway.setPort(port, for: file.mode)
                        try await minimuxer.core.reinitializePairingData(pairingFile: pairing)
                        if case .failure(let error) = await minimuxer.core.isReady(withNetworkCheck: true) {
                            throw error.asOperationError
                        }
                        connectedFile = file
                        break
                    } catch {
                        lastError = error
                    }
                }
                guard let connectedFile else {
                    throw lastError ?? RemoteDeviceError.missingPairingFile
                }
                let deviceIdentifier = try? await minimuxer.core.fetchUDID()
                PairingFileManager.shared.bindRemotePairingFile(
                    connectedFile,
                    to: target,
                    deviceIdentifier: deviceIdentifier
                )
                let result = try await operation()
                try await restoreLocal(pairing: localPairing)
                return result
            } catch {
                try? await restoreLocal(pairing: localPairing)
                throw error
            }
        }
    }

    private func restoreLocal(pairing: String) async throws {
        await bindConnectionConfig()
        minimuxer.set(MinimuxerParams(remotePairingPort: remotePairingPortCache))
        minimuxer.gateway.setPort(PairingProtocol.lockdown.defaultPort, for: .lockdown)
        try await minimuxer.core.reinitializePairingData(pairingFile: pairing)
    }
}

struct StikServerDevice: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String?
    let pairingIdentifier: String?
    let routeHops: Int?
    let connected: Bool?
    let controllable: Bool?
    let capabilities: [String]?
    let mode: String?
}

enum StikServerConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

@MainActor
final class StikServerDeviceConnection: ObservableObject {
    static let shared = StikServerDeviceConnection()

    @Published private(set) var devices: [StikServerDevice] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var state: StikServerConnectionState = .disconnected
    private(set) var serverAddress = ""
    private(set) var accessToken = ""

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var connectionTimeout: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]

    func connect(serverAddress: String, token: String) {
        disconnect()
        guard let url = Self.socketURL(serverAddress, token: token, role: "viewer") else {
            let error = NSError(
                domain: "StikServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid StikServer address"]
            )
            errorMessage = error.localizedDescription
            state = .failed(error.localizedDescription)
            NotificationCenter.default.post(name: .commandTargetConnectionFailed, object: error)
            return
        }
        self.serverAddress = serverAddress
        accessToken = Self.accessToken(from: serverAddress, explicitToken: token)
        errorMessage = nil
        state = .connecting
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        self.session = session
        self.socket = socket
        socket.resume()
        connectionTimeout = Task { [weak self, weak socket] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  let socket,
                  self.socket === socket,
                  self.state == .connecting else { return }
            socket.cancel(with: .goingAway, reason: nil)
            self.failAll(NSError(
                domain: "StikServer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "StikServer did not respond. Check that this device can open the copied address in Safari and that the access token is current."]
            ))
        }
        heartbeat = Self.makeHeartbeat(for: socket)
        receiver = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            do {
                while !Task.isCancelled { self.receive(try await socket.receive()) }
            } catch {
                self.devices = []
                self.failAll(Self.connectionError(error, address: serverAddress))
            }
        }
    }

    func disconnect() {
        receiver?.cancel()
        receiver = nil
        heartbeat?.cancel()
        heartbeat = nil
        connectionTimeout?.cancel()
        connectionTimeout = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        devices = []
        state = .disconnected
        failAll(RemoteDeviceError.relayDisconnected, notify: false)
    }

    func beginOperation(target: CommandTarget, operationID: String) async throws {
        _ = try await request(
            "sideStoreBegin",
            target: target,
            fields: ["sessionId": operationID],
            timeout: 20
        )
    }

    func endOperation(target: CommandTarget, operationID: String) async {
        _ = try? await request(
            "sideStoreEnd",
            target: target,
            fields: ["sessionId": operationID],
            timeout: 10
        )
    }

    func request(
        _ command: String,
        target: CommandTarget,
        fields: [String: Any],
        timeout: TimeInterval = 60
    ) async throws -> [String: Any] {
        guard let socket, let deviceID = target.relayDeviceID else { throw RemoteDeviceError.relayDisconnected }
        let requestID = UUID().uuidString
        var payload = fields
        payload["type"] = "command"
        payload["command"] = command
        payload["deviceId"] = deviceID
        payload["requestId"] = requestID
        if payload["sessionId"] == nil, let operationID = DeviceOperationScope.relayOperationID {
            payload["sessionId"] = operationID
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteDeviceError.invalidRelayResponse("request encoding failed")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = continuation
                Task {
                    do {
                        try await socket.send(.string(text))
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        guard let continuation = self.pending.removeValue(forKey: requestID) else { return }
                        continuation.resume(throwing: StikServerRequestError.timedOut)
                    } catch {
                        guard let continuation = self.pending.removeValue(forKey: requestID) else { return }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let continuation = self?.pending.removeValue(forKey: requestID) else { return }
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func receive(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        if type == "error" {
            let message = object["message"] as? String ?? "StikServer reported an error"
            failAll(NSError(
                domain: "StikServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
            return
        }
        if type == "devices", let raw = object["devices"],
           let encoded = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode([StikServerDevice].self, from: encoded) {
            devices = decoded
            connectionTimeout?.cancel()
            connectionTimeout = nil
            errorMessage = nil
            state = .connected
            return
        }
        if type == "deviceEvent", let event = object["event"] as? [String: Any],
           let requestID = event["requestId"] as? String,
           let continuation = pending.removeValue(forKey: requestID) {
            if event["ok"] as? Bool == false {
                let message = event["message"] as? String ?? "Relay operation failed"
                continuation.resume(throwing: NSError(domain: "StikServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
            } else {
                continuation.resume(returning: event)
            }
        }
    }

    private func failAll(_ error: Error, notify: Bool = true) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        if notify {
            errorMessage = error.localizedDescription
            state = .failed(error.localizedDescription)
            NotificationCenter.default.post(name: .commandTargetConnectionFailed, object: error)
        }
    }

    static func socketURL(_ address: String, token: String, role: String) -> URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value.contains("://") ? value : "http://\(value)"),
              components.host != nil else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        components.path = "/\(role)"
        let resolvedToken = accessToken(from: address, explicitToken: token)
        components.queryItems = resolvedToken.isEmpty ? nil : [URLQueryItem(name: "token", value: resolvedToken)]
        return components.url
    }

    nonisolated static func accessToken(from address: String, explicitToken: String) -> String {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = URLComponents(string: value.contains("://") ? value : "http://\(value)")
        if let copiedToken = components?.queryItems?.first(where: { $0.name == "token" })?.value,
           !copiedToken.isEmpty {
            return copiedToken
        }
        return explicitToken
    }

    private static func connectionError(_ error: Error, address: String) -> Error {
        guard let urlError = error as? URLError, urlError.code == .badServerResponse else { return error }
        return NSError(
            domain: "StikServer",
            code: urlError.errorCode,
            userInfo: [NSLocalizedDescriptionKey:
                "StikServer rejected the native WebSocket connection. Check the server address and access token, and make sure any reverse proxy forwards WebSockets to /viewer and /agent. Address: \(address)"
            ]
        )
    }

    nonisolated static func makeHeartbeat(for socket: URLSessionWebSocketTask) -> Task<Void, Never> {
        Task { [weak socket] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let socket else { return }
                socket.sendPing { _ in }
            }
        }
    }
}

enum StikServerRequestError: LocalizedError {
    case timedOut
    var errorDescription: String? { "StikServer did not return a response in time." }
}

enum RemoteDeviceOperations {
    struct HealthStatus: Sendable {
        let reachable: Bool
        let pairingLoaded: Bool
        let pairingVerified: Bool
        let ddiMounted: Bool
        let protocolName: String
        let udid: String?
    }

    static func ensureReady() async throws {
        let target = DeviceOperationScope.target
        if target.kind == .stikServer {
            _ = try await StikServerDeviceConnection.shared.request(
                "sideStoreReady", target: target, fields: [:], timeout: 20
            )
        } else if case .failure(let error) = await minimuxer.core.isReady(withNetworkCheck: true) {
            throw error.asOperationError
        }
    }

    static func fetchUDID() async throws -> String {
        let target = DeviceOperationScope.target
        guard target.kind == .stikServer else { return try await minimuxer.core.fetchUDID() }
        let response = try await StikServerDeviceConnection.shared.request("sideStoreUDID", target: target, fields: [:])
        guard let udid = response["udid"] as? String, !udid.isEmpty else {
            throw RemoteDeviceError.invalidRelayResponse("missing device identifier")
        }
        return udid
    }

    static func healthCheck() async throws -> HealthStatus {
        let target = DeviceOperationScope.target
        guard target.kind == .stikServer else {
            let ready = await minimuxer.core.isReady(withDDIMountCheck: true)
            if case .failure(let error) = ready { throw error.asOperationError }
            let ddiMounted = (try? await minimuxer.core.isDDIMounted()) ?? false
            let udid = try? await minimuxer.core.fetchUDID()
            let protocolName: String
            switch minimuxer.core.pairingFileType {
            case .rppairing: protocolName = "Remote Pairing"
            case .lockdown: protocolName = "Lockdown"
            case .unknown: protocolName = "Unknown"
            }
            return HealthStatus(
                reachable: true,
                pairingLoaded: minimuxer.core.isPairingFileLoaded,
                pairingVerified: udid != nil,
                ddiMounted: ddiMounted,
                protocolName: protocolName,
                udid: udid
            )
        }

        let response = try await StikServerDeviceConnection.shared.request(
            "sideStoreHealth", target: target, fields: [:], timeout: 30
        )
        return HealthStatus(
            reachable: response["reachable"] as? Bool ?? true,
            pairingLoaded: response["pairingLoaded"] as? Bool ?? true,
            pairingVerified: response["pairingVerified"] as? Bool ?? true,
            ddiMounted: response["ddiMounted"] as? Bool ?? false,
            protocolName: response["protocol"] as? String ?? "Remote Pairing",
            udid: response["udid"] as? String
        )
    }

    static func installProfile(_ data: Data) async throws {
        try await commandWithData("sideStoreInstallProfile", data: data)
    }

    static func removeProfile(_ identifier: String) async throws {
        try await command("sideStoreRemoveProfile", fields: ["identifier": identifier]) {
            try await minimuxer.core.removeProvisioningProfile(id: identifier)
        }
    }

    static func removeApp(_ bundleID: String) async throws {
        try await command("sideStoreRemoveApp", fields: ["bundleId": bundleID]) {
            try await minimuxer.core.removeApp(bundleId: bundleID)
        }
    }

    static func sendIPA(
        bundleID: String,
        data: Data,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let target = DeviceOperationScope.target
        guard target.kind == .stikServer else {
            try await minimuxer.core.sendIpaAfc(bundleId: bundleID, ipaBytes: data)
            progressHandler?(1)
            return
        }
        let uploadID = UUID().uuidString
        _ = try await StikServerDeviceConnection.shared.request(
            "sideStoreUploadBegin",
            target: target,
            fields: ["uploadId": uploadID, "bundleId": bundleID, "size": data.count]
        )
        let chunkSize = 384 * 1024
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            _ = try await StikServerDeviceConnection.shared.request(
                "sideStoreUploadChunk",
                target: target,
                fields: [
                    "uploadId": uploadID,
                    "offset": offset,
                    "data": chunk.base64EncodedString()
                ],
                timeout: 60
            )
            offset = end
            progressHandler?(Double(offset) / Double(max(data.count, 1)))
        }
        _ = try await StikServerDeviceConnection.shared.request(
            "sideStoreUploadCommit",
            target: target,
            fields: ["uploadId": uploadID],
            timeout: 15 * 60
        )
    }

    static func installIPA(bundleID: String) async throws {
        try await command("sideStoreInstallIPA", fields: ["bundleId": bundleID], timeout: 15 * 60) {
            try await minimuxer.core.installIpa(bundleId: bundleID)
        }
    }

    static func dumpProfiles(to directory: String, mode: ProfileDumpMode) async throws -> String {
        let target = DeviceOperationScope.target
        guard target.kind == .stikServer else {
            return try await minimuxer.core.dumpProfiles(docsPath: directory, mode: mode)
        }
        let response = try await StikServerDeviceConnection.shared.request(
            "sideStoreDumpProfiles",
            target: target,
            fields: ["mode": { if case .zip = mode { return "zip" }; return "raw" }()],
            timeout: 120
        )
        if let encoded = response["data"] as? String,
           let data = Data(base64Encoded: encoded),
           let filename = response["filename"] as? String {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return url.path
        }

        guard let encodedProfiles = response["profiles"] as? [String] else {
            throw RemoteDeviceError.invalidRelayResponse("missing provisioning profiles")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let exportURL = URL(fileURLWithPath: directory)
            .appendingPathComponent("ProvisioningProfiles-\(formatter.string(from: Date()))", isDirectory: true)
        try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)
        do {
            for (index, encoded) in encodedProfiles.enumerated() {
                guard let data = Data(base64Encoded: encoded) else {
                    throw RemoteDeviceError.invalidRelayResponse("invalid provisioning profile data")
                }
                let fileURL = exportURL.appendingPathComponent(
                    String(format: "profile-%03d.mobileprovision", index + 1)
                )
                try data.write(to: fileURL, options: .atomic)
            }
            return exportURL.path
        } catch {
            try? FileManager.default.removeItem(at: exportURL)
            throw error
        }
    }

    private static func commandWithData(_ name: String, data: Data) async throws {
        try await command(name, fields: ["data": data.base64EncodedString()]) {
            switch name {
            case "sideStoreInstallProfile": try await minimuxer.core.installProvisioningProfile(profile: data)
            default: throw RemoteDeviceError.invalidRelayResponse("unsupported data command")
            }
        }
    }

    private static func command(
        _ name: String,
        fields: [String: Any],
        timeout: TimeInterval = 60,
        local: () async throws -> Void
    ) async throws {
        let target = DeviceOperationScope.target
        if target.kind == .stikServer {
            _ = try await StikServerDeviceConnection.shared.request(name, target: target, fields: fields, timeout: timeout)
        } else {
            try await local()
        }
    }
}

@MainActor
final class SideStoreRelayAgentManager {
    static let shared = SideStoreRelayAgentManager()

    private var agents: [String: SideStoreRelayAgent] = [:]
    private var cancellable: AnyCancellable?
    private var address = ""
    private var token = ""

    func connect(serverAddress: String, token: String) {
        let changed = serverAddress != address || token != self.token
        address = serverAddress
        self.token = token
        if changed {
            agents.values.forEach { $0.disconnect() }
            agents.removeAll()
        }
        cancellable = CommandTargetManager.shared.$nearbyTargets
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
        reconcile()
    }

    private func reconcile() {
        let targets = [CommandTarget.local] + CommandTargetManager.shared.nearbyTargets
        let ids = Set(targets.map(\.id))
        for id in Array(agents.keys) where !ids.contains(id) {
            agents.removeValue(forKey: id)?.disconnect()
        }
        for target in targets where agents[target.id] == nil {
            let agent = SideStoreRelayAgent(target: target)
            agents[target.id] = agent
            agent.connect(serverAddress: address, token: token)
        }
    }
}

private actor RelayOperationLease {
    private var isReady = false
    private var isEnded = false
    private var failureMessage: String?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var endWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReady() async throws {
        if let failureMessage {
            throw NSError(
                domain: "SideStoreRelay",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: failureMessage]
            )
        }
        if isReady { return }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    func markReady() {
        guard !isReady, failureMessage == nil else { return }
        isReady = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilEnded() async {
        if isEnded { return }
        await withCheckedContinuation { endWaiters.append($0) }
    }

    func end() {
        guard !isEnded else { return }
        isEnded = true
        let waiters = endWaiters
        endWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func fail(_ message: String) {
        failureMessage = message
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach {
            $0.resume(throwing: NSError(
                domain: "SideStoreRelay",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
        end()
    }
}

@MainActor
final class SideStoreRelayAgent {
    private let target: CommandTarget

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var uploads: [String: RelayUpload] = [:]
    private var heldOperation: HeldRelayOperation?
    private var heldOperationTimeout: Task<Void, Never>?

    private struct RelayUpload {
        let bundleID: String
        let expectedSize: Int
        let sessionID: String?
        let url: URL
        var receivedSize: Int
    }

    private struct HeldRelayOperation {
        let id: String
        let lease: RelayOperationLease
        let task: Task<Void, Never>
    }

    init(target: CommandTarget) {
        self.target = target
    }

    func connect(serverAddress: String, token: String) {
        disconnect()
        guard let url = StikServerDeviceConnection.socketURL(serverAddress, token: token, role: "agent") else { return }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        self.session = session
        self.socket = socket
        socket.resume()
        heartbeat = StikServerDeviceConnection.makeHeartbeat(for: socket)
        receiver = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            await self.register(socket: socket)
            do {
                while !Task.isCancelled { await self.receive(try await socket.receive()) }
            } catch {
                debugLog("[SideStoreRelayAgent] Relay stopped: \(error.localizedDescription)")
                self.disconnect()
            }
        }
    }

    func disconnect() {
        receiver?.cancel()
        receiver = nil
        heartbeat?.cancel()
        heartbeat = nil
        heldOperationTimeout?.cancel()
        heldOperationTimeout = nil
        if let heldOperation {
            heldOperation.task.cancel()
            Task { await heldOperation.lease.end() }
        }
        heldOperation = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        for upload in uploads.values { try? FileManager.default.removeItem(at: upload.url) }
        uploads.removeAll()
    }

    private func register(socket: URLSessionWebSocketTask) async {
        let identifier = target.id == CommandTarget.local.id
            ? ((try? await minimuxer.core.fetchUDID()) ?? UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)
            : (target.pairingIdentifier ?? target.id.replacingOccurrences(of: "nearby|", with: ""))
        let agentID = "sidestore-agent|\(identifier)"
        let payload: [String: Any] = [
            "type": "register",
            "device": [
                "id": agentID,
                "name": target.name,
                "kind": target.deviceKind ?? (UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"),
                "serviceIdentifier": target.advertisedServiceIdentifier ?? agentID,
                "pairingIdentifier": identifier,
                "paired": true,
                "routeHops": 1,
                "capabilities": ["sidestore.device.v1"]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await socket.send(.string(text))
    }

    private func receive(_ message: URLSessionWebSocketTask.Message) async {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "command",
              let command = object["command"] as? String else { return }
        let requestID = object["requestId"] as? String ?? UUID().uuidString
        Task { [weak self] in
            do {
                let values = try await self?.execute(command, object: object) ?? [:]
                await self?.reply(requestID: requestID, ok: true, values: values)
            } catch {
                await self?.reply(requestID: requestID, ok: false, values: ["message": error.localizedDescription])
            }
        }
    }

    private func execute(_ command: String, object: [String: Any]) async throws -> [String: Any] {
        if command == "sideStoreBegin" {
            guard let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else {
                throw RemoteDeviceError.invalidRelayResponse("missing operation session identifier")
            }
            try await beginHeldOperation(id: sessionID)
            return [:]
        }
        if command == "sideStoreEnd" {
            guard let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else {
                throw RemoteDeviceError.invalidRelayResponse("missing operation session identifier")
            }
            try await endHeldOperation(id: sessionID)
            return [:]
        }
        if let heldOperation {
            guard object["sessionId"] as? String == heldOperation.id else {
                throw RemoteDeviceError.invalidRelayResponse("another device operation is already active")
            }
            return try await executeForSelectedTarget(command, object: object)
        }
        if command == "sideStoreUploadBegin" || command == "sideStoreUploadChunk" {
            return try await executeForSelectedTarget(command, object: object)
        }
        return try await DeviceOperationSession.run(target: target) {
            try await self.executeForSelectedTarget(command, object: object)
        }
    }

    private func beginHeldOperation(id: String) async throws {
        if let heldOperation {
            guard heldOperation.id == id else {
                throw RemoteDeviceError.invalidRelayResponse("another device operation is already active")
            }
            return
        }

        let lease = RelayOperationLease()
        let target = self.target
        let task = Task {
            do {
                try await DeviceOperationSession.run(target: target) {
                    await lease.markReady()
                    await lease.waitUntilEnded()
                }
            } catch {
                await lease.fail(error.localizedDescription)
            }
        }
        heldOperation = HeldRelayOperation(id: id, lease: lease, task: task)
        heldOperationTimeout = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            task.cancel()
            await lease.fail("Timed out waiting for the selected device session")
        }

        do {
            try await lease.waitUntilReady()
            heldOperationTimeout?.cancel()
            heldOperationTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                try? await self?.endHeldOperation(id: id)
            }
        } catch {
            if heldOperation?.id == id {
                heldOperationTimeout?.cancel()
                heldOperationTimeout = nil
                heldOperation = nil
            }
            throw error
        }
    }

    private func endHeldOperation(id: String) async throws {
        guard let heldOperation else { return }
        guard heldOperation.id == id else {
            throw RemoteDeviceError.invalidRelayResponse("operation session identifier does not match")
        }
        heldOperationTimeout?.cancel()
        heldOperationTimeout = nil
        await heldOperation.lease.end()
        _ = await heldOperation.task.result
        let expiredUploadIDs = uploads.compactMap { $0.value.sessionID == id ? $0.key : nil }
        for uploadID in expiredUploadIDs {
            if let upload = uploads.removeValue(forKey: uploadID) {
                try? FileManager.default.removeItem(at: upload.url)
            }
        }
        if self.heldOperation?.id == id {
            self.heldOperation = nil
        }
    }

    private func executeForSelectedTarget(_ command: String, object: [String: Any]) async throws -> [String: Any] {
        switch command {
        case "sideStoreReady":
            if case .failure(let error) = await minimuxer.core.isReady(withNetworkCheck: true) { throw error }
            return [:]
        case "sideStoreHealth":
            if case .failure(let error) = await minimuxer.core.isReady(withNetworkCheck: true) { throw error }
            let ddiMounted = (try? await minimuxer.core.isDDIMounted()) ?? false
            let udid = try? await minimuxer.core.fetchUDID()
            let protocolName: String
            switch minimuxer.core.pairingFileType {
            case .rppairing: protocolName = "Remote Pairing"
            case .lockdown: protocolName = "Lockdown"
            case .unknown: protocolName = "Unknown"
            }
            var values: [String: Any] = [
                "reachable": true,
                "pairingLoaded": minimuxer.core.isPairingFileLoaded,
                "pairingVerified": udid != nil,
                "ddiMounted": ddiMounted,
                "protocol": protocolName
            ]
            if let udid { values["udid"] = udid }
            return values
        case "sideStoreUDID":
            return ["udid": try await minimuxer.core.fetchUDID()]
        case "sideStoreInstallProfile":
            guard let encoded = object["data"] as? String, let data = Data(base64Encoded: encoded) else {
                throw RemoteDeviceError.invalidRelayResponse("missing profile data")
            }
            try await minimuxer.core.installProvisioningProfile(profile: data)
            return [:]
        case "sideStoreRemoveProfile":
            guard let identifier = object["identifier"] as? String else { throw RemoteDeviceError.invalidRelayResponse("missing profile identifier") }
            try await minimuxer.core.removeProvisioningProfile(id: identifier)
            return [:]
        case "sideStoreRemoveApp":
            guard let bundleID = object["bundleId"] as? String else { throw RemoteDeviceError.invalidRelayResponse("missing bundle identifier") }
            try await minimuxer.core.removeApp(bundleId: bundleID)
            return [:]
        case "sideStoreUploadBegin":
            guard let uploadID = object["uploadId"] as? String,
                  let bundleID = object["bundleId"] as? String,
                  let size = object["size"] as? Int else { throw RemoteDeviceError.invalidRelayResponse("invalid upload request") }
            let url = FileManager.default.uniqueTemporaryURL().appendingPathExtension("ipa")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            uploads[uploadID] = RelayUpload(
                bundleID: bundleID,
                expectedSize: size,
                sessionID: object["sessionId"] as? String,
                url: url,
                receivedSize: 0
            )
            return [:]
        case "sideStoreUploadChunk":
            guard let uploadID = object["uploadId"] as? String,
                  var upload = uploads[uploadID],
                  let offset = object["offset"] as? Int,
                  let encoded = object["data"] as? String,
                  let data = Data(base64Encoded: encoded) else { throw RemoteDeviceError.invalidRelayResponse("invalid upload chunk") }
            guard offset == upload.receivedSize,
                  upload.receivedSize + data.count <= upload.expectedSize else {
                throw RemoteDeviceError.invalidRelayResponse("upload chunk is out of order")
            }
            let handle = try FileHandle(forWritingTo: upload.url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            upload.receivedSize += data.count
            uploads[uploadID] = upload
            return ["received": upload.receivedSize]
        case "sideStoreUploadCommit":
            guard let uploadID = object["uploadId"] as? String,
                  let upload = uploads.removeValue(forKey: uploadID) else { throw RemoteDeviceError.invalidRelayResponse("unknown upload") }
            defer { try? FileManager.default.removeItem(at: upload.url) }
            guard upload.receivedSize == upload.expectedSize else { throw RemoteDeviceError.invalidRelayResponse("incomplete upload") }
            let data = try Data(contentsOf: upload.url, options: .mappedIfSafe)
            try await minimuxer.core.sendIpaAfc(bundleId: upload.bundleID, ipaBytes: data)
            return [:]
        case "sideStoreInstallIPA":
            guard let bundleID = object["bundleId"] as? String else { throw RemoteDeviceError.invalidRelayResponse("missing bundle identifier") }
            try await minimuxer.core.installIpa(bundleId: bundleID)
            return [:]
        case "sideStoreDumpProfiles":
            let mode: ProfileDumpMode = object["mode"] as? String == "raw" ? .raw : .zip
            let directory = FileManager.default.uniqueTemporaryURL()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = try await minimuxer.core.dumpProfiles(docsPath: directory.path, mode: mode)
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            return ["filename": url.lastPathComponent, "data": data.base64EncodedString()]
        default:
            throw RemoteDeviceError.unsupportedRelay
        }
    }

    private func reply(requestID: String, ok: Bool, values: [String: Any]) {
        guard let socket else { return }
        var event = values
        event["type"] = "sideStoreResult"
        event["requestId"] = requestID
        event["ok"] = ok
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "deviceEvent", "event": event]),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await socket.send(.string(text)) }
    }
}
