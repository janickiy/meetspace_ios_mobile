import Foundation
import MeetSpaceCore

/// Errors deliberately omit URLs, tickets, SDP, ICE credentials and server error bodies.
public enum ConferenceSignalError: Error, Equatable, Sendable {
    case invalidEnvelope, invalidPayload, invalidTicket, unsupportedProtocol
    case disconnected(retryable: Bool)
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null

    /// Декодирует значение JSON сигнального протокола с ограничением глубины вложенности.
    /// - Parameter decoder: Декодер, установленный вызывающей стороной для чтения полей модели.
    public init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= 64 else { throw ConferenceSignalError.invalidPayload }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Int64.self) { self = .integer(item) }
        else if let item = try? value.decode(Double.self), item.isFinite { self = .number(item) }
        else if let item = try? value.decode([String: JSONValue].self) { self = .object(item) }
        else if let item = try? value.decode([JSONValue].self) { self = .array(item) }
        else { throw ConferenceSignalError.invalidPayload }
    }
    /// Записывает значение JSON в соответствующем ему формате.
    /// - Parameter encoder: Кодировщик, в который записываются поля модели.
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): guard item.isFinite else { throw ConferenceSignalError.invalidPayload }; try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

public protocol ConferenceSignalPayload: Decodable, Sendable {
    /// Проверяет допустимость данных сигнального события до его обработки.
    func validate() throws
}

public struct ConferenceEnvelope: Sendable {
    public let id: UUID
    public let type: String
    public let conferenceID: UUID
    public let timestamp: Date
    public let replyTo: UUID?
    public let data: JSONValue

    public var payloadData: Data { get throws { try WireJSON.encoder().encode(data) } }
    /// Декодирует содержимое конверта и проверяет его тип и принадлежность конференции.
    /// - Parameter type: Тип содержимого, ожидаемый при декодировании.
    public func payload<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            let value = try WireJSON.decoder().decode(type, from: payloadData)
            if let checked = value as? any ConferenceSignalPayload { try checked.validate() }
            if let state = value as? ConferenceSignalState,
               state.participants.contains(where: { $0.conferenceId != conferenceID }) { throw ConferenceSignalError.invalidPayload }
            if let media = value as? ConferenceSignalParticipantMedia,
               media.participant.conferenceId != conferenceID { throw ConferenceSignalError.invalidPayload }
            return value
        } catch { throw ConferenceSignalError.invalidPayload }
    }
    /// Возвращает типизированное содержимое конверта после проверки.
    /// - Parameter type: Тип содержимого, ожидаемый при декодировании.
    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T { try payload(type) }

    /// Декодирует входящее сообщение и сверяет заголовок с ожидаемой конференцией.
    /// - Parameters:
    ///   - bytes: Байты входящего сообщения.
    ///   - conferenceID: Идентификатор конференции.
    public static func decode(_ bytes: Data, conferenceID: UUID) throws -> ConferenceEnvelope {
        struct Wire: Decodable {
            let version: Int, id: UUID, type: String, conferenceId: UUID, timestamp: Date, replyTo: UUID?, data: JSONValue
        }
        do {
            guard bytes.count <= ConferenceSocketFraming.inboundLimit, String(data: bytes, encoding: .utf8) != nil else {
                throw ConferenceSignalError.invalidEnvelope
            }
            let wire = try WireJSON.decoder().decode(Wire.self, from: bytes)
            guard wire.version == 1, wire.conferenceId == conferenceID, validIdentifier(wire.id),
                  validIdentifier(conferenceID), wire.replyTo.map(validIdentifier) ?? true,
                  validType(wire.type), wire.timestamp.timeIntervalSince1970.isFinite,
                  wire.timestamp > Date(timeIntervalSince1970: -62_135_596_800) else { throw ConferenceSignalError.invalidEnvelope }
            return ConferenceEnvelope(id: wire.id, type: wire.type, conferenceID: wire.conferenceId,
                timestamp: wire.timestamp, replyTo: wire.replyTo, data: wire.data)
        } catch { throw ConferenceSignalError.invalidEnvelope }
    }

    /// Кодирует сигнальную команду конференции в JSON и записывает UUID заголовка в нижнем регистре.
    ///
    /// Строковые UUID в теле команды вызывающий код также передаёт в нижнем регистре по правилам сервера.
    /// - Parameters:
    ///   - type: Тип сигнальной команды, ожидаемый сервером.
    ///   - conferenceID: Идентификатор конференции.
    ///   - data: Объект полезной нагрузки команды, кодируемый в JSON.
    ///   - id: Уникальный идентификатор отправляемой сигнальной команды.
    ///   - timestamp: Время создания команды.
    public static func command<T: Encodable>(type: String, conferenceID: UUID, data: T,
                                             id: UUID = UUID(), timestamp: Date = Date()) throws -> Data {
        guard validType(type), validIdentifier(conferenceID), validIdentifier(id),
              timestamp.timeIntervalSince1970.isFinite else { throw ConferenceSignalError.invalidEnvelope }
        let payload = try WireJSON.decoder().decode(JSONValue.self, from: WireJSON.encoder().encode(data))
        guard case .object = payload else { throw ConferenceSignalError.invalidPayload }
        let formatter = ISO8601DateFormatter()
        let envelope: JSONValue = .object([
            "version": .integer(1), "id": .string(id.uuidString.lowercased()), "type": .string(type),
            "conferenceId": .string(conferenceID.uuidString.lowercased()),
            "timestamp": .string(formatter.string(from: timestamp)), "data": payload
        ])
        let result = try WireJSON.encoder().encode(envelope)
        _ = try ConferenceSocketFraming.outgoing(result)
        return result
    }
}

