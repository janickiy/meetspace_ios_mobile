import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceCalling

/// Serializes identity mutations. Every active workspace is a fresh, immutable account scope.
@MainActor @Observable public final class IdentityModel {
    public private(set) var index = AccountIndex()
    public private(set) var messaging: MessagingModel?
    public private(set) var conferences: ConferenceWorkspace?
    public private(set) var calls: DirectCallCoordinator?
    public let notifications: PushRegistrationModel
    public private(set) var busy = false
    public var addingAccount = false
    public var error: String?
    public var information: String?
    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private let systemCalling: any SystemCalling
    @ObservationIgnored private var sessionEvents: Task<Void, Never>?
    @ObservationIgnored private var epoch = UUID()

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        systemCalling = dependencies.calling()
        notifications = PushRegistrationModel(platform: dependencies.notifications(), store: dependencies.pushStore)
    }

    public func restore() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            index = try await dependencies.accounts.load().validated()
            guard let account = index.accounts.first(where: { $0.id == index.activeID }) else { return }
            try await activateStored(account, allowOffline: true)
        } catch { self.error = userMessage(error) }
    }

    public func register(server: ServerOrigin?, email: String, password: String, confirmation: String, name: String) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil; information = nil; defer { busy = false }
        do {
            guard let server, password == confirmation else { throw ClientError.invalidInput }
            _ = try await AuthenticationGateway(origin: server, transport: dependencies.transport())
                .register(email: email, password: password, name: name)
            information = "Аккаунт создан. Войдите с новым паролем."
            return true
        } catch { self.error = userMessage(error); return false }
    }

    public func login(server: ServerOrigin?, email: String, password: String) async {
        guard !busy else { return }
        busy = true; error = nil; information = nil; defer { busy = false }
        do {
            guard let server else { throw ClientError.invalidInput }
            let normalized = try AccountValidation.email(email)
            let existing = index.accounts.first { $0.server == server && $0.user.email.lowercased() == normalized }
            guard existing != nil || index.accounts.filter({ $0.server == server }).count < 5 else { throw ClientError.accountLimit }
            var cookie: String?
            if let existing, let saved = try await dependencies.credentials.read(existing.key) {
                cookie = try WireJSON.decoder().decode(SessionCredentials.self, from: saved).validated().sessionCookie
            }
            let signed = try await AuthenticationGateway(origin: server, transport: dependencies.transport())
                .login(email: normalized, password: password, previousCookie: cookie)
            var next = index; try next.upsert(signed.account)
            try await dependencies.credentials.write(WireJSON.encoder().encode(signed.credentials), for: signed.account.key)
            do { try await dependencies.accounts.save(next) }
            catch {
                // A newly created session that cannot be indexed must not remain orphaned locally.
                if existing == nil { try? await dependencies.credentials.delete(signed.account.key) }
                throw error
            }
            index = next
            await install(client(signed.account, credentials: signed.credentials))
        } catch { self.error = userMessage(error) }
    }

    public func switchAccount(_ account: AccountRecord) async {
        guard !busy, index.accounts.contains(where: { $0.id == account.id }) else { return }
        busy = true; error = nil; defer { busy = false }
        do { try await activateStored(account, allowOffline: true) }
        catch { self.error = userMessage(error) }
    }

    public func logout(_ account: AccountRecord) async {
        guard !busy else { return }
        busy = true; error = nil; information = nil; defer { busy = false }
        do {
            let active = messaging?.account.id == account.id
            let target: AuthenticatedClient?
            var pushRemoved = true
            if active {
                epoch = UUID(); sessionEvents?.cancel(); sessionEvents = nil
                target = messaging?.client
                notifications.suspendDelivery()
                await calls?.close(); calls = nil
                await conferences?.close(); conferences = nil
                pushRemoved = await notifications.detach()
                await messaging?.close(); messaging = nil
            } else if let data = try await dependencies.credentials.read(account.key) {
                target = client(account, credentials: try WireJSON.decoder().decode(SessionCredentials.self, from: data).validated())
            } else { target = nil }
            if !active, let target { pushRemoved = await notifications.cleanup(repository: NotificationDeviceRepository(client: target)) }
            let revoked = try await target?.close(logout: true) ?? false
            try await dependencies.credentials.delete(account.key)
            try await AccountFileStore(account: account).clear()
            var next = index; next.remove(account.id)
            try await dependencies.accounts.save(next); index = next
            if !revoked { information = "Аккаунт удалён с устройства. Завершение сессии на сервере не подтверждено." }
            if !pushRemoved {
                information = "Аккаунт удалён с устройства. Удаление push-привязки на сервере не подтверждено; новые регистрации заблокированы до повторного входа и очистки."
            }
        } catch { self.error = userMessage(error) }
    }

    private func activateStored(_ account: AccountRecord, allowOffline: Bool) async throws {
        guard let data = try await dependencies.credentials.read(account.key) else { throw ClientError.missingSession }
        let saved = try WireJSON.decoder().decode(SessionCredentials.self, from: data).validated()
        let candidate = client(account, credentials: saved)
        do {
            var updated = account
            do { updated.user = try await candidate.currentUser() }
            catch APIError.offline where allowOffline { }
            catch APIError.timeout where allowOffline { }
            var next = index; try next.upsert(updated)
            try await dependencies.accounts.save(next); index = next
            await install(candidate)
        } catch {
            _ = try? await candidate.close()
            if error is ClientError, [ClientError.sessionExpired, .accountMismatch].contains(error as? ClientError ?? .storage) {
                try await dependencies.credentials.delete(account.key)
                var next = index; next.remove(account.id)
                try await dependencies.accounts.save(next); index = next
            }
            throw error
        }
    }

    private func client(_ account: AccountRecord, credentials: SessionCredentials) -> AuthenticatedClient {
        AuthenticatedClient(account: account, credentials: credentials, secureStore: dependencies.credentials,
                            transport: dependencies.transport())
    }

    private func install(_ client: AuthenticatedClient) async {
        epoch = UUID(); let current = epoch
        sessionEvents?.cancel()
        if let previous = messaging {
            notifications.suspendDelivery()
            await calls?.close(); calls = nil
            await conferences?.close(); conferences = nil
            _ = await notifications.detach()
            await previous.close()
            _ = try? await previous.client.close()
        }
        let workspace = MessagingModel(client: client, downloads: dependencies.transport(), sockets: dependencies.sockets)
        messaging = workspace; addingAccount = false
        conferences = ConferenceWorkspace(repository: ConferenceRepository(client: client),
            sockets: dependencies.conferenceSockets, makeMedia: dependencies.media, makeBroadcast: dependencies.broadcast,
            canUseMedia: { [weak self] in self?.calls?.isActive != true && self?.calls?.busy != true })
        let calls = DirectCallCoordinator(repository: DirectCallsRepository(client: client),
            conferenceRepository: ConferenceRepository(client: client), system: systemCalling,
            sockets: dependencies.conferenceSockets, makeMedia: dependencies.media, makeBroadcast: dependencies.broadcast,
            canUseMedia: { [weak self] in self?.conferences?.call == nil && self?.conferences?.busy != true })
        self.calls = calls
        workspace.onCallUpdate = { [weak calls] call in Task { await calls?.receive(call) } }
        workspace.onRealtimeConnected = { [weak calls] in Task { await calls?.reconcile() } }
        _ = await notifications.attach(repository: NotificationDeviceRepository(client: client))
        sessionEvents = Task { [weak self] in
            for await _ in client.events {
                guard let self else { return }
                // Identity mutations may themselves trigger the expiry event; let them finish first.
                while self.busy && self.epoch == current && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled, self.epoch == current else { return }
                self.busy = true
                self.notifications.suspendDelivery()
                await self.calls?.close(); self.calls = nil
                await self.conferences?.close(); self.conferences = nil
                _ = await self.notifications.detach()
                await workspace.close(); _ = try? await client.close()
                self.messaging = nil; self.addingAccount = false
                do {
                    try await self.dependencies.credentials.delete(client.account.key)
                    var next = self.index; next.remove(client.account.id)
                    try await self.dependencies.accounts.save(next); self.index = next
                    self.error = "Сессия завершена. Войдите снова."
                } catch { self.error = userMessage(error) }
                self.busy = false
            }
        }
        workspace.start()
    }
}

