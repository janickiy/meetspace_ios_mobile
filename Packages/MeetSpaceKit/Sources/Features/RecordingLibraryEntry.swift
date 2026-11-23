import Foundation
import MeetSpaceCore
import MeetSpaceDesignSystem

enum RecordingPreviewKind {
    case video, screen, audio, tracks, unknown

    init(mode: RecordingMode?) {
        switch mode {
        case .composite: self = .video
        case .screenFocus: self = .screen
        case .audioOnly: self = .audio
        case .individualTracks: self = .tracks
        case nil: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .video: "Видеозапись"
        case .screen: "Демонстрация экрана"
        case .audio: "Аудиозапись"
        case .tracks: "Дорожки участников"
        case .unknown: "Запись встречи"
        }
    }

    var icon: String {
        switch self {
        case .video: "video"
        case .screen: "display"
        case .audio: "mic"
        case .tracks: "person.2"
        case .unknown: "doc"
        }
    }
}

enum RecordingOpenAction: String {
    case watch = "Смотреть", listen = "Слушать", materials = "Материалы", open = "Открыть"

    var icon: String {
        switch self {
        case .watch, .listen: "play"
        case .materials: "folder"
        case .open: "arrow.right"
        }
    }
}

struct RecordingLibraryEntry: Identifiable {
    let id: String
    let meetingID: String
    let kind: RecordingPreviewKind
    let title: String
    let date: Date
    let duration: Int?
    var owner: String?
    let participantCount: Int?
    let initials: [String]
    let isLive: Bool
    let statusTitle: String?
    let canDelete: Bool
    var isCapturing = false
    var sizeText: String?
    var sampleDay: Date?
    var mediaAction: RecordingOpenAction?

    var openAction: RecordingOpenAction {
        if let mediaAction { return mediaAction }
        if isLive { return .open }
        return switch kind {
        case .video, .screen: .watch
        case .audio: .listen
        case .tracks: .materials
        case .unknown: .open
        }
    }

    var durationText: String? {
        duration.map { String(format: "%02lld:%02lld", Int64($0 / 60), Int64($0 % 60)) }
    }

    var peopleText: String? {
        guard let count = participantCount else { return nil }
        let noun: String = switch (count % 100, count % 10) {
        case (11...14, _): "участников"
        case (_, 1): "участник"
        case (_, 2...4): "участника"
        default: "участников"
        }
        return "\(count) " + tr(noun)
    }
}

extension RecordingLibraryEntry {
    init(row: RecordingLibraryItem, account: AccountRecord) {
        let recording = row.recording
        let conference = row.conference
        self.init(id: row.id.uuidString, meetingID: conference.id.uuidString,
                  kind: RecordingPreviewKind(mode: RecordingMode(rawValue: recording.mode)), title: conference.title,
                  date: recording.startedAt ?? recording.createdAt, duration: recording.ready ? (recording.durationSec ?? recording.media?.durationSec) : nil,
                  owner: conference.ownerId == account.user.id ? Self.ownName(account.user.name) : nil,
                  participantCount: nil, initials: [], isLive: conference.status == "active",
                  statusTitle: recording.statusTitle, canDelete: RecordingPermissions.canDelete(row, accountID: account.user.id),
                  isCapturing: ["recording", "degraded"].contains(recording.status))
        if let media = recording.media {
            mediaAction = media.type == "final_audio" ? .listen : .watch
        } else if recording.ready, recording.files.contains(where: { $0.type == "tracks_archive" && $0.available }) {
            mediaAction = .materials
        } else {
            mediaAction = .open
        }
    }

    static func ownName(_ name: String) -> String { name + " (" + tr("вы") + ")" }

    // Stable indexes are also used by the demo screen catalog and navigation stack.
    static func demoSamples(ownerName: String) -> [Self] {
        let own = ownName(ownerName)
        let calendar = Calendar(identifier: .gregorian)
        let sampleDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16))!
        func sample(_ index: Int, _ title: String, meeting: String, kind: RecordingPreviewKind,
                    day: Int, hour: Int, minute: Int = 0, seconds: Int?, mb: Int?, people: Int,
                    owner: String, canDelete: Bool, live: Bool = false) -> Self {
            let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
            return Self(id: String(index), meetingID: meeting, kind: kind, title: tr(title), date: date,
                        duration: seconds, owner: owner, participantCount: people, initials: ["АС", "АК", "МП", "ДВ"],
                        isLive: live, statusTitle: live ? "Идёт запись" : nil, canDelete: canDelete, isCapturing: live,
                        sizeText: mb.map { "\($0) " + tr("МБ") }, sampleDay: sampleDay)
        }
        return [
            sample(0, "Продукт. Следующая глава", meeting: "product", kind: .video, day: 15, hour: 10,
                   seconds: 2538, mb: 128, people: 5, owner: own, canDelete: true),
            sample(1, "Дизайн-ревью мобильного приложения", meeting: "design", kind: .video, day: 14, hour: 14,
                   minute: 30, seconds: 1866, mb: 96, people: 4, owner: "Анна Кузнецова", canDelete: false),
            sample(2, "Планы на октябрь", meeting: "plans", kind: .audio, day: 12, hour: 9,
                   seconds: 1722, mb: 27, people: 4, owner: own, canDelete: true),
            sample(3, "Демо новой версии", meeting: "demo", kind: .video, day: 11, hour: 16,
                   seconds: 3252, mb: 168, people: 8, owner: "Максим Петров", canDelete: true),
            sample(4, "Продукт. Следующая глава", meeting: "product", kind: .tracks, day: 15, hour: 10,
                   minute: 45, seconds: 720, mb: 42, people: 5, owner: own, canDelete: true),
            sample(5, "Ежедневная синхронизация", meeting: "live", kind: .video, day: 16, hour: 10,
                   seconds: nil, mb: nil, people: 6, owner: own, canDelete: false, live: true)
        ]
    }
}