private func validIdentifier(_ id: UUID) -> Bool { id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
private func validType(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 100 && value.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-").contains($0)
    }
}
private func require(_ condition: Bool) throws { if !condition { throw ConferenceSignalError.invalidPayload } }

public struct ConferenceSignalParticipant: Decodable, Equatable, Sendable, Identifiable {
    public let id: UUID, conferenceId: UUID
    public let userId: UUID?
    public let displayName: String, role: String, status: String
    public let online: Bool, microphoneEnabled: Bool, cameraEnabled: Bool, screenSharing: Bool
    public let microphoneBlocked: Bool, cameraBlocked: Bool, screenBlocked: Bool
    public let admissionState: String?
    public let connections: Int
    public let connectionIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case id, conferenceId, userId, displayName, role, status, online, microphoneEnabled, cameraEnabled, screenSharing
        case microphoneBlocked, cameraBlocked, screenBlocked, admissionState, connections, connectionIds
    }
    /// Декодирует состояние участника сигнального канала и его подключений.
    /// - Parameter decoder: Декодер, установленный вызывающей стороной для чтения полей модели.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); conferenceId = try c.decode(UUID.self, forKey: .conferenceId)
        userId = try c.decodeIfPresent(UUID.self, forKey: .userId)
        displayName = try c.decode(String.self, forKey: .displayName)
        role = try c.decode(String.self, forKey: .role); status = try c.decode(String.self, forKey: .status)
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        microphoneEnabled = try c.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? false
        cameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .cameraEnabled) ?? false
        screenSharing = try c.decodeIfPresent(Bool.self, forKey: .screenSharing) ?? false
        microphoneBlocked = try c.decodeIfPresent(Bool.self, forKey: .microphoneBlocked) ?? false
        cameraBlocked = try c.decodeIfPresent(Bool.self, forKey: .cameraBlocked) ?? false
        screenBlocked = try c.decodeIfPresent(Bool.self, forKey: .screenBlocked) ?? false
        admissionState = try c.decodeIfPresent(String.self, forKey: .admissionState)
        connections = try c.decodeIfPresent(Int.self, forKey: .connections) ?? 0
        connectionIds = try c.decodeIfPresent([UUID].self, forKey: .connectionIds) ?? []
        try validate()
    }
    /// Проверяет идентификаторы участника, роль, состояние и число подключений.
    public func validate() throws {
        try require(validIdentifier(id) && validIdentifier(conferenceId) && (userId.map(validIdentifier) ?? true))
        try require(displayName.unicodeScalars.count <= 256 && !role.isEmpty && role.utf8.count <= 64 && !status.isEmpty && status.utf8.count <= 64)
        try require(connections >= 0 && connections <= 1000 && connectionIds.count <= 1000 && connectionIds.allSatisfy(validIdentifier))
    }
}
public struct ConferenceSignalState: ConferenceSignalPayload {
    public let connectionId: UUID, participantId: UUID
    public let status: String
    public let participants: [ConferenceSignalParticipant]
    /// Проверяет состояние встречи, уникальность участников и корректность каждой записи.
    public func validate() throws {
        try require(validIdentifier(connectionId) && validIdentifier(participantId) && !status.isEmpty && status.utf8.count <= 64)
        try require(participants.count <= 500 && Set(participants.map(\.id)).count == participants.count)
        for participant in participants { try participant.validate() }
    }
}
public struct ConferenceSignalParticipantMedia: ConferenceSignalPayload {
    public let participant: ConferenceSignalParticipant
    /// Проверяет данные участника в событии обновления медиа.
    public func validate() throws { try participant.validate() }
}
public struct ConferenceSignalPolicy: Codable, Equatable, ConferenceSignalPayload {
    public let version: Int64
    public let microphoneBlocked: Bool, cameraBlocked: Bool, screenBlocked: Bool, kicked: Bool
    /// Проверяет версию полученных ограничений на публикацию медиа.
    public func validate() throws { try require(version >= 0) }
}
public struct ConferenceSignalTrack: Codable, Equatable, Identifiable, ConferenceSignalPayload {
    public let id: UUID, mediaPeerId: UUID, participantId: UUID
    public let streamId: String, kind: String, source: String
    /// Проверяет соответствие источника, типа и идентификаторов опубликованной дорожки.
    public func validate() throws {
        try require(validIdentifier(id) && validIdentifier(mediaPeerId) && validIdentifier(participantId))
        try require(["microphone", "camera", "video/screen", "audio/screen"].contains(source))
        try require(kind == (["microphone", "audio/screen"].contains(source) ? "audio" : "video"))
        try require(streamId == mediaPeerId.uuidString.lowercased() + (source.hasSuffix("/screen") ? "-screen" : ""))
    }
}
public struct ConferenceSignalVideoCapture: Codable, Equatable, ConferenceSignalPayload {
    public let maxWidth: Int, maxHeight: Int, maxFrameRate: Int
    /// Проверяет границы разрешения кадра и частоты кадров камеры.
    public func validate() throws {
        try require((1...7680).contains(maxWidth) && (1...4320).contains(maxHeight) && (1...120).contains(maxFrameRate))
    }
}
public struct ConferenceSignalJoined: ConferenceSignalPayload {
    public let mediaPeerId: UUID
    public let maxPeers: Int
    public let tracks: [ConferenceSignalTrack]
    public let videoCapture: ConferenceSignalVideoCapture
    public let policy: ConferenceSignalPolicy?
    /// The assigned worker can advertise a different TURN pool from the REST discovery endpoint.
    public let iceServers: [ICEServer]?
    /// Проверяет идентификатор медиасоединения, его лимиты, дорожки, ICE и политику публикации.
    public func validate() throws {
        try require(validIdentifier(mediaPeerId) && (1...32).contains(maxPeers))
        try validateTracks(tracks); try videoCapture.validate(); try policy?.validate()
        if let iceServers { _ = try ICEConfiguration(iceServers: iceServers).validated() }
    }
}
public struct ConferenceSignalAnswer: ConferenceSignalPayload {
    public let mediaPeerId: UUID, negotiationId: UUID
    public let sdp: String
    /// Проверяет идентификаторы согласования и размер полученного ответа SDP.
    public func validate() throws {
        try require(validIdentifier(mediaPeerId) && validIdentifier(negotiationId) && !sdp.isEmpty && sdp.utf8.count <= 131_072)
    }
}
public struct ConferenceSignalCandidate: Codable, Equatable, Sendable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int32?
    public let usernameFragment: String?
    /// Описывает ICE-кандидат с привязкой к секции медиапотока.
    /// - Parameters:
    ///   - candidate: Строка ICE-кандидата из WebRTC.
    ///   - sdpMid: Идентификатор медиасекции в описании SDP.
    ///   - sdpMLineIndex: Индекс медиасекции в описании SDP.
    ///   - usernameFragment: Фрагмент имени ICE-пользователя для данного поколения кандидатов.
    public init(candidate: String, sdpMid: String? = nil, sdpMLineIndex: Int32? = nil, usernameFragment: String? = nil) {
        self.candidate = candidate; self.sdpMid = sdpMid; self.sdpMLineIndex = sdpMLineIndex; self.usernameFragment = usernameFragment
    }
    /// Проверяет формат и допустимый размер ICE-кандидата и его полей.
    public func validate() throws {
        try require(candidate.utf8.count <= 4096 && !candidate.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        try require(sdpMid.map { !$0.isEmpty && $0.utf8.count <= 16 } ?? true)
        try require(sdpMLineIndex.map { (0...127).contains($0) } ?? true)
        try require(usernameFragment.map { $0.utf8.count <= 256 } ?? true)
        try require(WireJSON.encoder().encode(self).count <= 4096)
    }
}
public struct ConferenceSignalICE: Codable, ConferenceSignalPayload {
    public let mediaPeerId: UUID
    public let candidate: ConferenceSignalCandidate?
    /// Создаёт событие ICE, включая сигнал об окончании сбора кандидатов.
    /// - Parameters:
    ///   - mediaPeerId: Идентификатор медиасоединения участника.
    ///   - candidate: ICE-кандидат или nil, чтобы отметить конец списка.
    public init(mediaPeerId: UUID, candidate: ConferenceSignalCandidate?) { self.mediaPeerId = mediaPeerId; self.candidate = candidate }
    enum CodingKeys: String, CodingKey { case mediaPeerId, candidate }
    /// Декодирует событие ICE с обязательным полем кандидата, допускающим null.
    /// - Parameter decoder: Декодер, установленный вызывающей стороной для чтения полей модели.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaPeerId = try c.decode(UUID.self, forKey: .mediaPeerId)
        guard c.contains(.candidate) else { throw ConferenceSignalError.invalidPayload }
        candidate = try c.decodeIfPresent(ConferenceSignalCandidate.self, forKey: .candidate)
    }
    /// Кодирует ICE-кандидат или явное завершение списка кандидатов.
    /// - Parameter encoder: Кодировщик, в который записываются поля модели.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mediaPeerId.uuidString.lowercased(), forKey: .mediaPeerId)
        if let candidate { try c.encode(candidate, forKey: .candidate) } else { try c.encodeNil(forKey: .candidate) }
    }
    /// Проверяет идентификатор медиасоединения и данные кандидата, если он передан.
    public func validate() throws { try require(validIdentifier(mediaPeerId)); try candidate?.validate() }
}
public struct ConferenceSignalRenegotiate: ConferenceSignalPayload {
    public let mediaPeerId: UUID
    public let revision: Int64
    /// Проверяет медиасоединение и ревизию запрошенного пересогласования.
    public func validate() throws { try require(validIdentifier(mediaPeerId) && revision >= 0) }
}
public struct ConferenceSignalTracks: ConferenceSignalPayload {
    public let mediaPeerId: UUID
    public let revision: Int64
    public let tracks: [ConferenceSignalTrack]
    /// Проверяет ревизию каталога и список опубликованных дорожек.
    public func validate() throws { try require(validIdentifier(mediaPeerId) && revision >= 0); try validateTracks(tracks) }
}
public struct ConferenceSignalPolicyUpdate: ConferenceSignalPayload {
    public let mediaPeerId: UUID
    public let policy: ConferenceSignalPolicy
    /// Проверяет медиасоединение и обновлённую политику публикации.
    public func validate() throws { try require(validIdentifier(mediaPeerId)); try policy.validate() }
}
public struct ConferenceSignalMediaState: ConferenceSignalPayload {
    public let mediaPeerId: UUID
    public let state: String
    /// Проверяет медиасоединение и строку его текущего состояния.
    public func validate() throws { try require(validIdentifier(mediaPeerId) && !state.isEmpty && state.utf8.count <= 64) }
}
public struct ConferenceSignalAck: ConferenceSignalPayload {
    public let type: String
    /// Проверяет тип подтверждаемой сигнальной команды.
    public func validate() throws { try require(validType(type)) }
}
public struct ConferenceSignalErrorPayload: ConferenceSignalPayload {
    public let code: String
    /// Проверяет формат кода ошибки сигнального протокола.
    public func validate() throws { try require(validType(code)) }
}
public struct ConferenceSignalMediaErrorPayload: ConferenceSignalPayload {
    public let mediaPeerId: UUID
    public let code: String
    /// Проверяет код ошибки и идентификатор медиасоединения, в котором она возникла.
    public func validate() throws { try require(validIdentifier(mediaPeerId) && validType(code)) }
}
private func validateTracks(_ tracks: [ConferenceSignalTrack]) throws {
    try require(tracks.count <= 128 && Set(tracks.map(\.id)).count == tracks.count)
    for track in tracks { try track.validate() }
}

