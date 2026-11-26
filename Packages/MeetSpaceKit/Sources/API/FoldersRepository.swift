import Foundation
import MeetSpaceCore

/// Управляет личными папками аккаунта и ссылками на чаты и встречи в этих папках.
public struct FoldersRepository: Sendable {
    private let client: AuthenticatedClient

    /// Создаёт репозиторий личных папок для одного аккаунта.
    /// - Parameter client: Клиент, который авторизует запросы от имени владельца папок.
    public init(client: AuthenticatedClient) { self.client = client }

    /// Загружает все личные папки текущего аккаунта.
    public func list() async throws -> [PersonalFolder] {
        try await list(query: [])
    }

    /// Загружает все личные папки и для каждой возвращает признак `contains` — входит ли в неё указанный элемент.
    /// - Parameters:
    ///   - kind: Тип элемента — чат или встреча.
    ///   - id: Идентификатор элемента, наличие которого нужно проверить.
    public func list(containing kind: FolderItemKind, item id: UUID) async throws -> [PersonalFolder] {
        let folders = try await list(query: [URLQueryItem(name: "itemKind", value: kind.rawValue),
                                             URLQueryItem(name: "itemId", value: id.uuidString.lowercased())])
        guard folders.allSatisfy({ $0.contains != nil }) else { throw APIError.invalidResponse }
        return folders
    }

    /// Запрашивает список папок и проверяет полученные от сервера данные.
    /// - Parameter query: Параметры запроса списка, например тип и идентификатор элемента для проверки принадлежности.
    private func list(query: [URLQueryItem]) async throws -> [PersonalFolder] {
        try validatedList(decodeJSON(ItemsResponse<PersonalFolder>.self, from: await request("GET", path: ["folders"], query: query)).items)
    }

    /// Создаёт личную папку и возвращает её с присвоенным сервером идентификатором.
    /// - Parameter name: Имя папки длиной от 1 до 50 скалярных значений Unicode
    ///   после удаления пробелов по краям и нормализации NFC.
    public func create(name: String) async throws -> PersonalFolder {
        struct Body: Encodable { let name: String }
        return try validated(decodeJSON(ItemResponse<PersonalFolder>.self, from: await request("POST", path: ["folders"],
            body: WireJSON.encoder().encode(Body(name: FolderValidation.text(name, maximum: 50, required: true))))).item)
    }

    /// Меняет имя папки и возвращает обновлённую папку.
    /// - Parameters:
    ///   - id: Идентификатор переименовываемой папки.
    ///   - name: Новое имя с теми же ограничениями, что и у ``create(name:)``.
    public func rename(_ id: UUID, name: String) async throws -> PersonalFolder {
        struct Body: Encodable { let name: String }
        return try scoped(id, response: await request("PATCH", path: scope(id),
            body: WireJSON.encoder().encode(Body(name: FolderValidation.text(name, maximum: 50, required: true)))))
    }

    /// Удаляет папку вместе с её ссылками. Сами чаты и встречи сохраняются.
    /// - Parameter id: Идентификатор удаляемой папки.
    public func delete(_ id: UUID) async throws { _ = try await request("DELETE", path: scope(id)) }

    /// Сохраняет порядок папок и возвращает их с обновлёнными позициями.
    /// - Parameter ids: Идентификаторы всех текущих папок в желаемом порядке, каждый ровно один раз.
    public func order(_ ids: [UUID]) async throws -> [PersonalFolder] {
        guard ids.count <= 100, Set(ids).count == ids.count else { throw ClientError.invalidInput }
        struct Body: Encodable { let ids: [String] }
        let items = try decodeJSON(ItemsResponse<PersonalFolder>.self, from: await request("PUT", path: ["folders", "order"],
            body: WireJSON.encoder().encode(Body(ids: ids.map { $0.uuidString.lowercased() })))).items
        guard Set(items.map(\.id)) == Set(ids), items.count == ids.count else { throw ClientError.scopeMismatch }
        return try validatedList(items)
    }

