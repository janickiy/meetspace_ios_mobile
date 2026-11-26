import Foundation
import SwiftUI
import MeetSpaceCore
import MeetSpaceBroadcast

public enum ConferenceAudioActivation: Equatable, Sendable { case application, callKit }

public struct ConferenceMediaConfiguration: Sendable {
    public var iceServers: [ICEServer]
    public var iceTransportPolicy: String
    public var maxPeers: Int
    public var mediaPeerID: UUID
    public var maxWidth: Int
    public var maxHeight: Int
    public var maxFrameRate: Int
    public var microphoneAllowed: Bool
    public var cameraAllowed: Bool
    public var screenAllowed: Bool
    public var audioActivation: ConferenceAudioActivation
    public var preferFrontCamera: Bool
    public var receiveVideo: Bool
    /// Задаёт параметры WebRTC-соединения, источников публикации и захвата видео для одной попытки подключения.
    /// - Parameters:
    ///   - iceServers: Серверы STUN и TURN для поиска доступного маршрута.
    ///   - iceTransportPolicy: Политика ICE: all разрешает все маршруты, relay ограничивает их ретрансляцией.
    ///   - maxPeers: Лимит участников, по которому резервируются дорожки приёма.
    ///   - mediaPeerID: Идентификатор медиасоединения на сервере конференции.
    ///   - maxWidth: Предельная ширина видео в пикселях.
    ///   - maxHeight: Предельная высота видео в пикселях.
    ///   - maxFrameRate: Целевая верхняя граница частоты кадров в секунду.
    ///   - microphoneAllowed: Разрешена ли публикация микрофона.
    ///   - cameraAllowed: Разрешена ли публикация камеры.
    ///   - screenAllowed: Разрешена ли публикация экрана.
    ///   - audioActivation: Кто управляет активацией аудиосессии — приложение или CallKit.
    ///   - preferFrontCamera: Следует ли начинать с фронтальной камеры.
    ///   - receiveVideo: Нужно ли принимать видео других участников.
    public init(iceServers: [ICEServer], iceTransportPolicy: String = "all", maxPeers: Int = 8,
                mediaPeerID: UUID, maxWidth: Int = 1280, maxHeight: Int = 720, maxFrameRate: Int = 30,
                microphoneAllowed: Bool = true, cameraAllowed: Bool = true,
                screenAllowed: Bool = false,
                audioActivation: ConferenceAudioActivation = .application,
                preferFrontCamera: Bool = true, receiveVideo: Bool = true) {
        self.iceServers = iceServers; self.iceTransportPolicy = iceTransportPolicy
        self.maxPeers = maxPeers; self.mediaPeerID = mediaPeerID
        self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxFrameRate = maxFrameRate
        self.microphoneAllowed = microphoneAllowed; self.cameraAllowed = cameraAllowed
        self.screenAllowed = screenAllowed
        self.audioActivation = audioActivation
        self.preferFrontCamera = preferFrontCamera
        self.receiveVideo = receiveVideo
    }
}

public struct ConferenceICECandidate: Codable, Equatable, Sendable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int32
    /// Описывает ICE-кандидат вместе с адресуемой секцией SDP.
    /// - Parameters:
    ///   - candidate: Строка кандидата в формате SDP.
    ///   - sdpMid: Идентификатор медиа-секции, если он известен.
    ///   - sdpMLineIndex: Индекс медиа-секции в SDP, начиная с нуля.
    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        self.candidate = candidate; self.sdpMid = sdpMid; self.sdpMLineIndex = sdpMLineIndex
    }
}

public struct ConferenceMediaPublication: Codable, Equatable, Sendable {
    public let mid: String
    public let source: String
    public let trackId: String
    /// Описывает дорожку, которую приложение объявляет серверу вместе с предложением SDP.
    /// - Parameters:
    ///   - mid: Идентификатор медиа-секции.
    ///   - source: Обозначение источника, например microphone или video/screen.
    ///   - trackId: Идентификатор публикуемой дорожки для сервера.
    public init(mid: String, source: String, trackId: String) {
        self.mid = mid; self.source = source; self.trackId = trackId
    }
}