/// Offer/answer/ready is a transaction. Revisions arriving during it are coalesced.
public struct NegotiationGate: Sendable {
    public struct Pending: Equatable, Sendable {
        public let id: UUID, revision: Int64, localRevision: Int64
        public fileprivate(set) var requestID: UUID?, readyID: UUID?
    }
    public private(set) var pending: Pending?
    private var wanted: Int64 = 0, local: Int64 = 0, answered: Int64 = -1, answeredLocal: Int64 = -1
    /// Создаёт начальное состояние согласования без незавершённых транзакций.
    public init() {}
    /// Запоминает наибольшую запрошенную сервером ревизию согласования.
    /// - Parameter revision: Номер ревизии каталога медиа на сервере.
    public mutating func remote(revision: Int64) throws { try require(revision >= 0); wanted = max(wanted, revision) }
    /// Увеличивает локальную ревизию после изменения набора медиа.
    public mutating func changed() throws { try require(local < Int64.max); local += 1 }
    /// Начинает транзакцию согласования, если есть изменения и свободен её слот.
    /// - Parameter id: Идентификатор транзакции согласования.
    public mutating func begin(id: UUID = UUID()) -> Pending? {
        guard pending == nil, wanted > answered || local > answeredLocal, validIdentifier(id) else { return nil }
        pending = Pending(id: id, revision: wanted, localRevision: local)
        return pending
    }
    /// Связывает отправленное предложение SDP с текущей транзакцией.
    /// - Parameter requestID: Уникальный идентификатор отправленного запроса.
    public mutating func sentOffer(requestID: UUID) throws {
        try require(validIdentifier(requestID) && pending != nil && pending?.requestID == nil)
        pending?.requestID = requestID
    }
    /// Запоминает запрос готовности после отправки предложения SDP.
    /// - Parameter requestID: Уникальный идентификатор отправленного запроса.
    public mutating func sentReady(requestID: UUID) throws {
        try require(validIdentifier(requestID) && pending?.requestID != nil && pending?.readyID == nil)
        pending?.readyID = requestID
    }
    /// Завершает транзакцию по подтверждению соответствующего запроса готовности.
    /// - Parameter requestID: Уникальный идентификатор отправленного запроса.
    public mutating func acknowledge(requestID: UUID) -> Bool {
        guard let transaction = pending, transaction.readyID == requestID else { return false }
        answered = transaction.revision; answeredLocal = transaction.localRevision; pending = nil
        return true
    }
    /// Сбрасывает незавершённую транзакцию и запрашивает новое согласование.
    public mutating func rollback() throws { pending = nil; try changed() }
}

