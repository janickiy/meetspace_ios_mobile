import Foundation
import MeetSpaceCore

public struct ConferenceRepository: Sendable {
    public let origin: ServerOrigin
    public let userID: UUID
    private let perform: @Sendable (String, [String], [URLQueryItem], Data?) async throws -> NetworkResponse

    /// Создаёт репозиторий конференций для авторизованного аккаунта.
    /// - Parameter client: Клиент, выполняющий запросы от имени текущего аккаунта.
    public init(client: AuthenticatedClient) {
        origin = client.account.server; userID = client.account.user.id
        perform = { method, path, query, body in
            try await client.request(method, path: path, query: query, body: body)
        }
    }
    /// Создаёт репозиторий для доступа гостя к его конференции.
    /// - Parameters:
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    ///   - guest: Гостевая сессия участника конференции.
    ///   - transport: Транспорт для HTTP-запросов к серверу.
    public init(origin: ServerOrigin, guest: GuestConferenceSession, transport: any RequestTransport = URLSessionRequestTransport()) {
        self.origin = origin; userID = guest.user.id
        perform = { method, path, query, body in
            try Task.checkCancellation()
            guard origin == guest.origin else { throw ClientError.scopeMismatch }
            guard guest.expiresAt > Date() else { throw ClientError.sessionExpired }
            let roomPath = ["conferences", guest.conferenceID.uuidString.lowercased()]
            guard path.starts(with: roomPath) || (method == "GET" && path == ["webrtc", "config"])
            else { throw ClientError.scopeMismatch }
            var request = URLRequest(url: try EndpointURL.make(origin, path: path, query: query))
            request.httpMethod = method; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            request.setValue("Bearer \(guest.accessToken)", forHTTPHeaderField: "Authorization")
            let response = try await transport.send(request, limit: 2_097_152, uploadFile: nil, progress: nil)
            try Task.checkCancellation()
            if response.status == 401 { throw ClientError.sessionExpired }
            try requireSuccess(response)
            return response
        }
    }
    /// Загружает страницу доступных конференций.
    /// - Parameters:
    ///   - limit: Максимальное число записей на странице.
    ///   - offset: Число элементов, пропускаемых в начале выборки.
    public func list(limit: Int = 50, offset: Int = 0) async throws -> [Conference] {
        try decodeJSON(ItemsResponse<Conference>.self, from: await perform("GET", ["conferences"], pagination(limit, offset), nil)).items
    }
    /// Создаёт конференцию с заданным расписанием и режимом зала ожидания.
    /// - Parameters:
    ///   - title: Название встречи.
    ///   - waitingRoomEnabled: Признак использования зала ожидания во встрече.
    ///   - scheduledAt: Планируемые дата и время начала встречи.
    ///   - plannedDurationMin: Планируемая длительность встречи в минутах.
    public func create(title: String, waitingRoomEnabled: Bool = false, scheduledAt: Date? = nil, plannedDurationMin: Int? = nil) async throws -> Conference {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(title.unicodeScalars.count), !title.contains("\0"),
              scheduledAt.map({ $0 > Date() }) ?? true,
              plannedDurationMin.map({ (1...1440).contains($0) && scheduledAt != nil }) ?? true else { throw ClientError.invalidInput }
        struct Body: Encodable { let title: String; let waitingRoomEnabled: Bool; let scheduledAt: Date?; let plannedDurationMin: Int? }
        let item = try decodeJSON(ItemResponse<Conference>.self, from: await perform("POST", ["conferences"], [],
            WireJSON.encoder().encode(Body(title: title, waitingRoomEnabled: waitingRoomEnabled, scheduledAt: scheduledAt, plannedDurationMin: plannedDurationMin)))).item
        guard item.ownerId == userID else { throw ClientError.scopeMismatch }
        return item
    }
    /// Загружает карточку конференции по её идентификатору.
    /// - Parameter id: Идентификатор конференции, к которой относится запрос.
    public func read(_ id: UUID) async throws -> Conference {
        try scopedConference(id, response: await perform("GET", scope(id), [], nil))
    }
    /// Ищет пользователей, которых можно пригласить на конференцию.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - query: Строка поиска адресатов приглашения.
    public func invitationUsers(_ id: UUID, query: String) async throws -> [ConferenceInvitationUser] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(query.unicodeScalars.count) else { throw ClientError.invalidInput }
        let response = try await perform("GET", scope(id) + ["invitation-users"], [URLQueryItem(name: "query", value: query)], nil)
        return try decodeJSON(ItemsResponse<ConferenceInvitationUser>.self, from: response).items
    }
    /// Рассылает приглашения и возвращает результат для каждого адресата.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - emails: Адреса электронной почты приглашённых пользователей.
    ///   - userIDs: Идентификаторы пользователей, которых приглашают на встречу.
    public func invite(_ id: UUID, emails: [String], userIDs: [UUID]) async throws -> [ConferenceInvitationResult] {
        guard (1...20).contains(emails.count + userIDs.count) else { throw ClientError.invalidInput }
        struct Body: Encodable { let emails: [String]; let userIds: [UUID] }
        let response = try await perform("POST", scope(id) + ["invitations"], [],
                                         WireJSON.encoder().encode(Body(emails: emails, userIds: userIDs)))
        return try decodeJSON(ItemsResponse<ConferenceInvitationResult>.self, from: response).items
    }
    /// Запрашивает изменение статуса конференции и проверяет принадлежность ответа.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - action: Команда жизненного цикла встречи — start, finish или cancel.
    public func transition(_ id: UUID, action: String) async throws -> Conference {
        guard ["start", "finish", "cancel"].contains(action) else { throw ClientError.invalidInput }
        return try scopedConference(id, response: await perform("POST", scope(id) + [action], [], empty))
    }
    /// Присоединяется к встрече по коду приглашения и возвращает запись участника.
    /// - Parameter code: Код или ссылка приглашения на настроенном сервере.
    public func joinInvite(code: String) async throws -> ConferenceParticipant {
        let code = try ConferenceInviteGateway.inviteCode(from: code, origin: origin)
        let item = try decodeJSON(ItemResponse<ConferenceParticipant>.self, from: await perform("POST", ["conference-invites", code, "join"], [], empty)).item
        guard item.userId == userID else { throw ClientError.scopeMismatch }
        return item
    }
    /// Присоединяется к указанной встрече и возвращает собственную запись участника.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - inviteCode: Код приглашения на встречу.
    public func join(_ id: UUID, inviteCode: String? = nil) async throws -> ConferenceParticipant {
        struct Body: Encodable { let inviteCode: String? }
        let code = try inviteCode.map { try ConferenceInviteGateway.inviteCode(from: $0, origin: origin) }
        return try participant(id, own: true, response: await perform("POST", scope(id) + ["join"], [], WireJSON.encoder().encode(Body(inviteCode: code))))
    }
    /// Выходит из встречи и возвращает обновлённую запись участника.
    /// - Parameter id: Идентификатор конференции, к которой относится запрос.
    public func leave(_ id: UUID) async throws -> ConferenceParticipant {
        try participant(id, own: true, response: await perform("POST", scope(id) + ["leave"], [], empty))
    }
    /// Загружает страницу участников встречи.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - limit: Максимальное число записей на странице.
    ///   - offset: Число элементов, пропускаемых в начале выборки.
    public func participants(_ id: UUID, limit: Int = 100, offset: Int = 0) async throws -> [ConferenceParticipant] {
        let items = try decodeJSON(ItemsResponse<ConferenceParticipant>.self, from: await perform("GET", scope(id) + ["participants"], pagination(limit, offset), nil)).items
        guard items.allSatisfy({ $0.conferenceId == id }) else { throw ClientError.scopeMismatch }
        return items
    }
    /// Возвращает запись текущего пользователя в этой конференции.
    /// - Parameter id: Идентификатор конференции, к которой относится запрос.
    public func selfParticipant(_ id: UUID) async throws -> ConferenceParticipant {
        try participant(id, own: true, response: await perform("GET", scope(id) + ["participants", "me"], [], nil))
    }
    /// Передаёт решение о допуске участника из зала ожидания.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - target: Идентификатор участника, к которому применяется действие.
    ///   - decision: Решение о допуске, admit или reject.
    public func admission(_ id: UUID, participant target: UUID, decision: String) async throws -> ConferenceParticipant {
        guard ["admit", "reject"].contains(decision) else { throw ClientError.invalidInput }
        struct Body: Encodable { let decision: String }
        return try participant(id, target: target, response: await perform("POST", scope(id) + ["participants", sid(target), "admission"], [],
            WireJSON.encoder().encode(Body(decision: decision))))
    }
    /// Применяет действие модератора к выбранному участнику.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - target: Идентификатор участника, к которому применяется действие.
    ///   - request: Проверенная команда модератора с действием и его параметрами.
    public func moderate(_ id: UUID, participant target: UUID, request: ConferenceModeration) async throws -> ConferenceParticipant {
        try participant(id, target: target, response: await perform("POST", scope(id) + ["participants", sid(target), "moderation"], [], WireJSON.encoder().encode(request)))
    }
    /// Публикует состояние микрофона, камеры и демонстрации текущего участника.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - state: Новое состояние локальных источников медиа участника.
    public func updateMedia(_ id: UUID, state: ConferenceMediaState) async throws -> ConferenceParticipant {
        try state.validate()
        return try participant(id, own: true, response: await perform("PUT", scope(id) + ["participants", "me", "media"], [], WireJSON.encoder().encode(state)))
    }
    /// Отправляет реакцию участника во встречу.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - emoji: Символ реакции для отправки во встречу.
    public func reaction(_ id: UUID, emoji: String) async throws {
        guard ["👍", "👏", "❤️", "😂"].contains(emoji) else { throw ClientError.invalidInput }
        struct Body: Encodable { let emoji: String }
        _ = try await perform("POST", scope(id) + ["reactions"], [], WireJSON.encoder().encode(Body(emoji: emoji)))
    }
    /// Получает билет для сигнального WebSocket-соединения конференции.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - clientID: Идентификатор экземпляра клиента на устройстве пользователя.
    public func ticket(_ id: UUID, clientID: UUID) async throws -> WSTicket {
        struct Body: Encodable { let clientId: String }
        let ticket = try decodeJSON(WSTicket.self, from: await perform("POST", scope(id) + ["ws-ticket"], [],
            WireJSON.encoder().encode(Body(clientId: sid(clientID)))))
        guard ticket.expiresAt > Date(), ticket.ticket.utf8.count == 43, SessionCookie.valid(ticket.ticket) else { throw APIError.invalidResponse }
        return ticket
    }
    /// Загружает и проверяет конфигурацию ICE для медиасоединения.
    public func ice() async throws -> ICEConfiguration {
        let result = try decodeJSON(ICEConfiguration.self, from: await perform("GET", ["webrtc", "config"], [], nil))
        return try result.validated()
    }
    /// Загружает страницу сообщений чата конференции с учётом строки поиска.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - before: Курсор предыдущей страницы истории. Для первого запроса передайте nil.
    ///   - search: Строка поиска для отбора результатов.
    public func messages(_ id: UUID, before: String? = nil, search: String? = nil) async throws -> ConferenceMessagePage {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let before, !before.isEmpty {
            guard before.utf8.count <= 2048 else { throw ClientError.invalidInput }
            query.append(URLQueryItem(name: "before", value: before))
        }
        var path = scope(id) + ["messages"]
        if let search, !search.isEmpty {
            let queryText = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...200).contains(queryText.unicodeScalars.count), !queryText.contains("\0") else { throw ClientError.invalidInput }
            path = scope(id) + ["chat", "messages", "search"]
            query.append(URLQueryItem(name: "q", value: queryText))
        }
        let page = try decodeJSON(ConferenceMessagePage.self, from: await perform("GET", path, query, nil))
        guard page.items.allSatisfy({ $0.conferenceId == id }) else { throw ClientError.scopeMismatch }
        return page
    }
    /// Отправляет сообщение в чат конференции и возвращает сохранённую версию.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - draft: Подготовленное сообщение с текстом, вложениями и идентификатором отправки.
    public func send(_ id: UUID, draft: MessageDraft) async throws -> ConferenceMessage {
        try message(id, response: await perform("POST", scope(id) + ["messages"], [], WireJSON.encoder().encode(draft)))
    }
    /// Изменяет текст сообщения чата конференции.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - messageID: Идентификатор сообщения в выбранном чате.
    ///   - text: Текст сообщения.
    public func edit(_ id: UUID, message messageID: UUID, text: String) async throws -> ConferenceMessage {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.count <= 4000, !text.contains("\0") else { throw ClientError.invalidInput }
        struct Body: Encodable { let text: String }
        return try message(id, target: messageID, response: await perform("PATCH", scope(id) + ["messages", sid(messageID)], [], WireJSON.encoder().encode(Body(text: text))))
    }
    /// Удаляет сообщение конференции и возвращает его состояние после удаления.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - messageID: Идентификатор сообщения в выбранном чате.
    public func delete(_ id: UUID, message messageID: UUID) async throws -> ConferenceMessage {
        try message(id, target: messageID, response: await perform("DELETE", scope(id) + ["messages", sid(messageID)], [], nil))
    }
    /// Получает границу прочитанного в чате встречи.
    /// - Parameter id: Идентификатор конференции, к которой относится запрос.
    public func readState(_ id: UUID) async throws -> ReadState {
        try decodeJSON(ItemResponse<ReadState>.self, from: await perform("GET", scope(id) + ["chat", "read"], [], nil)).item
    }
    /// Отмечает сообщения чата встречи прочитанными до указанного сообщения включительно.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - messageID: Идентификатор сообщения в выбранном чате.
    public func markRead(_ id: UUID, through messageID: UUID) async throws -> ReadState {
        struct Body: Encodable { let messageId: String }
        return try decodeJSON(ItemResponse<ReadState>.self, from: await perform("PUT", scope(id) + ["chat", "read"], [], WireJSON.encoder().encode(Body(messageId: sid(messageID))))).item
    }
    private var empty: Data { Data("{}".utf8) }
    /// Преобразует UUID в строку нижнего регистра для API.
    /// - Parameter id: Идентификатор сущности для включения в путь или тело запроса.
    private func sid(_ id: UUID) -> String { id.uuidString.lowercased() }
    /// Формирует сегменты пути API для выбранной конференции.
    /// - Parameter id: Идентификатор конференции, к которой относится запрос.
    private func scope(_ id: UUID) -> [String] { ["conferences", sid(id)] }
    /// Проверяет границы страницы и формирует параметры пагинации.
    /// - Parameters:
    ///   - limit: Максимальное число записей на странице.
    ///   - offset: Число элементов, пропускаемых в начале выборки.
    private func pagination(_ limit: Int, _ offset: Int) throws -> [URLQueryItem] {
        guard (1...100).contains(limit), (0...1_000_000).contains(offset) else { throw ClientError.invalidInput }
        return [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
    }
    /// Извлекает встречу из ответа и сверяет её идентификатор с запросом.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - response: Ответ сервера, из которого извлекаются запрошенные данные.
    private func scopedConference(_ id: UUID, response: NetworkResponse) throws -> Conference {
        let item = try decodeJSON(ItemResponse<Conference>.self, from: response).item
        guard item.id == id else { throw ClientError.scopeMismatch }; return item
    }
    /// Проверяет принадлежность полученной записи участника встрече и запрошенному пользователю.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - own: Признак того, что запись должна принадлежать текущему пользователю.
    ///   - target: Идентификатор участника, к которому применяется действие.
    ///   - response: Ответ сервера, из которого извлекаются запрошенные данные.
    private func participant(_ id: UUID, own: Bool = false, target: UUID? = nil, response: NetworkResponse) throws -> ConferenceParticipant {
        let item = try decodeJSON(ItemResponse<ConferenceParticipant>.self, from: response).item
        guard item.conferenceId == id, !own || item.userId == userID, target == nil || target == item.id else { throw ClientError.scopeMismatch }
        return item
    }
    /// Проверяет принадлежность сообщения встрече и его соответствие запрошенному сообщению.
    /// - Parameters:
    ///   - id: Идентификатор конференции, к которой относится запрос.
    ///   - target: Ожидаемый идентификатор сообщения, если ответ относится к конкретному сообщению.
    ///   - response: Ответ сервера, из которого извлекаются запрошенные данные.
    private func message(_ id: UUID, target: UUID? = nil, response: NetworkResponse) throws -> ConferenceMessage {
        let item = try decodeJSON(ItemResponse<ConferenceMessage>.self, from: response).item
        guard item.conferenceId == id, target == nil || target == item.id else { throw ClientError.scopeMismatch }; return item
    }
}