public struct ConferenceMediaOffer: Equatable, Sendable {
    public let sdp: String
    public let publications: [ConferenceMediaPublication]
    /// Объединяет локальное предложение SDP с перечнем публикуемых дорожек.
    /// - Parameters:
    ///   - sdp: Текст предложения SDP.
    ///   - publications: Источники, объявляемые в этом предложении.
    public init(sdp: String, publications: [ConferenceMediaPublication]) {
        self.sdp = sdp; self.publications = publications
    }
}

/// The view model resolves remote IDs/MIDs against the server's media catalog before displaying a tile.
public struct ConferenceVideoTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let mid: String?
    public let streamID: String?
    public let isLocal: Bool
    /// Описывает видеодорожку для сопоставления с участником и показа в интерфейсе.
    /// - Parameters:
    ///   - id: Идентификатор дорожки WebRTC.
    ///   - mid: Идентификатор согласованной медиа-секции, если известен.
    ///   - streamID: Идентификатор медиапотока, если он известен.
    ///   - isLocal: Принадлежит ли дорожка этому устройству.
    public init(id: String, mid: String?, streamID: String?, isLocal: Bool) {
        self.id = id; self.mid = mid; self.streamID = streamID; self.isLocal = isLocal
    }
}

public enum ConferenceMediaConnectionState: String, Equatable, Sendable {
    case new, connecting, connected, disconnected, failed, closed
}

/// One WebRTC sampling interval. Remote levels are keyed by the negotiated receiver MID.
public struct ConferenceMicrophoneLevels: Sendable {
    public let local: Double
    public let remoteByMID: [String: Double]

    /// Собирает измеренные за один интервал уровни микрофонов.
    /// - Parameters:
    ///   - local: Нормализованная амплитуда собственного микрофона от 0 до 1.
    ///   - remoteByMID: Амплитуды входящих дорожек по идентификаторам медиа-секций.
    public init(local: Double = 0, remoteByMID: [String: Double] = [:]) {
        self.local = local
        self.remoteByMID = remoteByMID
    }
}

struct ConferenceAudioSample: Sendable {
    let level: Double?
    let energy: Double?
    let duration: Double?
    let packets: UInt64?

    /// Вычисляет среднеквадратичную амплитуду по приросту энергии и длительности, учитывая поступление новых пакетов.
    /// - Parameter previous: Предыдущая выборка того же источника или входящего RTP-потока.
    func rms(since previous: Self?) -> Double {
        if let packets, packets <= (previous?.packets ?? 0) { return 0 }
        if energy != nil || duration != nil {
            guard let energy, let duration, let oldEnergy = previous?.energy, let oldDuration = previous?.duration,
                  energy.isFinite, duration.isFinite, energy >= oldEnergy, duration > oldDuration else { return 0 }
            return min(1, sqrt((energy - oldEnergy) / (duration - oldDuration)))
        }
        guard let level, level.isFinite, (0...1).contains(level) else { return 0 }
        return level
    }
}

public enum ConferenceMediaError: Error, Equatable, Sendable {
    case unavailable, invalidConfiguration, notConfigured, negotiation, invalidCandidate, publicationBlocked
    case microphonePermissionDenied, cameraPermissionDenied, cameraUnavailable, capture, audioSession, interrupted
    case screenUnavailable, invalidScreenFrame
}

public enum ConferenceMediaEvent: Equatable, Sendable {
    case candidate(ConferenceICECandidate)
    case iceGatheringComplete
    case negotiationNeeded
    case connectionState(ConferenceMediaConnectionState)
    case videoTrackAdded(ConferenceVideoTrack)
    case videoTrackRemoved(String)
    case captureState(microphone: Bool, camera: Bool, frontCamera: Bool)
    case screenCaptureState(Bool)
    case audioRoute(String)
    case interrupted(Bool)
    case networkPathChanged
    case failure(ConferenceMediaError)
}