public protocol ConferenceSocket: Sendable {
    /// Отправляет сообщение сигнального протокола в сокет конференции.
    /// - Parameter data: Данные исходящего JSON-сообщения.
    func send(_ data: Data) async throws
    /// Возвращает байты следующего входящего сообщения конференции.
    func receive() async throws -> Data
    /// Закрывает сигнальное соединение конференции.
    func close() async
}
public protocol ConferenceSocketFactory: Sendable {
    /// Открывает сигнальное WebSocket-соединение с билетом указанной конференции.
    /// - Parameters:
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    ///   - conferenceID: Идентификатор конференции.
    ///   - ticket: Билет доступа к потоку событий, выданный сервером.
    func connect(origin: ServerOrigin, conferenceID: UUID, ticket: String) async throws -> any ConferenceSocket
}

enum ConferenceSocketFraming {
    static let inboundLimit = 1_048_576, outboundLimit = 65_536
    /// Проверяет размер и JSON-формат исходящей команды и превращает её в текст.
    /// - Parameter bytes: JSON-объект исходящей команды в кодировке UTF-8.
    static func outgoing(_ bytes: Data) throws -> String {
        guard bytes.count <= outboundLimit, let text = String(data: bytes, encoding: .utf8),
              (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else { throw ConferenceSignalError.invalidEnvelope }
        return text
    }
    /// Принимает текстовый кадр и возвращает его байты после проверки размера.
    /// - Parameter message: Полученный текстовый или двоичный кадр URLSession.
    static func incoming(_ message: URLSessionWebSocketTask.Message) throws -> Data {
        guard case .string(let text) = message, text.utf8.count <= inboundLimit else { throw ConferenceSignalError.invalidEnvelope }
        return Data(text.utf8)
    }
    /// Преобразует ошибку сокета в ошибку сигнального канала с признаком возможности повтора.
    /// - Parameters:
    ///   - error: Ошибка сетевой задачи, если она завершилась неуспешно.
    ///   - task: Сетевая задача, для которой получено событие.
    static func failure(_ error: Error, task: URLSessionWebSocketTask) -> Error {
        if error is CancellationError { return CancellationError() }
        if task.closeCode == .policyViolation {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ConferenceSignalError.disconnected(retryable: ["broker_unavailable", "slow_client", "state_unavailable", "authentication_unavailable", "authentication_expired"].contains(reason))
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && (-1206 ... -1200).contains(ns.code) { return ConferenceSignalError.disconnected(retryable: false) }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, [400, 403, 404].contains(status) {
            return ConferenceSignalError.disconnected(retryable: false)
        }
        return ConferenceSignalError.disconnected(retryable: true)
    }
}
final class ConferenceSocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    let opened: AsyncThrowingStream<Void, Error>
    private let continuation: AsyncThrowingStream<Void, Error>.Continuation
    /// Создаёт поток для ожидания результата согласования WebSocket-подпротокола.
    override init() {
        (opened, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
    }
    /// Проверяет выбранный сервером подпротокол и сообщает результат открытия.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - webSocketTask: WebSocket-задача, для которой получено событие.
    ///   - protocol: Имя подпротокола, согласованного с сервером.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard `protocol` == "go-recorder.v1" else {
            continuation.finish(throwing: ConferenceSignalError.unsupportedProtocol)
            webSocketTask.cancel(with: .protocolError, reason: nil); session.invalidateAndCancel(); return
        }
        continuation.yield(()); continuation.finish()
    }
    /// Передаёт закрытие сокета в поток ожидания подключения.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - webSocketTask: WebSocket-задача, для которой получено событие.
    ///   - closeCode: Код закрытия WebSocket, полученный от сетевой сессии.
    ///   - reason: Необязательное тело сообщения о причине закрытия WebSocket.
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        continuation.finish(throwing: ConferenceSocketFraming.failure(ConferenceSignalError.disconnected(retryable: true), task: webSocketTask))
    }
    /// Завершает ожидание подключения с учётом ошибки сетевой задачи.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - task: Сетевая задача, для которой получено событие.
    ///   - error: Ошибка сетевой задачи, если она завершилась неуспешно.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let socket = task as? URLSessionWebSocketTask {
            continuation.finish(throwing: ConferenceSocketFraming.failure(error ?? ConferenceSignalError.disconnected(retryable: true), task: socket))
        } else { continuation.finish(throwing: ConferenceSignalError.disconnected(retryable: true)) }
    }
    /// Запрещает HTTP-перенаправление при подключении к сигнальному каналу.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - task: Сетевая задача, для которой получено событие.
    ///   - response: HTTP-ответ при попытке перенаправления сокета.
    ///   - request: Потенциальный запрос по адресу перенаправления.
    ///   - completionHandler: Обработчик URLSession, которому передаётся решение о перенаправлении.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
