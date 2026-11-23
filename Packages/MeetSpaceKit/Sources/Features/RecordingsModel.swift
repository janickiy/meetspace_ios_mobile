import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI

@MainActor @Observable public final class RecordingsModel {
    public let account: AccountRecord
    public private(set) var items: [RecordingLibraryItem] = []
    public private(set) var nextCursor: String?
    public private(set) var selected: RecordingLibraryItem?
    public private(set) var modes: [RecordingMode] = []
    public private(set) var conferenceItems: [UUID: [MeetingRecording]] = [:]
    public private(set) var loading = false
    public private(set) var controlling = false
    public private(set) var downloading = false
    public private(set) var progress: Double = 0
    public private(set) var playbackURL: URL?
    public private(set) var exportURL: URL?
    public var error: String?
    public var query = ""
    public var modeFilter = "all"
    public var statusFilter = "all"
    private let repository: RecordingsRepository
    private let downloads: any RecordingDownloading
    private var transfer: Task<URL, Error>?
    private var transferID = UUID()
    private var selectionID: UUID?
    private var generation = UUID()
    private var closed = false

    public init(client: AuthenticatedClient, downloads: (any RecordingDownloading)? = nil) {
        account = client.account; repository = RecordingsRepository(client: client)
        self.downloads = downloads ?? URLSessionRecordingDownloader(account: client.account)
    }
    public var visibleItems: [RecordingLibraryItem] {
        items.filter { (query.isEmpty || $0.conference.title.localizedCaseInsensitiveContains(query)) &&
            (modeFilter == "all" || $0.recording.mode == modeFilter) &&
            (statusFilter == "all" || (statusFilter == "ready" ? $0.recording.ready : $0.recording.active)) }
    }
    public var canDeleteSelected: Bool {
        guard let selected else { return false }
        return RecordingPermissions.canDelete(selected, accountID: account.user.id)
    }
    public func deleteSelected() async {
        guard let selected else { return }
        await delete(selected)
    }
    public func delete(_ row: RecordingLibraryItem) async {
        guard !closed, !loading, !downloading,
              let current = selected?.id == row.id ? selected : items.first(where: { $0.id == row.id }),
              RecordingPermissions.canDelete(current, accountID: account.user.id) else { return }
        let epoch = generation; loading = true; error = nil
        defer { if epoch == generation { loading = false } }
        do {
            try await repository.delete(conferenceID: current.conference.id, recordingID: current.id)
            guard valid(epoch) else { return }
            items.removeAll { $0.id == current.id }
            conferenceItems[current.conference.id]?.removeAll { $0.id == current.id }
            if selected?.id == current.id { selected = nil; await clearLocalFiles() }
        } catch { if valid(epoch) { self.error = Self.message(error) } }
    }
    public func load(more: Bool = false) async {
        guard !closed, !loading, !more || nextCursor != nil else { return }
        let epoch = generation; loading = true; error = nil
        defer { if epoch == generation { loading = false } }
        do {
            let result = try await repository.library(cursor: more ? nextCursor : nil)
            guard valid(epoch) else { return }
            let existing = more ? items : []
            items = existing + result.items.filter { row in !existing.contains { $0.id == row.id } }
            nextCursor = result.nextCursor
        } catch { if valid(epoch) { self.error = Self.message(error) } }
    }
    public func select(_ row: RecordingLibraryItem) async {
        guard !closed, !loading, !downloading else { return }
        let requestID = UUID(); selectionID = requestID
        let epoch = generation; loading = true; error = nil
        selected = nil
        await clearLocalFiles()
        defer {
            if generation == epoch, selectionID == requestID { loading = false; selectionID = nil }
        }
        guard valid(epoch), selectionID == requestID else { return }
        do {
            let recording = try await repository.read(conferenceID: row.conference.id, recordingID: row.id)
            guard valid(epoch), selectionID == requestID else { return }
            selected = RecordingLibraryItem(conference: row.conference, recording: recording)
        } catch { if valid(epoch), selectionID == requestID { self.error = Self.message(error) } }
    }
    public func back() async { await releaseSelection().value }