/// One engine belongs to one conference attempt. Capture starts only after an explicit enabled action.
/// `close` is final, drains camera shutdown, detaches renderers and releases the peer/audio session.
@MainActor public protocol ConferenceMediaEngine: AnyObject {
    var events: AsyncStream<ConferenceMediaEvent> { get }
    var localVideoTrackID: String { get }
    var localScreenVideoTrackID: String { get }
    /// Готовит медиасоединение конференции с заданными параметрами устройств и сети.
    /// - Parameter configuration: Настройки ICE, разрешения публикации и ограничения видеозахвата.
    func configure(_ configuration: ConferenceMediaConfiguration) async throws
    /// Создаёт локальное предложение SDP и список объявляемых серверу публикаций.
    /// - Parameter iceRestart: Запрашивать ли новый цикл ICE для соединения.
    func makeOffer(iceRestart: Bool) async throws -> ConferenceMediaOffer
    /// Устанавливает удалённое описание соединения из ответа сервера.
    /// - Parameter sdp: SDP-ответ на текущее локальное предложение.
    func applyAnswer(_ sdp: String) async throws
    /// Отменяет ожидающее локальное предложение, возвращая соединение в стабильное состояние.
    func rollbackLocalOffer() async throws
    /// Передаёт в медиасоединение ICE-кандидат, полученный от сервера.
    /// - Parameter candidate: Сетевой кандидат и адресуемая секция SDP.
    func addRemoteCandidate(_ candidate: ConferenceICECandidate) async throws
    /// Применяет серверные разрешения на публикацию устройств и демонстрацию экрана.
    /// - Parameters:
    ///   - microphone: Разрешена ли передача звука микрофона.
    ///   - camera: Разрешена ли передача видео с камеры.
    ///   - screen: Разрешена ли передача видео экрана.
    func setPublicationPermissions(microphone: Bool, camera: Bool, screen: Bool) async throws
    /// Включает или останавливает публикацию локального микрофона.
    /// - Parameter enabled: Значение true запрашивает передачу звука микрофона.
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    /// Включает или останавливает публикацию локальной камеры.
    /// - Parameter enabled: Значение true запрашивает передачу видео с камеры.
    func setCameraEnabled(_ enabled: Bool) async throws
    /// Включает или останавливает публикацию демонстрации экрана.
    /// - Parameter enabled: Значение true запрашивает отправку видео с экрана.
    func setScreenEnabled(_ enabled: Bool) async throws
    /// Передаёт кадр текущей демонстрации в видеодорожку экрана.
    /// - Parameter frame: Кадр с идентификатором сеанса, геометрией и временем показа.
    func pushScreenFrame(_ frame: ScreenBroadcastFrame) throws
    /// Переключает захват между фронтальной и задней камерами.
    func switchCamera() async throws
    /// Выбирает динамик устройства или возвращает системный маршрут вывода звонка.
    /// - Parameter enabled: Значение true выбирает динамик устройства.
    func setSpeakerEnabled(_ enabled: Bool) throws
    /// Возвращает текущие уровни собственного микрофона и входящих аудиодорожек.
    func microphoneLevels() async -> ConferenceMicrophoneLevels
    /// Приостанавливает захват медиа при уходе приложения в фон или системном прерывании.
    func suspend() async
    /// Завершает медиасоединение, освобождает устройства и закрывает поток событий.
    func close() async
    /// Возвращает представление для отображения видеодорожки.
    /// - Parameters:
    ///   - trackID: Идентификатор локальной или удалённой видеодорожки.
    ///   - mirrored: Нужно ли отразить изображение по горизонтали.
    func videoView(trackID: String, mirrored: Bool) -> AnyView
    /// Возвращает представление видеодорожки с выбранным способом масштабирования.
    /// - Parameters:
    ///   - trackID: Идентификатор локальной или удалённой видеодорожки.
    ///   - mirrored: Нужно ли отразить изображение по горизонтали.
    ///   - fit: Значение true вписывает кадр целиком, false заполняет область с обрезкой.
    func videoView(trackID: String, mirrored: Bool, fit: Bool) -> AnyView
}

public extension ConferenceMediaEngine {
    /// Возвращает нулевые уровни для реализаций без измерителя звука.
    func microphoneLevels() async -> ConferenceMicrophoneLevels { .init() }

    /// Использует базовое представление видеодорожки, если движок не реализует отдельную настройку масштабирования.
    /// - Parameters:
    ///   - trackID: Идентификатор локальной или удалённой видеодорожки.
    ///   - mirrored: Нужно ли отразить изображение по горизонтали.
    ///   - fit: Значение true вписывает кадр целиком, false заполняет область с обрезкой.
    func videoView(trackID: String, mirrored: Bool, fit: Bool) -> AnyView {
        videoView(trackID: trackID, mirrored: mirrored)
    }
}

