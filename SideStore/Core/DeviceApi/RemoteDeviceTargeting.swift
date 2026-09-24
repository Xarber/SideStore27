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
        kind: .local
    )

    var pairingFileURL: URL? {
        pairingFilePath.map { URL(fileURLWithPath: $0) }
    }

    var supportsSideStoreOperations: Bool {
        kind != .stikServer || relayCapabilities.contains("sidestore.device.v1") || relayDeviceID?.hasPrefix("sidestore-agent|") == true
    }
}

extension Notification.Name {
    static let commandTargetDidChange = Notification.Name("SideStore.commandTargetDidChange")
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
        if let data = UserDefaults.standard.data(forKey: selectedTargetKey),
           let stored = try? JSONDecoder().decode(CommandTarget.self, from: data) {
            selectedTarget = stored
        } else {
            selectedTarget = .local
        }

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
            ofTypes: ["_remotepairing._tcp.", "_apple-mobdev2._tcp."],
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
        StikServerDeviceConnection.shared.connect(serverAddress: address, token: token)
        SideStoreRelayAgentManager.shared.connect(serverAddress: address, token: token)
    }

    private func updateNearbyTargets(from services: [DiscoveredService]) {
        let pairings = PairingFileManager.shared.remotePairingFiles()
        let knownIdentifiers = Dictionary(uniqueKeysWithValues: pairings.compactMap { item in
            item.identifier.map { ($0.lowercased(), item.url) }
        })

        for service in services where resolutionTasks[service.id] == nil {
            resolutionTasks[service.id] = Task { [weak self] in
                guard let self else { return }
                let resolved = await Self.resolve(service)
                guard !Task.isCancelled, let resolved else { return }
                let txt = Dictionary(uniqueKeysWithValues: service.txtRecords.map { ($0.key.lowercased(), $0.value) })
                let identifiers = [txt["identifier"], txt["uuid"], txt["deviceid"], txt["udid"]]
                    .compactMap { $0?.lowercased() }
                let normalizedName = service.name.lowercased().filter(\.isLetterOrNumber)
                let pairing = identifiers.compactMap({ knownIdentifiers[$0] }).first
                    ?? pairings.first(where: {
                        $0.url.deletingPathExtension().lastPathComponent.lowercased().filter(\.isLetterOrNumber).contains(normalizedName)
                    })?.url
                guard let pairing else { return }
                let id = identifiers.first ?? service.id
                let target = CommandTarget(
                    id: "nearby|\(id)",
                    name: service.name,
                    kind: .nearby,
                    host: resolved.host,
                    port: resolved.port,
                    pairingFilePath: pairing.path
                )
                if !self.nearbyTargets.contains(where: { $0.id == target.id }) {
                    self.nearbyTargets.append(target)
                    self.nearbyTargets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }
        }
    }

    private func updateRelayTargets(from devices: [StikServerDevice]) {
        let connection = StikServerDeviceConnection.shared
        relayTargets = devices.map { device in
            CommandTarget(
                id: "stikserver|\(device.id)",
                name: device.name,
                kind: .stikServer,
                serverAddress: connection.serverAddress,
                serverToken: connection.accessToken,
                relayDeviceID: device.id,
                relayCapabilities: Set(device.capabilities ?? [])
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func resolve(_ service: DiscoveredService) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let connection = NWConnection(to: service.result.endpoint, using: parameters)
            let lock = NSLock()
            var resumed = false
            let finish: ((String, UInt16)?) -> Void = { result in
                lock.withLock {
                    guard !resumed else { return }
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: result)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        finish((host.debugDescription.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port.rawValue))
                    } else {
                        finish((service.name + ".local", AppConstants.Minimuxer.remotePairingPort))
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }
}

struct RemotePairingFile: Sendable {
    let url: URL
    let identifier: String?
}

extension PairingFileManager {
    nonisolated func remotePairingFiles() -> [RemotePairingFile] {
        let directory = FileManager.default.documentsDirectory
        let localPaths = Set([
            pairingFileURL(for: .rppairing).standardizedFileURL.path,
            pairingFileURL(for: .lockdown).standardizedFileURL.path
        ])
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.compactMap { url in
            guard !localPaths.contains(url.standardizedFileURL.path),
                  AppConstants.Pairing.supportedExtensions.contains(url.pathExtension.lowercased()),
                  let content = try? String(contentsOf: url),
                  let parsed = try? parse(content: content) else { return nil }
            let identifier: String?
            if let rp = parsed as? RPPairingFile { identifier = rp.identifier }
            else if let lockdown = parsed as? LockdownPairingFile { identifier = lockdown.udid }
            else { identifier = nil }
            return RemotePairingFile(url: url, identifier: identifier)
        }
    }
}

enum DeviceOperationScope {
    @TaskLocal static var scopedTarget: CommandTarget?

    static var target: CommandTarget { scopedTarget ?? .local }

    static var requiresIPA: Bool { target.kind == .stikServer }
}

enum RemoteDeviceError: LocalizedError {
    case missingPairingFile
    case missingEndpoint
    case unsupportedRelay
    case relayDisconnected
    case invalidRelayResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingPairingFile: return "The selected device's pairing file is missing. Pair that device again without replacing this device's main pairing identity."
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
                try await DeviceSessionCoordinator.shared.withSession(for: target, operation: operation)
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
            try await StikServerDeviceConnection.shared.beginOperation(target: target)
            defer { Task { await StikServerDeviceConnection.shared.endOperation(target: target) } }
            return try await operation()
        case .nearby:
            guard let fileURL = target.pairingFileURL,
                  let pairing = try? String(contentsOf: fileURL) else { throw RemoteDeviceError.missingPairingFile }
            guard let host = target.host, !host.isEmpty else { throw RemoteDeviceError.missingEndpoint }

            let localPairing = PairingFileManager.shared.fetchPairingFile()
            let config = ConnectionConfigBinding(
                setTunnelIfaceIp: { _ in }, setTunnelPeerIp: { _ in },
                setTunnelPeerSubnetMask: { _ in }, setTunnelPeerReachable: { _ in },
                setTunnelIfaceSubnetMask: { _ in }, getRemoteServerIp: { host },
                setRemoteReachable: { _ in }, getOverrideTunnelPeerIp: { "" },
                setOverrideTunnelPeerReachable: { _ in }, getConnectionMode: { .remoteServer }
            )
            if let port = target.port { minimuxer.set(MinimuxerParams(remotePairingPort: port)) }
            await minimuxer.core.bindConnectionConfig(config)
            try await minimuxer.core.reinitializePairingData(pairingFile: pairing)

            do {
                let result = try await operation()
                try await restoreLocal(pairing: localPairing)
                return result
            } catch {
                try? await restoreLocal(pairing: localPairing)
                throw error
            }
        }
    }

    private func restoreLocal(pairing: String?) async throws {
        await bindConnectionConfig()
        minimuxer.set(MinimuxerParams(remotePairingPort: remotePairingPortCache))
        if let pairing { try await minimuxer.core.reinitializePairingData(pairingFile: pairing) }
    }
}

struct StikServerDevice: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let connected: Bool?
    let controllable: Bool?
    let capabilities: [String]?
}

