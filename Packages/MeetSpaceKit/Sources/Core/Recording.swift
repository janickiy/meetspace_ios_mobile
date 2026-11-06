import Foundation

public enum RecordingMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case composite, audioOnly = "audio_only", individualTracks = "individual_tracks", screenFocus = "screen_focus"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .composite: "Общий вид"
        case .audioOnly: "Только аудио"
        case .individualTracks: "Отдельные дорожки"
        case .screenFocus: "Демонстрация экрана"
        }
    }
}

/// Public metadata only. Signed object-storage URLs never enter observable or persisted state.
public struct RecordingFile: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let type: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int64?
    public let checksumSHA256: String?
    public let durationSec: Int?
    public let available: Bool
    public var playable: Bool { available && ["final_mp4", "final_audio"].contains(type) }
    public init(id: UUID, type: String, filename: String, mimeType: String, sizeBytes: Int64? = nil,
                checksumSHA256: String? = nil, durationSec: Int? = nil, available: Bool = true) {
        self.id = id; self.type = type; self.filename = filename; self.mimeType = mimeType
        self.sizeBytes = sizeBytes; self.checksumSHA256 = checksumSHA256; self.durationSec = durationSec; self.available = available
    }
}

public struct MeetingRecording: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let conferenceID: UUID
    public let mode: String
    public let status: String
    public let createdAt: Date
    public let startedAt: Date?
    public let requestedBy: UUID?
    public let durationSec: Int?
    public let files: [RecordingFile]
    public var ready: Bool { ["ready", "partial_ready"].contains(status) }
    public var active: Bool { ["starting", "recording", "degraded", "stopping", "processing", "finalizing", "uploading"].contains(status) }
    public var stoppable: Bool { ["starting", "recording", "degraded"].contains(status) }
    public var media: RecordingFile? { ready ? (files.first { $0.type == "final_mp4" && $0.playable } ?? files.first { $0.type == "final_audio" && $0.playable }) : nil }
    public var statusTitle: String {
        switch status {
        case "starting": "Запись запускается"
        case "recording": "Идёт запись"
        case "degraded": "Запись с ограничениями"
        case "stopping": "Запись останавливается"
        case "processing", "finalizing", "uploading": "Обрабатывается"
        case "ready": "Готова"
        case "partial_ready": "Готова частично"
        case "failed": "Не удалось записать"
        case "cancelled": "Запись отменена"
        default: "Неизвестный статус записи"
        }
    }
    public init(id: UUID, conferenceID: UUID, mode: String, status: String, createdAt: Date,
                startedAt: Date? = nil, requestedBy: UUID? = nil, durationSec: Int? = nil, files: [RecordingFile] = []) {
        self.id = id; self.conferenceID = conferenceID; self.mode = mode; self.status = status
        self.createdAt = createdAt; self.startedAt = startedAt; self.requestedBy = requestedBy
        self.durationSec = durationSec; self.files = files
    }
}

public struct RecordingLibraryItem: Equatable, Sendable, Identifiable {
    public let conference: Conference
    public let recording: MeetingRecording
    public var id: UUID { recording.id }
    public init(conference: Conference, recording: MeetingRecording) { self.conference = conference; self.recording = recording }
}
public struct RecordingLibraryPage: Sendable {
    public let items: [RecordingLibraryItem]
    public let nextCursor: String?
    public init(items: [RecordingLibraryItem], nextCursor: String?) { self.items = items; self.nextCursor = nextCursor }
}

public enum RecordingAccessError: Error, Equatable, Sendable {
    case unavailable, unsupportedMedia, invalidArtifact, tooLarge, noPermission, incompatibleServer
}

public enum RecordingPermissions {
    public static func canStart(conference: Conference, participant: ConferenceParticipant, accountID: UUID) -> Bool {
        conference.status == "active" && participant.conferenceId == conference.id && participant.userId == accountID && participant.canParticipate && participant.role != "guest"
    }
    public static func canStop(_ recording: MeetingRecording, conference: Conference, participant: ConferenceParticipant, accountID: UUID) -> Bool {
        participant.conferenceId == conference.id && recording.conferenceID == conference.id && participant.userId == accountID && participant.canReadHistory && participant.role != "guest" && recording.stoppable &&
            ((conference.ownerId == accountID && participant.role == "owner") || recording.requestedBy == accountID)
    }
}