public struct ConferenceInviteGateway: Sendable {
    public let origin: ServerOrigin
    private let transport: any RequestTransport
    /// Создаёт клиент публичных приглашений для выбранного сервера.
    /// - Parameters:
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    ///   - transport: Транспорт для HTTP-запросов к серверу.
    public init(origin: ServerOrigin, transport: any RequestTransport = URLSessionRequestTransport()) {
        self.origin = origin; self.transport = transport
    }
    /// Строит ссылку для приглашения на открытую встречу.
    ///
    /// Принимает код приглашения, полную ссылку на том же сервере или относительный путь к приглашению в API.
    /// - Parameters:
    ///   - meeting: Встреча, данные которой используются для операции.
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    public static func shareURL(for meeting: Conference, origin: ServerOrigin) -> URL? {
        guard !meeting.isClosed else { return nil }
        for candidate in [meeting.inviteCode, meeting.inviteUrl] where !candidate.isEmpty {
            let input = candidate.hasPrefix("/") ? origin.url.absoluteString + candidate : candidate
            if let code = try? inviteCode(from: input, origin: origin) {
                return origin.url.appendingPathComponent("i").appendingPathComponent(code)
            }
        }
        return nil
    }
    /// Возвращает код приглашения из самого кода или полной ссылки на настроенном сервере.
    /// - Parameters:
    ///   - input: Код приглашения или полная ссылка на него.
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    public static func inviteCode(from input: String, origin: ServerOrigin) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if validCode(value) { return value }
        guard !value.contains("%"), !value.contains("\\"),
              let parts = URLComponents(string: value), parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw ClientError.invalidInput }
        var base = parts; base.path = ""
        guard let url = base.url, (try? ServerOrigin(url.absoluteString)) == origin else { throw ClientError.scopeMismatch }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let code: String
        if segments.count == 2, segments[0] == "i" { code = segments[1] }
        else if segments.count == 4, Array(segments.prefix(3)) == ["api", "v1", "conference-invites"] { code = segments[3] }
        else { throw ClientError.invalidInput }
        guard validCode(code), parts.path == "/" + segments.joined(separator: "/") || parts.path == "/" + segments.joined(separator: "/") + "/" else { throw ClientError.invalidInput }
        return code
    }
    /// Получает публичные сведения о встрече по коду приглашения.
    /// - Parameter code: Код или ссылка приглашения на настроенном сервере.
    public func lookup(code: String) async throws -> ConferenceInvite {
        let code = try Self.inviteCode(from: code, origin: origin)
        let response = try await send("GET", path: ["conference-invites", code])
        return try decodeJSON(ItemResponse<ConferenceInvite>.self, from: response).item
    }
    /// Подключает гостя по приглашению или использует переданную гостевую сессию для той же встречи.
    /// - Parameters:
    ///   - code: Код или ссылка приглашения на настроенном сервере.
    ///   - displayName: Имя пользователя, отображаемое другим участникам.
    ///   - resume: Действующая сессия гостя для повторного входа в ту же встречу.
    public func guestJoin(code: String, displayName: String, resume: GuestConferenceSession? = nil) async throws -> GuestConferenceSession {
        let code = try Self.inviteCode(from: code, origin: origin)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(name.unicodeScalars.count), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw ClientError.invalidInput }
        if let resume {
            guard resume.origin == origin else { throw ClientError.scopeMismatch }
            guard resume.expiresAt > Date() else { throw ClientError.sessionExpired }
        }
        let invite = try await lookup(code: code)
        if let resume, resume.conferenceID != invite.id { throw ClientError.scopeMismatch }
        struct Body: Encodable { let displayName: String }
        struct Response: Decodable { let accessToken: String; let tokenType: String; let expiresIn: Int; let user: AccountUser; let item: ConferenceParticipant }
        let response = try decodeJSON(Response.self, from: await send("POST", path: ["conference-invites", code, "guest"],
            body: WireJSON.encoder().encode(Body(displayName: name)), bearer: resume?.accessToken))
        guard response.tokenType.lowercased() == "bearer", (1...10_800).contains(response.expiresIn),
              response.item.conferenceId == invite.id, resume == nil || resume?.user.id == response.user.id else { throw APIError.invalidResponse }
        return try GuestConferenceSession(origin: origin, accessToken: response.accessToken,
            expiresAt: Date().addingTimeInterval(Double(response.expiresIn)), user: response.user, participant: response.item)
    }
    /// Проверяет длину кода приглашения и разрешённый набор символов.
    /// - Parameter code: Код приглашения на конференцию.
    private static func validCode(_ code: String) -> Bool {
        code.utf8.count == 32 && code.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    /// Отправляет запрос к API приглашений с необязательной гостевой авторизацией.
    /// - Parameters:
    ///   - method: Метод HTTP-запроса.
    ///   - path: Сегменты пути относительно корня API.
    ///   - body: Данные, отправляемые в теле запроса.
    ///   - bearer: Токен для заголовка Authorization, если требуется авторизация.
    private func send(_ method: String, path: [String], body: Data? = nil, bearer: String? = nil) async throws -> NetworkResponse {
        var request = URLRequest(url: try EndpointURL.make(origin, path: path)); request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let response = try await transport.send(request, limit: 131_072, uploadFile: nil, progress: nil)
        try requireSuccess(response); return response
    }
}
