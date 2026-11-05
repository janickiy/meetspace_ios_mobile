import Foundation
import CryptoKit
import MeetSpaceCore

public struct StagedFile: Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let filename: String
    public let mimeType: String
    public let size: Int
}

/// Private, non-backed-up, account-scoped temporary files. Exports happen only through the system UI.
public actor AccountFileStore {
    private let root: URL
    public init(account: AccountRecord, baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let scope = SHA256.hash(data: Data(account.id.utf8)).map { String(format: "%02x", $0) }.joined()
        root = base.appendingPathComponent("MeetSpaceTransfers", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
    }
    public func stage(_ imported: URL) throws -> StagedFile {
        try Task.checkCancellation()
        let access = imported.startAccessingSecurityScopedResource()
        defer { if access { imported.stopAccessingSecurityScopedResource() } }
        let filename = imported.lastPathComponent
        let mimeType = try FilePolicy.mimeType(for: filename)
        var coordinated: Result<Data, any Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: imported, options: .withoutChanges, error: &coordinationError) { url in
            coordinated = Result { try Self.readBounded(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let coordinated else { throw ClientError.unsupportedFile }
        let data = try coordinated.get()
        let id = UUID()
        let url = try write(data, filename: filename, directory: id)
        return StagedFile(id: id, url: url, filename: filename, mimeType: mimeType, size: data.count)
    }
    private static func readBounded(_ imported: URL) throws -> Data {
        let metadata = try imported.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true else { throw ClientError.unsupportedFile }
        guard let size = metadata.fileSize, (1...FilePolicy.maximumBytes).contains(size) else { throw ClientError.fileTooLarge }
        let file = try FileHandle(forReadingFrom: imported)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count + chunk.count <= FilePolicy.maximumBytes else { throw ClientError.fileTooLarge }
            data.append(chunk)
        }
        guard !data.isEmpty else { throw ClientError.fileTooLarge }
        return data
    }
    public func storeDownload(_ data: Data, filename: String) throws -> URL {
        guard !data.isEmpty, data.count <= FilePolicy.maximumBytes else { throw ClientError.fileTooLarge }
        return try write(data, filename: filename, directory: UUID())
    }
    public func remove(_ url: URL) {
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    private func write(_ data: Data, filename: String, directory: UUID) throws -> URL {
        try Task.checkCancellation()
        try FilePolicy.validateName(filename)
        var folder = root.appendingPathComponent(directory.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let destination = folder.appendingPathComponent(filename, isDirectory: false)
        do {
            #if os(iOS)
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            #endif
            try Task.checkCancellation()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