@MainActor public enum ConferenceMediaFactory {
    /// Выбирает нативный медиадвижок iOS или адаптер недоступности для текущей платформы.
    public static func make() -> any ConferenceMediaEngine {
        #if os(iOS)
        NativeConferenceMediaEngine()
        #else
        UnavailableConferenceMediaEngine()
        #endif
    }
}

public enum WebRTCLibrary {
    public static let version = "156.0.0"
    public static var licenseText: String {
        ["WebRTC-LICENSE", "WebRTC-PATENTS", "WebRTC-Distribution-LICENSE", "WebRTC-THIRD-PARTY-NOTICES"].compactMap { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n")
    }
}

/// Host previews/tests never silently pretend that WebRTC media is available on macOS.
#if !os(iOS)
@MainActor private final class UnavailableConferenceMediaEngine: ConferenceMediaEngine {
    let events = AsyncStream<ConferenceMediaEvent> { $0.finish() }
    let localVideoTrackID = "unavailable"
    let localScreenVideoTrackID = "unavailable-screen"
    /// Сообщает о недоступности настройки WebRTC на этой платформе.
    /// - Parameter configuration: Настройки ICE, разрешения публикации и ограничения видеозахвата.
    func configure(_ configuration: ConferenceMediaConfiguration) async throws { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности создания предложения SDP.
    /// - Parameter iceRestart: Запрашивать ли новый цикл ICE для соединения.
    func makeOffer(iceRestart: Bool) async throws -> ConferenceMediaOffer { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности установки ответа SDP.
    /// - Parameter sdp: SDP-ответ на текущее локальное предложение.
    func applyAnswer(_ sdp: String) async throws { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности отката предложения SDP.
    func rollbackLocalOffer() async throws { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности обработки ICE-кандидата.
    /// - Parameter candidate: Сетевой кандидат и адресуемая секция SDP.
    func addRemoteCandidate(_ candidate: ConferenceICECandidate) async throws { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности настройки разрешений на публикацию.
    /// - Parameters:
    ///   - microphone: Разрешена ли передача звука микрофона.
    ///   - camera: Разрешена ли передача видео с камеры.
    ///   - screen: Разрешена ли передача видео экрана.
    func setPublicationPermissions(microphone: Bool, camera: Bool, screen: Bool) async throws { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности публикации микрофона.
    /// - Parameter enabled: Значение true запрашивает передачу звука микрофона.
    func setMicrophoneEnabled(_ enabled: Bool) async throws { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности публикации камеры.
    /// - Parameter enabled: Значение true запрашивает передачу видео с камеры.
    func setCameraEnabled(_ enabled: Bool) async throws { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности демонстрации экрана.
    /// - Parameter enabled: Значение true запрашивает отправку видео с экрана.
    func setScreenEnabled(_ enabled: Bool) async throws { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности передачи видеокадра экрана.
    /// - Parameter frame: Кадр с идентификатором сеанса, геометрией и временем показа.
    func pushScreenFrame(_ frame: ScreenBroadcastFrame) throws { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности переключения камеры.
    func switchCamera() async throws { throw ConferenceMediaError.unavailable }
    /// Сообщает о недоступности управления аудиомаршрутом.
    /// - Parameter enabled: Значение true выбирает динамик устройства.
    func setSpeakerEnabled(_ enabled: Bool) throws { throw ConferenceMediaError.unavailable }
    /// Пропускает приостановку медиазахвата на платформе без активных устройств.
    func suspend() async { }
    /// Завершает работу адаптера без открытого медиасоединения.
    func close() async { }
    /// Возвращает прозрачное представление на платформе без видеовывода.
    /// - Parameters:
    ///   - trackID: Идентификатор локальной или удалённой видеодорожки.
    ///   - mirrored: Нужно ли отразить изображение по горизонтали.
    func videoView(trackID: String, mirrored: Bool) -> AnyView { AnyView(Color.clear) }
}
#endif