/// Server payloads and transport descriptions may contain private URLs. Only curated errors reach UI.
public func userMessage(_ error: any Error) -> String {
    switch error {
    case ClientError.accountLimit: "На этом сервере уже сохранено 5 аккаунтов."
    case ClientError.missingSession, ClientError.sessionExpired, ClientError.accountMismatch: "Сессия завершена. Войдите снова."
    case ClientError.invalidInput: "Проверьте введённые данные и ограничения полей."
    case ClientError.invalidFileName: "Недопустимое имя файла."
    case ClientError.unsupportedFile: "Этот тип файла не поддерживается сервером."
    case ClientError.fileTooLarge: "Размер файла должен быть от 1 байта до 10 МБ."
    case APIError.httpStatus(400), APIError.httpStatus(422): "Сервер отклонил данные. Проверьте поля."
    case APIError.httpStatus(401): "Не удалось войти. Проверьте почту и пароль."
    case APIError.httpStatus(403): "Недостаточно прав для этой операции."
    case APIError.httpStatus(404): "Объект недоступен или уже удалён."
    case APIError.httpStatus(409): "Данные уже существуют или были изменены. Обновите экран."
    case APIError.httpStatus(413): "Размер файла превышает лимит сервера."
    case APIError.httpStatus(429): "Слишком много запросов. Повторите немного позже."
    case APIError.offline, APIError.timeout: "Нет связи с сервером. Повторите попытку."
    case APIError.tls: "Не удалось проверить защищённое соединение."
    case is CancellationError: "Операция отменена."
    default: "Операция не выполнена. Повторите попытку."
    }
}
