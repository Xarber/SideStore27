import Foundation
import CryptoKit

/// The controller exchanges only these fixed files over House Arrest. No callback
/// URL is opened on the controller, and app-group data stays in the normal engine.
enum RemoteBackup {
    struct Request: Codable { let id: String; let action: String; let sha256: String? }
    struct Entry: Codable {
        let path: String
        let size: UInt64
        let directory: Bool
        let link: String?
        let permissions: Int?
        let modified: Date?
    }
    static var exchange: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(".sidestore-remote") }

    static func runIfRequested() async -> Bool {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: exchange.appendingPathComponent("request.json")),
              let request = try? JSONDecoder().decode(Request.self, from: data),
              UUID(uuidString: request.id) != nil,
              ["backup", "restore"].contains(request.action) else { return false }
        do {
            try fm.removeItem(at: exchange.appendingPathComponent("request.json"))
            guard let group = Bundle.main.altstoreAppGroup,
                  let container = fm.containerURL(forSecurityApplicationGroupIdentifier: group),
                  let bundle = Bundle.main.bundleIdentifier else {
                throw CocoaError(.fileNoSuchFile)
            }
            let backup = container.appendingPathComponent("Backups").appendingPathComponent(bundle)
            if request.action == "backup" {
                // Never recursively include a previous transfer in the app backup.
                try fm.removeItem(at: exchange)
                try await BackupEngine.shared.performBackup(skipNonCopyable: false)
                try fm.createDirectory(at: exchange, withIntermediateDirectories: true)
                try pack(backup, to: exchange.appendingPathComponent("backup.bin"))
            } else {
                let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: staging) }
                let archive = staging.appendingPathComponent("backup.bin")
                try fm.moveItem(at: exchange.appendingPathComponent("backup.bin"), to: archive)
                let verification = try FileHandle(forReadingFrom: archive)
                var digest = SHA256()
                while let chunk = try verification.read(upToCount: 262144), !chunk.isEmpty { digest.update(data: chunk) }
                try verification.close()
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == request.sha256 else { throw CocoaError(.fileReadCorruptFile) }
                let contents = staging.appendingPathComponent("contents")
                try unpack(archive, to: contents)
                // Keep the previous complete backup until the upload is validated.
                try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: backup.path) { _ = try fm.replaceItemAt(backup, withItemAt: contents) }
                else { try fm.moveItem(at: contents, to: backup) }
                try await BackupEngine.shared.restoreBackup(skipNonCopyable: false)
            }
            var result: [String: Any] = ["id": request.id, "state": "complete"]
            if request.action == "backup" {
                let archive = exchange.appendingPathComponent("backup.bin")
                let handle = try FileHandle(forReadingFrom: archive)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 262144), !chunk.isEmpty { hash.update(data: chunk) }
                result["sha256"] = hash.finalize().map { String(format: "%02x", $0) }.joined()
                result["size"] = try fm.attributesOfItem(atPath: archive.path)[.size]
            }
            try writeStatus(result)
        } catch {
            try? writeStatus(["id": request.id, "state": "failed", "message": error.localizedDescription])
        }
        return true
    }

    private static func writeStatus(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: exchange.appendingPathComponent("status.json"), options: .atomic)
    }

    private static func pack(_ root: URL, to archive: URL) throws {
        let fm = FileManager.default
        fm.createFile(atPath: archive.path, contents: nil)
        let output = try FileHandle(forWritingTo: archive)
        defer { try? output.close() }
        var enumerationError: Error?
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            let link = values.isSymbolicLink == true ? try fm.destinationOfSymbolicLink(atPath: file.path) : nil
            let attributes = try fm.attributesOfItem(atPath: file.path)
            let entry = Entry(path: String(file.path.dropFirst(root.path.count + 1)), size: values.isDirectory == true || link != nil ? 0 : UInt64(values.fileSize ?? 0), directory: values.isDirectory == true && link == nil,
                              link: link, permissions: attributes[.posixPermissions] as? Int, modified: attributes[.modificationDate] as? Date)
            let metadata = try JSONEncoder().encode(entry)
            var length = UInt32(metadata.count).bigEndian
            try output.write(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
            try output.write(contentsOf: metadata)
            if !entry.directory && entry.link == nil {
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                var remaining = entry.size
                while remaining > 0 {
                    let chunk = try read(input, count: Int(min(remaining, 262144)))
                    try output.write(contentsOf: chunk)
                    remaining -= UInt64(chunk.count)
                }
            }
        }
        if let enumerationError { throw enumerationError }
        try output.write(contentsOf: Data(repeating: 0, count: 4))
        try output.synchronize()
    }

    private static func unpack(_ archive: URL, to root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        var seen = Set<String>()
        var links: [(URL, String)] = []
        var attributes: [(URL, Entry)] = []
        while true {
            let length = try read(input, count: 4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if length == 0 { break }
            guard length <= 65536 else { throw CocoaError(.fileReadCorruptFile) }
            let entry = try JSONDecoder().decode(Entry.self, from: read(input, count: Int(length)))
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
                  seen.insert(entry.path).inserted else { throw CocoaError(.fileReadCorruptFile) }
            let file = root.appendingPathComponent(entry.path)
            if let link = entry.link {
                guard entry.size == 0, !entry.directory else { throw CocoaError(.fileReadCorruptFile) }
                links.append((file, link))
            } else if entry.directory {
                guard entry.size == 0 else { throw CocoaError(.fileReadCorruptFile) }
                try fm.createDirectory(at: file, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: file)
                defer { try? output.close() }
                var remaining = entry.size
                while remaining > 0 {
                    let chunk = try read(input, count: Int(min(remaining, 262144)))
                    try output.write(contentsOf: chunk)
                    remaining -= UInt64(chunk.count)
                }
                try output.synchronize()
            }
            if entry.link == nil { attributes.append((file, entry)) }
        }
        guard (try input.read(upToCount: 1))?.isEmpty != false,
              fm.fileExists(atPath: root.appendingPathComponent("App").path) else { throw CocoaError(.fileReadCorruptFile) }
        // Extract regular files first, so archive paths can never traverse links.
        for (file, destination) in links {
            guard !fm.fileExists(atPath: file.path),
                  !seen.contains(where: { $0.hasPrefix(String(file.path.dropFirst(root.path.count + 1)) + "/") }) else { throw CocoaError(.fileReadCorruptFile) }
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: file.path, withDestinationPath: destination)
        }
        for (file, entry) in attributes.reversed() {
            var values: [FileAttributeKey: Any] = [:]
            if let permissions = entry.permissions { values[.posixPermissions] = permissions & 0o777 }
            if let modified = entry.modified { values[.modificationDate] = modified }
            try fm.setAttributes(values, ofItemAtPath: file.path)
        }
    }

    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try file.read(upToCount: count - result.count), !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            result.append(chunk)
        }
        return result
    }
}