@MainActor
final class StikServerDeviceConnection: ObservableObject {
    static let shared = StikServerDeviceConnection()

    @Published private(set) var devices: [StikServerDevice] = []
    @Published private(set) var errorMessage: String?
    private(set) var serverAddress = ""
    private(set) var accessToken = ""

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]

    func connect(serverAddress: String, token: String) {
        disconnect()
        guard let url = Self.socketURL(serverAddress, token: token, role: "viewer") else {
            errorMessage = "Invalid StikServer address"
            return
        }
        self.serverAddress = serverAddress
        accessToken = token
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        self.session = session
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            do {
                while !Task.isCancelled { self.receive(try await socket.receive()) }
            } catch {
                self.failAll(error)
            }
        }
    }

    func disconnect() {
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        devices = []
        failAll(RemoteDeviceError.relayDisconnected)
    }

    func beginOperation(target: CommandTarget) async throws {
        _ = try await request("sideStoreBegin", target: target, fields: [:], timeout: .seconds(20))
    }

    func endOperation(target: CommandTarget) async {
        _ = try? await request("sideStoreEnd", target: target, fields: [:], timeout: .seconds(10))
    }

    func request(
        _ command: String,
        target: CommandTarget,
        fields: [String: Any],
        timeout: Duration = .seconds(60)
    ) async throws -> [String: Any] {
        guard let socket, let deviceID = target.relayDeviceID else { throw RemoteDeviceError.relayDisconnected }
        let requestID = UUID().uuidString
        var payload = fields
        payload["type"] = "command"
        payload["command"] = command
        payload["deviceId"] = deviceID
        payload["requestId"] = requestID
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteDeviceError.invalidRelayResponse("request encoding failed")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            Task {
                do {
                    try await socket.send(.string(text))
                    try await Task.sleep(for: timeout)
                    guard let continuation = self.pending.removeValue(forKey: requestID) else { return }
                    continuation.resume(throwing: StikServerRequestError.timedOut)
                } catch {
                    guard let continuation = self.pending.removeValue(forKey: requestID) else { return }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func receive(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        if type == "devices", let raw = object["devices"],
           let encoded = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode([StikServerDevice].self, from: encoded) {
            devices = decoded
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

    private func failAll(_ error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        errorMessage = error.localizedDescription
    }

    static func socketURL(_ address: String, token: String, role: String) -> URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value.contains("://") ? value : "http://\(value)"),
              components.host != nil else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/\(role)"
        components.queryItems = token.isEmpty ? nil : [URLQueryItem(name: "token", value: token)]
        return components.url
    }
}

enum StikServerRequestError: LocalizedError {
    case timedOut
    var errorDescription: String? { "StikServer did not return a response in time." }
}

enum RemoteDeviceOperations {
    static func ensureReady() async throws {
        let target = DeviceOperationScope.target
        if target.kind == .stikServer {
            _ = try await StikServerDeviceConnection.shared.request(
                "sideStoreReady", target: target, fields: [:], timeout: .seconds(20)
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

    static func sendIPA(bundleID: String, data: Data) async throws {
        let target = DeviceOperationScope.target
        guard target.kind == .stikServer else {
            try await minimuxer.core.sendIpaAfc(bundleId: bundleID, ipaBytes: data)
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
                timeout: .seconds(60)
            )
            offset = end
        }
        _ = try await StikServerDeviceConnection.shared.request(
            "sideStoreUploadCommit",
            target: target,
            fields: ["uploadId": uploadID],
            timeout: .seconds(15 * 60)
        )
    }

    static func installIPA(bundleID: String) async throws {
        try await command("sideStoreInstallIPA", fields: ["bundleId": bundleID], timeout: .seconds(15 * 60)) {
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
            timeout: .seconds(120)
        )
        guard let encoded = response["data"] as? String,
              let data = Data(base64Encoded: encoded),
              let filename = response["filename"] as? String else {
            throw RemoteDeviceError.invalidRelayResponse("missing provisioning profile archive")
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url.path
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
        timeout: Duration = .seconds(60),
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
        for id in agents.keys where !ids.contains(id) {
            agents.removeValue(forKey: id)?.disconnect()
        }
        for target in targets where agents[target.id] == nil {
            let agent = SideStoreRelayAgent(target: target)
            agents[target.id] = agent
            agent.connect(serverAddress: address, token: token)
        }
    }
}

@MainActor
final class SideStoreRelayAgent {
    private let target: CommandTarget

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var uploads: [String: RelayUpload] = [:]

    private struct RelayUpload {
        let bundleID: String
        let expectedSize: Int
        let url: URL
        var receivedSize: Int
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
        receiver = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            await self.register(socket: socket)
            do {
                while !Task.isCancelled { await self.receive(try await socket.receive()) }
            } catch {
                debugLog("[SideStoreRelayAgent] Relay stopped: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        receiver?.cancel()
        receiver = nil
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
            : target.id
        let agentID = "sidestore-agent|\(identifier)"
        let payload: [String: Any] = [
            "type": "register",
            "device": [
                "id": agentID,
                "name": target.name,
                "kind": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
                "serviceIdentifier": agentID,
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
        if command == "sideStoreUploadBegin" || command == "sideStoreUploadChunk" {
            return try await executeForSelectedTarget(command, object: object)
        }
        return try await DeviceOperationSession.run(target: target) {
            try await self.executeForSelectedTarget(command, object: object)
        }
    }

    private func executeForSelectedTarget(_ command: String, object: [String: Any]) async throws -> [String: Any] {
        switch command {
        case "sideStoreBegin", "sideStoreEnd":
            return [:]
        case "sideStoreReady":
            if case .failure(let error) = await minimuxer.core.isReady(withNetworkCheck: true) { throw error }
            return [:]
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
            uploads[uploadID] = RelayUpload(bundleID: bundleID, expectedSize: size, url: url, receivedSize: 0)
            return [:]
        case "sideStoreUploadChunk":
            guard let uploadID = object["uploadId"] as? String,
                  var upload = uploads[uploadID],
                  let encoded = object["data"] as? String,
                  let data = Data(base64Encoded: encoded) else { throw RemoteDeviceError.invalidRelayResponse("invalid upload chunk") }
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
