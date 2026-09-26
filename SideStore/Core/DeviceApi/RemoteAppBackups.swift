import Foundation
import CryptoKit

/// Backups are keyed by physical UDID, not a Bonjour UUID or a relay route.
enum RemoteAppBackups {
    private static func key(_ value: String) -> String { SHA256.hash(data: Data(value.lowercased().utf8)).map { String(format: "%02x", $0) }.joined() }
    static func remember(udid: String, target: CommandTarget) {
        UserDefaults.standard.set(udid, forKey: "remoteBackupDevice." + target.id)
    }
    static func device(for target: CommandTarget) -> String? { UserDefaults.standard.string(forKey: "remoteBackupDevice." + target.id) }
    static func directory(udid: String, bundle: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteAppBackups").appendingPathComponent(key(udid)).appendingPathComponent(key(bundle))
    }
    static func archive(udid: String, bundle: String) -> URL { directory(udid: udid, bundle: bundle).appendingPathComponent("backup.bin") }
    static func inactive(target: CommandTarget) -> Set<String> {
        guard let udid = device(for: target) else { return [] }
        return Set(UserDefaults.standard.stringArray(forKey: "remoteInactive." + key(udid)) ?? [])
    }
    static func setInactive(_ inactive: Bool, bundle: String, target: CommandTarget) {
        guard let udid = device(for: target) else { return }
        var ids = self.inactive(target: target)
        if inactive { ids.insert(bundle) } else { ids.remove(bundle) }
        UserDefaults.standard.set(Array(ids), forKey: "remoteInactive." + key(udid))
    }
    static func hasBackup(target: CommandTarget, bundle: String) -> Bool {
        guard let udid = device(for: target) else { return false }
        return FileManager.default.fileExists(atPath: archive(udid: udid, bundle: bundle).path)
    }

    static func perform(action: String, bundle: String, progress: @escaping (Double) -> Void) async throws {
        let target = DeviceOperationScope.target
        try await DeviceOperationSession.run(target: target) {
            let udid = try await RemoteDeviceOperations.fetchUDID()
            remember(udid: udid, target: target)
            let archive = archive(udid: udid, bundle: bundle)
            let id = UUID().uuidString
            var requestObject = ["id": id, "action": action]
            if action == "restore" {
                let input = try FileHandle(forReadingFrom: archive)
                defer { try? input.close() }
                _ = try await RemoteDeviceOperations.backupExchange(bundleID: bundle, action: "reset", file: "backup.bin")
                var offset: Int64 = 0
                var hash = SHA256()
                let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.doubleValue ?? 1
                while let chunk = try input.read(upToCount: 262144), !chunk.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: chunk)
                    _ = try await RemoteDeviceOperations.backupExchange(bundleID: bundle, action: "write", file: "backup.bin", offset: offset, data: chunk)
                    offset += Int64(chunk.count)
                    progress(Double(offset) / max(size, 1) * 0.8)
                }
                requestObject["sha256"] = hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
            let request = try JSONSerialization.data(withJSONObject: requestObject)
            _ = try await RemoteDeviceOperations.backupExchange(bundleID: bundle, action: "reset", file: "request.json", data: request)
            _ = try await RemoteDeviceOperations.backupExchange(bundleID: bundle, action: "launch")
            let deadline = Date().addingTimeInterval(1800)
            var result: [String: Any]?
            while Date() < deadline {
                try Task.checkCancellation()
                // House Arrest may briefly disconnect while the helper launches.
                if let data = try? await RemoteDeviceOperations.backupExchange(bundleID: bundle, action: "read"),
                   let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any], status["id"] as? String == id {
                    if status["state"] as? String == "failed" { throw OperationError.invalidParameters(status["message"] as? String ?? "Remote backup failed") }
                    if status["state"] as? String == "complete" { result = status; break }
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let result else { throw OperationError.invalidParameters("The backup helper on the selected device did not finish. Keep that device unlocked. The app has not been uninstalled.") }
            if action == "backup" {
                guard let size = (result["size"] as? NSNumber)?.int64Value, size > 0,
                      let expectedHash = result["sha256"] as? String else { throw OperationError.invalidParameters("Invalid remote backup manifest") }
                try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = archive.deletingLastPathComponent().appendingPathComponent(id + ".partial")
                defer { try? FileManager.default.removeItem(at: temporary) }
                FileManager.default.createFile(atPath: temporary.path, contents: nil)
                let output = try FileHandle(forWritingTo: temporary)
                defer { try? output.close() }
                var offset: Int64 = 0
                var hash = SHA256()
                while offset < size {
                    try Task.checkCancellation()
                    let chunk = try await RemoteDeviceOperations.backupExchange(bundleID: bundle, action: "read", file: "backup.bin", offset: offset)
                    guard !chunk.isEmpty, offset + Int64(chunk.count) <= size else { throw OperationError.invalidParameters("Incomplete remote backup; app was not removed") }
                    hash.update(data: chunk)
                    try output.write(contentsOf: chunk)
                    offset += Int64(chunk.count)
                    progress(Double(offset) / Double(size))
                }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash else {
                    throw OperationError.invalidParameters("Remote backup verification failed; app was not removed")
                }
                try output.synchronize()
                try output.close()
                if FileManager.default.fileExists(atPath: archive.path) { _ = try FileManager.default.replaceItemAt(archive, withItemAt: temporary) }
                else { try FileManager.default.moveItem(at: temporary, to: archive) }
            }
            progress(1)
        }
    }
}
