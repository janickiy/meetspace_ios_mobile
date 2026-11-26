import Foundation

/// Upload response bodies need a data delegate: URLSession's async upload API buffers
/// the complete response before returning. All mutable state is protected by `lock`.
final class BoundedUpload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let progress: TransferProgress?
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionUploadTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    private var response: URLResponse?
    private var responseLimit = 0
    private var buffer = Data()
    private var finished = false

    /// Настраивает предел размера успешного ответа и обработчик прогресса отправки.
    /// - Parameters:
    ///   - limit: Предельный размер успешного ответа в байтах.
    ///   - progress: Обработчик доли переданных данных от 0 до 1.
    init(limit: Int, progress: TransferProgress?) { self.limit = limit; self.progress = progress }

    /// Отправляет файл и возвращает накопленное тело ответа вместе с его заголовками.
    /// - Parameters:
    ///   - request: Исходный HTTP-запрос для передачи.
    ///   - file: Локальный адрес подготовленного файла для отправки.
    ///   - configuration: Конфигурация сетевой сессии.
    func run(request: URLRequest, file: URL, configuration: URLSessionConfiguration) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.uploadTask(with: request, fromFile: file)
                let start = lock.withLock {
                    guard !finished else { return false }
                    self.session = session; self.task = task; self.continuation = continuation
                    return true
                }
                if start { task.resume() }
                else { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: { self.cancel() }
    }

    /// Отменяет отправку и завершает ожидающую задачу с ошибкой отмены.
    func cancel() { finish(.failure(CancellationError())) }

    /// Проверяет статус и объявленный размер ответа перед чтением тела.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - dataTask: Задача передачи данных, получившая ответ сервера.
    ///   - response: Ответ сервера, из которого извлекаются запрошенные данные.
    ///   - completionHandler: Обработчик, которому передаётся разрешение или запрет на чтение ответа.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(APIError.invalidResponse)); completionHandler(.cancel); return
        }
        guard !(300...399).contains(http.statusCode) else {
            finish(.failure(APIError.redirect)); completionHandler(.cancel); return
        }
        // Preserve small JSON 401/403 errors even when the success response limit is tiny.
        let cap = (200...299).contains(http.statusCode) ? limit : 65_536
        guard response.expectedContentLength <= Int64(cap) else {
            finish(.failure(APIError.responseTooLarge)); completionHandler(.cancel); return
        }
        let accept = lock.withLock {
            guard !finished else { return false }
            self.response = response; responseLimit = cap
            return true
        }
        completionHandler(accept ? .allow : .cancel)
    }

    /// Добавляет очередную порцию ответа в буфер, завершая отправку при превышении лимита.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - dataTask: Задача передачи данных, получившая ответ сервера.
    ///   - data: Очередная часть тела ответа сервера.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock {
            guard !finished else { return false }
            guard data.count <= responseLimit - buffer.count else { return true }
            buffer.append(data); return false
        }
        if oversized { finish(.failure(APIError.responseTooLarge)) }
    }

    /// Завершает отправку с накопленным ответом или ошибкой URLSession.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - task: Сетевая задача, для которой получено событие.
    ///   - error: Ошибка сетевой задачи, если она завершилась неуспешно.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result: Result<(Data, URLResponse), any Error> = lock.withLock {
            if let error { return .failure(error) }
            guard let response else { return .failure(APIError.invalidResponse) }
            return .success((buffer, response))
        }
        finish(result)
    }

    /// Отклоняет перенаправление и завершает отправку с ошибкой.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - task: Сетевая задача, для которой получено событие.
    ///   - response: HTTP-ответ с указанием перенаправления.
    ///   - request: Новый запрос, предложенный URLSession для перенаправления.
    ///   - completionHandler: Обработчик URLSession, которому передаётся решение о перенаправлении.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(APIError.redirect))
    }

    /// Передаёт обработчику долю отправленных байтов, когда полный размер известен.
    /// - Parameters:
    ///   - session: Сетевая сессия, которой принадлежит задача.
    ///   - task: Сетевая задача, для которой получено событие.
    ///   - bytesSent: Число байтов, отправленных с предыдущего уведомления о прогрессе.
    ///   - totalBytesSent: Суммарное число уже отправленных байтов.
    ///   - totalBytesExpectedToSend: Ожидаемый полный размер тела запроса в байтах.
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0, !lock.withLock({ finished }) {
            progress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }

    /// Освобождает сетевые ресурсы и однократно передаёт результат ожидающей задаче.
    /// - Parameter result: Полученный ответ с телом или ошибка передачи.
    private func finish(_ result: Result<(Data, URLResponse), any Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse), any Error>?, URLSession?) in
            guard !finished else { return (nil, nil) }
            finished = true
            let pending = (continuation, session)
            continuation = nil; session = nil; task = nil; response = nil; buffer = Data()
            return pending
        }
        pending.1?.invalidateAndCancel()
        pending.0?.resume(with: result)
    }
}

/// Separate upload sessions use the same ephemeral configuration and participate in
/// account cancellation. The registry owns no credentials or response data.
final class BoundedUploadRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var uploads: [ObjectIdentifier: BoundedUpload] = [:]
    /// Регистрирует активную отправку для последующей отмены вместе с аккаунтом.
    /// - Parameter upload: Активная отправка, которая учитывается в реестре.
    func insert(_ upload: BoundedUpload) { lock.withLock { uploads[ObjectIdentifier(upload)] = upload } }
    /// Снимает завершённую отправку с учёта.
    /// - Parameter upload: Активная отправка, которая учитывается в реестре.
    func remove(_ upload: BoundedUpload) { lock.withLock { _ = uploads.removeValue(forKey: ObjectIdentifier(upload)) } }
    /// Отменяет все отправки, зарегистрированные на момент вызова.
    func cancelAll() {
        let active = lock.withLock { Array(uploads.values) }
        for upload in active { upload.cancel() }
    }
}