    @discardableResult func releaseSelection() -> Task<Void, Never> {
        // Detach the old operation and its files before suspension. The user can select
        // another recording while a cancelled transfer drains; never clear that new state.
        let pending = transfer
        let urls = [playbackURL, exportURL].compactMap { $0 }
        if selectionID != nil { loading = false; selectionID = nil }
        transferID = UUID(); transfer = nil; selected = nil
        playbackURL = nil; exportURL = nil; downloading = false; progress = 0; error = nil
        pending?.cancel()
        return Task { [downloads] in
            if let pending, let url = try? await pending.value { await downloads.remove(url) }
            for url in urls { await downloads.remove(url) }
        }
    }
    public func download(fileID: UUID, play: Bool) async {
        guard !closed, !loading, !downloading, let row = selected, row.recording.ready,
              let file = row.recording.files.first(where: { $0.id == fileID }), file.available,
              !play || file.playable else { return }
        let epoch = generation; let operationID = UUID(); transferID = operationID
        downloading = true; progress = 0; error = nil
        await clearLocalFiles()
        guard valid(epoch), transferID == operationID else { return }
        let task = Task { [repository, downloads] in
            try await repository.download(conferenceID: row.conference.id, recordingID: row.id, fileID: fileID, using: downloads) { [weak self] value in
                Task { @MainActor in if self?.valid(epoch) == true && self?.transferID == operationID { self?.progress = value } }
            }
        }
        transfer = task
        defer { if epoch == generation, transferID == operationID { downloading = false; transfer = nil } }
        do {
            let url = try await task.value
            guard valid(epoch), transferID == operationID, selected?.id == row.id else { await downloads.remove(url); return }
            if play { playbackURL = url } else { exportURL = url }
        } catch is CancellationError { }
        catch { if valid(epoch), transferID == operationID { self.error = Self.message(error) } }
    }
    public func cancelDownload() async {
        let pending = transfer; transferID = UUID(); transfer = nil; pending?.cancel(); downloading = false
        if let pending, let url = try? await pending.value { await downloads.remove(url) }
    }
    public func dismissExport() async {
        if let exportURL { self.exportURL = nil; await downloads.remove(exportURL) }
    }
    public func playbackFailed(url: URL? = nil) {
        guard let failedURL = playbackURL, url == nil || url == failedURL else { return }
        playbackURL = nil
        Task { await downloads.remove(failedURL) }
        error = "Этот файл не удалось воспроизвести. Можно скачать его и открыть в другом приложении."
    }
    public func loadConference(_ id: UUID) async {
        guard !closed, !controlling else { return }
        let epoch = generation; controlling = true
        defer { if epoch == generation { controlling = false } }
        do {
            let supported = try await repository.capabilities()
            let records = try await repository.list(conferenceID: id)
            guard valid(epoch) else { return }
            modes = supported
            conferenceItems[id] = records
            self.error = nil
        } catch {
            guard valid(epoch) else { return }
            conferenceItems[id] = nil
            self.error = Self.message(error)
        }
    }
    public func start(conference: Conference, participant: ConferenceParticipant, mode: RecordingMode) async {
        guard RecordingPermissions.canStart(conference: conference, participant: participant, accountID: account.user.id),
              modes.contains(mode), let records = conferenceItems[conference.id], !records.contains(where: \.active) else { return }
        await mutate(conference.id) { [repository] in _ = try await repository.start(conferenceID: conference.id, mode: mode) }
    }
    public func stop(_ recording: MeetingRecording, conference: Conference, participant: ConferenceParticipant) async {
        guard RecordingPermissions.canStop(recording, conference: conference, participant: participant, accountID: account.user.id) else { return }
        await mutate(conference.id) { [repository] in _ = try await repository.stop(conferenceID: conference.id, recordingID: recording.id) }
    }
    private func mutate(_ id: UUID, action: @escaping @Sendable () async throws -> Void) async {
        guard !closed, !controlling else { return }; controlling = true; error = nil; let epoch = generation
        defer { if epoch == generation { controlling = false } }
        do {
            try await action()
            let records = try await repository.list(conferenceID: id)
            guard valid(epoch) else { return }; conferenceItems[id] = records
        } catch {
            guard valid(epoch) else { return }
            // Never blindly retry a start/stop after an uncertain response.
            self.error = Self.message(error)
            let records = try? await repository.list(conferenceID: id)
            if valid(epoch) { conferenceItems[id] = records }
        }
    }
    public func close() async {
        guard !closed else { return }; closed = true; generation = UUID()
        playbackURL = nil; exportURL = nil; selected = nil; items = []; conferenceItems = [:]; modes = []; nextCursor = nil
        await cancelDownload(); await downloads.close(); loading = false; controlling = false; error = nil
    }
    private func clearLocalFiles() async {
        let urls = [playbackURL, exportURL].compactMap { $0 }; playbackURL = nil; exportURL = nil
        for url in urls { await downloads.remove(url) }
    }
    private func valid(_ epoch: UUID) -> Bool { !closed && generation == epoch && !Task.isCancelled }
    private static func message(_ error: any Error) -> String {
        switch error {
        case APIError.httpStatus(401), APIError.httpStatus(403), RecordingAccessError.noPermission: "Нет доступа к этой записи. Права могли измениться."
        case APIError.httpStatus(404), RecordingAccessError.unavailable: "Запись или её материалы больше недоступны."
        case APIError.httpStatus(409): "Состояние записи изменилось. Обновите список."
        case RecordingAccessError.incompatibleServer: "Сервер не поддерживает общий каталог записей. Обновите MeetSpace на сервере."
        case RecordingAccessError.tooLarge: "Файл больше 512 МБ. Откройте запись в веб-версии."
        case APIError.offline, APIError.timeout: "Не удалось загрузить запись. Проверьте подключение."
        case ClientError.sessionExpired: "Сессия истекла. Войдите снова."
        default: "Не удалось обработать запись. Повторите попытку."
        }
    }
}