private actor ConferenceSessionSocket: ConferenceSocket {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private var closed = false, receiving = false
    /// Привязывает сигнальный сокет к его задаче и сетевой сессии.
    /// - Parameters:
    ///   - task: Сетевая задача, для которой получено событие.
    ///   - session: Сетевая сессия, которой принадлежит задача.
    init(task: URLSessionWebSocketTask, session: URLSession) { self.task = task; self.session = session }
    /// Закрывает сигнальный сокет и сессию при освобождении соединения.
    deinit { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    /// Отправляет сообщение сигнального протокола в сокет конференции.
    /// - Parameter data: Данные исходящего JSON-сообщения.
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !closed else { throw ConferenceSignalError.disconnected(retryable: false) }
        let text = try ConferenceSocketFraming.outgoing(data)
        let task = task, session = session
        do {
            try await withTaskCancellationHandler {
                try await task.send(.string(text)); try Task.checkCancellation()
            } onCancel: { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        }
        catch { if Task.isCancelled { throw CancellationError() }; throw ConferenceSocketFraming.failure(error, task: task) }
    }
    /// Возвращает байты следующего входящего сообщения конференции.
    func receive() async throws -> Data {
        try Task.checkCancellation()
        guard !closed, !receiving else { throw ConferenceSignalError.disconnected(retryable: false) }
        receiving = true; defer { receiving = false }
        let task = task, session = session
        do {
            return try await withTaskCancellationHandler {
                let message = try await task.receive()
                try Task.checkCancellation()
                return try ConferenceSocketFraming.incoming(message)
            } onCancel: { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if error is ConferenceSignalError { throw error }
            throw ConferenceSocketFraming.failure(error, task: task)
        }
    }
    /// Закрывает сигнальное соединение конференции.
    func close() async { closed = true; task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
public struct URLSessionConferenceSocketFactory: ConferenceSocketFactory {
    /// Создаёт фабрику сетевых соединений конференции на основе URLSession.
    public init() {}
    /// Проверяет билет и формирует запрос на открытие сигнального WebSocket.
    /// - Parameters:
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    ///   - conferenceID: Идентификатор конференции.
    ///   - ticket: Билет доступа к потоку событий, выданный сервером.
    public static func request(origin: ServerOrigin, conferenceID: UUID, ticket: String) throws -> URLRequest {
        guard validIdentifier(conferenceID), ticket.utf8.count == 43,
              ticket.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }) else {
            throw ConferenceSignalError.invalidTicket
        }
        let url = try RealtimeEndpoint.url(origin: origin, scope: .conference(conferenceID), ticket: ticket)
        guard url.scheme == "wss", url.user == nil, url.password == nil, url.fragment == nil else { throw ConferenceSignalError.invalidEnvelope }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(origin.url.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("go-recorder.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }
    /// Открывает сигнальное WebSocket-соединение с билетом указанной конференции.
    /// - Parameters:
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    ///   - conferenceID: Идентификатор конференции.
    ///   - ticket: Билет доступа к потоку событий, выданный сервером.
    public func connect(origin: ServerOrigin, conferenceID: UUID, ticket: String) async throws -> any ConferenceSocket {
        try Task.checkCancellation()
        let request = try Self.request(origin: origin, conferenceID: conferenceID, ticket: ticket)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        let delegate = ConferenceSocketDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = ConferenceSocketFraming.inboundLimit
        let socket = ConferenceSessionSocket(task: task, session: session)
        task.resume()
        do {
            return try await withTaskCancellationHandler {
                for try await _ in delegate.opened { try Task.checkCancellation(); return socket }
                throw ConferenceSignalError.disconnected(retryable: true)
            } onCancel: { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        } catch { await socket.close(); throw error }
    }
}