    /// Загружает страницу содержимого папки или элементов для выбора.
    /// - Parameters:
    ///   - id: Идентификатор папки, содержимое которой просматривают или редактируют.
    ///   - candidates: При `true` загружает доступные элементы с признаком `inFolder`, при `false` — содержимое папки.
    ///   - filter: Какие типы включить в выборку — чаты, встречи или оба типа.
    ///   - search: Строка поиска. Пустая строка отключает текстовый фильтр.
    ///   - before: Значение `nextCursor` из предыдущего ответа. Для первой страницы передайте `nil`.
    /// - Returns: До 50 элементов и курсор для продолжения, если есть следующая страница.
    public func items(_ id: UUID, candidates: Bool = false, filter: FolderFilter = .all,
                      search: String = "", before: String? = nil) async throws -> PersonalFolderPage {
        let search = try FolderValidation.text(search, maximum: 100, required: false)
        guard before.map({ $0.utf8.count <= 4096 }) ?? true else { throw ClientError.invalidInput }
        var query = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "type", value: filter.rawValue),
                     URLQueryItem(name: "search", value: search)]
        if let before, !before.isEmpty { query.append(URLQueryItem(name: "before", value: before)) }
        if candidates { query.append(URLQueryItem(name: "folderId", value: id.uuidString.lowercased())) }
        let page = try decodeJSON(PersonalFolderPage.self, from: await request("GET",
            path: candidates ? ["folder-items"] : scope(id) + ["items"], query: query))
        guard page.items.count <= 50, Set(page.items.map(\.id)).count == page.items.count,
              page.nextCursor.map({ $0.utf8.count <= 4096 && $0 != before }) ?? true else { throw APIError.invalidResponse }
        return page
    }

    /// Добавляет в папку ссылку на элемент или убирает её и возвращает обновлённую папку.
    /// - Parameters:
    ///   - folder: Идентификатор папки, в которой меняется состав ссылок.
    ///   - kind: Тип элемента — чат или встреча.
    ///   - id: Идентификатор чата или встречи.
    ///   - included: `true`, чтобы добавить ссылку, или `false`, чтобы убрать её.
    public func setItem(_ folder: UUID, kind: FolderItemKind, id: UUID, included: Bool) async throws -> PersonalFolder {
        try scoped(folder, response: await request(included ? "PUT" : "DELETE",
            path: scope(folder) + ["items", kind.rawValue, id.uuidString.lowercased()]))
    }

    /// Выполняет запрос к API папок от имени зарегистрированного пользователя.
    /// - Parameters:
    ///   - method: HTTP-метод запроса.
    ///   - path: Сегменты пути относительно базового URL API.
    ///   - query: Параметры строки запроса.
    ///   - body: Тело запроса в формате JSON, если оно требуется.
    /// - Throws: `ClientError.scopeMismatch`, если клиент принадлежит гостевой сессии.
    private func request(_ method: String, path: [String], query: [URLQueryItem] = [], body: Data? = nil) async throws -> NetworkResponse {
        guard client.account.user.guestConferenceId == nil else { throw ClientError.scopeMismatch }
        return try await client.request(method, path: path, query: query, body: body)
    }

    /// Возвращает папку после проверки её имени, позиции и согласованности счётчиков.
    /// - Parameter folder: Папка из ответа сервера.
    private func validated(_ folder: PersonalFolder) throws -> PersonalFolder {
        guard (0..<100).contains(folder.position), folder.itemCount >= 0, folder.conversationCount >= 0,
              folder.conferenceCount >= 0, folder.itemCount >= folder.conferenceCount,
              folder.itemCount - folder.conferenceCount == folder.conversationCount,
              (try? FolderValidation.text(folder.name, maximum: 50, required: true)) == folder.name else { throw APIError.invalidResponse }
        return folder
    }

    /// Проверяет ограничение в 100 папок, уникальность идентификаторов и данные каждой папки.
    /// - Parameter folders: Список папок из ответа сервера.
    private func validatedList(_ folders: [PersonalFolder]) throws -> [PersonalFolder] {
        guard folders.count <= 100, Set(folders.map(\.id)).count == folders.count else { throw APIError.invalidResponse }
        return try folders.map(validated)
    }

    /// Формирует сегменты пути API для обращения к одной папке.
    /// - Parameter id: Идентификатор папки в пути запроса.
    private func scope(_ id: UUID) -> [String] { ["folders", id.uuidString.lowercased()] }

    /// Извлекает папку из ответа и проверяет её идентификатор и данные.
    /// - Parameters:
    ///   - id: Идентификатор папки, которую сервер должен вернуть.
    ///   - response: Ответ сервера с объектом папки в поле `item`.
    private func scoped(_ id: UUID, response: NetworkResponse) throws -> PersonalFolder {
        let item = try decodeJSON(ItemResponse<PersonalFolder>.self, from: response).item
        guard item.id == id else { throw ClientError.scopeMismatch }; return try validated(item)
    }
}
