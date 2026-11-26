import Foundation
import CryptoKit
import MeetSpaceCore

/// Device-local removal, matching Android. The scope contains origin and user ID, never credentials.
public protocol HiddenChatMessagesStore: Sendable {
    /// Возвращает идентификаторы сообщений, скрытых в выбранной области.
    /// - Parameter scope: Ключ области хранения, разделяющий списки скрытых сообщений.
    func load(scope: String) async throws -> Set<UUID>
    /// Добавляет сообщения к скрытым и возвращает обновлённый набор идентификаторов.
    /// - Parameters:
    ///   - ids: Идентификаторы выбранных сообщений.
    ///   - scope: Ключ области хранения, разделяющий списки скрытых сообщений.
    func hide(_ ids: Set<UUID>, scope: String) async throws -> Set<UUID>
}

public actor MemoryHiddenChatMessagesStore: HiddenChatMessagesStore {
    private var scopes: [String: Set<UUID>] = [:]
    /// Создаёт пустое хранилище скрытых сообщений в памяти.
    public init() {}
    /// Возвращает идентификаторы сообщений, скрытых в выбранной области.
    /// - Parameter scope: Ключ области хранения, разделяющий списки скрытых сообщений.
    public func load(scope: String) -> Set<UUID> { scopes[scope, default: []] }
    /// Добавляет сообщения к скрытым и возвращает обновлённый набор идентификаторов.
    /// - Parameters:
    ///   - ids: Идентификаторы выбранных сообщений.
    ///   - scope: Ключ области хранения, разделяющий списки скрытых сообщений.
    public func hide(_ ids: Set<UUID>, scope: String) throws -> Set<UUID> {
        let next = scopes[scope, default: []].union(ids)
        guard next.count <= 100_000 else { throw ClientError.storage }
        scopes[scope] = next
        return next
    }
}

/// Atomic, protected, non-backed-up files containing only random message UUIDs.
/// Shared production instance serializes read/modify/write across account models.
public actor DeviceHiddenChatMessagesStore: HiddenChatMessagesStore {
    public static let shared = DeviceHiddenChatMessagesStore()
    private let directory: URL
    /// Выбирает каталог устройства для списков скрытых сообщений.
    /// - Parameter baseDirectory: Родительский каталог для локального хранилища. При nil выбирается системный каталог.
    public init(baseDirectory: URL? = nil) {
        directory = (baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("MeetSpaceHiddenMessages-v1", isDirectory: true)
    }
    /// Возвращает идентификаторы сообщений, скрытых в выбранной области.
    /// - Parameter scope: Ключ области хранения, разделяющий списки скрытых сообщений.
    public func load(scope: String) throws -> Set<UUID> { try read(file(scope)) }
    /// Добавляет сообщения к скрытым и возвращает обновлённый набор идентификаторов.
    /// - Parameters:
    ///   - ids: Идентификаторы выбранных сообщений.
    ///   - scope: Ключ области хранения, разделяющий списки скрытых сообщений.
    public func hide(_ ids: Set<UUID>, scope: String) throws -> Set<UUID> {
        let path = file(scope), previous = try read(path), next = previous.union(ids)
        guard next.count <= 100_000 else { throw ClientError.storage }
        if next == previous { return next }
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let data = Data((next.map { $0.uuidString.lowercased() }.sorted().joined(separator: "\n") + "\n").utf8)
        #if os(iOS)
        try data.write(to: path, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #endif
        guard try read(path) == next else { throw ClientError.storage }
        return next
    }
    /// Удаляет сохранённый список скрытых сообщений для выбранной области.
    /// - Parameter scope: Ключ области хранения, разделяющий списки скрытых сообщений.
    public func erase(scope: String) throws {
        let path = file(scope)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    /// Вычисляет путь к списку скрытых сообщений по хешу ключа области.
    /// - Parameter scope: Ключ области хранения, разделяющий списки скрытых сообщений.
    private func file(_ scope: String) -> URL {
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }
    /// Читает файл скрытых сообщений с проверкой размера и формата идентификаторов.
    /// - Parameter path: Путь к локальному списку идентификаторов скрытых сообщений.
    private func read(_ path: URL) throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let metadata = try path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true, let size = metadata.fileSize, size <= 100_000 * 37 else { throw ClientError.storage }
        let data = try Data(contentsOf: path)
        guard data.count <= 100_000 * 37, let text = String(data: data, encoding: .utf8) else { throw ClientError.storage }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.last == "" else { throw ClientError.storage }
        var ids: Set<UUID> = []
        for line in lines.dropLast() {
            guard let id = UUID(uuidString: String(line)), id.uuidString.lowercased() == line, ids.insert(id).inserted else { throw ClientError.storage }
        }
        return ids
    }
}
