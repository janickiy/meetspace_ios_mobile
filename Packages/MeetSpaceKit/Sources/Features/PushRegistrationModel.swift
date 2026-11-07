import Foundation
import Observation
import CryptoKit
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceStorage
import MeetSpaceCalling

/// Opaque, single-generation permission to restore this installation's prior intent.
struct AccountDeletionPushPause: Sendable {
    fileprivate let origin: ServerOrigin
    fileprivate let userID: UUID
    fileprivate let epoch: UUID
    fileprivate let enabledIntent: Bool
}

/// One process-wide owner of ordinary APNs registration. Server mutations and journal writes
/// are serialized; detach drains them before the caller closes account credentials.
@MainActor @Observable public final class PushRegistrationModel {
    public private(set) var enabled = false
    public private(set) var busy = false
    public private(set) var status = "Уведомления выключены"
    public private(set) var error: String?
    @ObservationIgnored private let platform: any NormalPushNotifications
    @ObservationIgnored private let store: any PushRegistrationStore
    @ObservationIgnored private var repository: (any NotificationDevicesServing)?
    @ObservationIgnored private var journal = PushRegistrationJournal()
    @ObservationIgnored private var confirmedDeletions: [PushAccountDeletionConfirmation] = []
    @ObservationIgnored private var pendingDeletionConfirmations: [PushAccountDeletionConfirmation] = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var acceptingToken: (epoch: UUID, cleanupOnly: Bool)?
    @ObservationIgnored private var latestToken: Data?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var queued = 0

    public init(platform: any NormalPushNotifications, store: any PushRegistrationStore) {
        self.platform = platform; self.store = store
        eventsTask = Task { [weak self, events = platform.events] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }
    deinit { eventsTask?.cancel() }

    /// Stop OS delivery synchronously before unrelated awaited call/media cleanup. This does
    /// not confirm server revocation: the owner must still await detach before closing credentials.
    public func suspendDelivery() { invalidate(); enabled = false }

    /// Stop new callbacks and finish this client's queued writes while its credentials
    /// are still valid. Failed cleanup remains journaled; it must not prevent the
    /// authoritative account DELETE or be mistaken for a successful device revoke.
    func prepareAccountDeletion(origin: ServerOrigin, userID: UUID) async -> AccountDeletionPushPause? {
        guard !confirmedDeletions.contains(where: { $0.origin == origin && $0.userID == userID }) else { return nil }
        guard repository.map({ $0.origin == origin && $0.userID == userID }) ?? true else { return nil }
        var intent = enabled
        invalidate(); enabled = false; let generation = epoch
        let drained = await serial { [self] in
            guard generation == epoch,
                  repository.map({ $0.origin == origin && $0.userID == userID }) ?? true else { return false }
            do {
                try await load()
                intent = journal.entries.first { $0.origin == origin && $0.userID == userID }?.enabled ?? false
                if let repository { _ = await clean(repository) }
            } catch { failedStorage() }
            return generation == epoch && (repository.map({ $0.origin == origin && $0.userID == userID }) ?? true)
        }
        guard drained else { return nil }
        return AccountDeletionPushPause(origin: origin, userID: userID, epoch: generation, enabledIntent: intent)
    }

    /// Rejection or an unknown DELETE outcome does not change the user's push intent.
    /// A new account, explicit disable, or other generation change invalidates the token.
    @discardableResult func restoreAccountDeletionPause(_ pause: AccountDeletionPushPause) async -> Bool {
        guard pause.epoch == epoch, let target = repository,
              target.origin == pause.origin, target.userID == pause.userID,
              !deletionConfirmed(target) else { return false }
        return await serial { [self] in
            guard pause.epoch == epoch, repository.map({ same($0, target) }) == true else { return false }
            guard pause.enabledIntent else { enabled = false; return true }
            do {
                try await load()
                guard await clean(target), !hasBindings else { blocked(); return false }
                guard pause.epoch == epoch, repository.map({ same($0, target) }) == true else { return false }
                return await resume(target, generation: pause.epoch, askPermission: false)
            } catch { failedStorage(); return false }
        }
    }

    /// Only after DELETE /auth/me success: the server atomically removed this account's
    /// push devices known to that transaction. The caller must drain this client's writes
    /// before DELETE; this cannot fence concurrent writes from another client or server
    /// requests whose response was lost. Persist exact-scope proof before pruning the journal.
    /// If every proof write fails, memory retains it for a later retry; process death before
    /// any durable write cannot be recovered by inferring deletion from a subsequent 401.
    @discardableResult public func accountDeletionConfirmed(origin: ServerOrigin, userID: UUID) async -> Bool {
        remember(PushAccountDeletionConfirmation(origin: origin, userID: userID), pending: true)
        return await serial { [self] in
            do {
                try await load()
                if !hasBindings { status = "Уведомления выключены"; error = nil }
                return true
            } catch { failedStorage(); return false }
        }
    }

    /// Identity checks this before restoring credentials/offline state. This deliberately
    /// reads only the confirmation store, not an unrelated cleanup journal or network 401.
    public func isAccountDeletionConfirmed(origin: ServerOrigin, userID: UUID) async throws -> Bool {
        let scope = PushAccountDeletionConfirmation(origin: origin, userID: userID)
        if confirmedDeletions.contains(scope) { return true }
        let saved = try await store.loadDeletionConfirmations()
        _ = try PushRegistrationJournal(confirmedDeletions: saved).validated()
        for confirmation in saved { remember(confirmation) }
        return confirmedDeletions.contains(scope)
    }

    /// Call on foreground entry to notice permission changes made in iOS Settings. This never
    /// prompts or registers: revocation uses the same immediate stop and scoped cleanup path.
    public func refreshAuthorization() async {
        let generation = epoch
        await platform.refreshAuthorization()
        guard generation == epoch else { return }
        // Read the result directly as well as consuming native events, so UI state is updated
        // before returning even if the AsyncStream consumer has not resumed yet.
        receive(.authorization(platform.authorization))
    }

    /// Attach only after calling detach on the previous account while its client is still open.
    /// The defensive cleanup here also handles callers that replace a scope directly.
    @discardableResult public func attach(repository next: any NotificationDevicesServing) async -> Bool {
        invalidate(); let generation = epoch
        return await serial { [self] in
            do {
                try await load()
                guard !deletionConfirmed(next) else { deletedAccount(); return false }
                if let previous = repository, !same(previous, next) { _ = await clean(previous) }
                guard generation == epoch else { return false }
                repository = next; enabled = entry(next).enabled; error = nil
                let cleanCurrent = await clean(next)
                guard generation == epoch else { return false }
                if !cleanCurrent || hasBindings {
                    blocked()
                    // A fresh OS callback may recover this account's unknown registration only.
                    if entry(next).pendingTokenFingerprint != nil { await requestRecoveryToken(next, generation: generation) }
                    return false
                }
                if enabled { return await resume(next, generation: generation, askPermission: false) }
                status = "Уведомления выключены"; return true
            } catch { failedStorage(); return false }
        }
    }

    /// Stops OS registration immediately, then drains in-flight registrations and scoped revokes.
    /// False means the global journal still requires cleanup; local logout may continue.
    @discardableResult public func detach() async -> Bool {
        invalidate(); enabled = false
        return await serial { [self] in
            do {
                try await load()
                let result = if let repository { await clean(repository) } else { !hasBindings }
                self.repository = nil
                if result && !hasBindings { status = "Уведомления выключены"; error = nil }
                else { blocked() }
                return result && !hasBindings
            } catch { failedStorage(); self.repository = nil; return false }
        }
    }

    /// Allows the application to clean a nonactive account using that account's own credentials.
    @discardableResult public func cleanup(repository target: any NotificationDevicesServing) async -> Bool {
        if let repository, same(repository, target) { invalidate(); enabled = false }
        return await serial { [self] in
            do {
                try await load()
                let result = await clean(target)
                if !result { blocked() }
                else if !hasBindings { error = nil; status = "Привязки этого приложения удалены" }
                return result
            } catch { failedStorage(); return false }
        }
    }

    public func enable() async {
        guard let repository else { error = "Войдите в аккаунт"; return }
        let generation = epoch
        _ = await serial { [self] in
            do {
                try await load()
                guard generation == epoch else { return false }
                guard await clean(repository), !hasBindings else { blocked(); return false }
                return await resume(repository, generation: generation, askPermission: true)
            } catch { failedStorage(); return false }
        }
    }

    public func disable() async {
        invalidate(); enabled = false
        guard let repository else { return }
        _ = await serial { [self] in
            do {
                try await load()
                var value = entry(repository); value.enabled = false; try await save(value)
                let result = await clean(repository)
                if result { error = nil; status = "Уведомления выключены" } else { blocked() }
                // Backend preferences are shared by every account device; do not disable those
                // devices when the user disables this installation's registration.
                return result
            } catch { failedStorage(); return false }
        }
    }

    public func retryCleanup() async {
        invalidate(); enabled = false; let generation = epoch
        _ = await serial { [self] in
            do {
                try await load()
                guard let repository else {
                    if hasBindings { blocked(); return false }
                    error = nil; status = "Привязки этого приложения удалены"; return true
                }
                if await clean(repository), !hasBindings {
                    error = nil; status = "Привязки этого приложения удалены"; return true
                }
                blocked()
                if entry(repository).pendingTokenFingerprint != nil { await requestRecoveryToken(repository, generation: generation) }
                return false
            } catch { failedStorage(); return false }
        }
    }

    private func resume(_ target: any NotificationDevicesServing, generation: UUID, askPermission: Bool) async -> Bool {
        guard generation == epoch, !deletionConfirmed(target) else { return false }
        do {
            guard try await target.capabilities().push == "http" else {
                error = "На сервере не настроен внешний push-шлюз"; status = "Push недоступен"; enabled = false; return false
            }
            guard generation == epoch else { return false }
            let authorization: NormalPushAuthorization
            if askPermission { authorization = try await platform.requestAuthorization() }
            else { await platform.refreshAuthorization(); authorization = platform.authorization }
            guard generation == epoch else { return false }
            guard allowed(authorization) else {
                enabled = false; error = "Разрешите уведомления в настройках iOS"; status = "Нет разрешения на уведомления"; return false
            }
            if askPermission {
                var preferences = try await target.preferences()
                guard generation == epoch else { return false }
                if !preferences.push { preferences.push = true; _ = try await target.savePreferences(preferences) }
                guard generation == epoch else { return false }
                var value = entry(target); value.enabled = true; try await save(value)
            }
            guard generation == epoch else { return false }
            enabled = true; error = nil; status = "Ожидание токена APNs"
            acceptingToken = (generation, false); platform.register(); return true
        } catch {
            if generation == epoch { enabled = false; self.error = "Не удалось включить уведомления. Повторите попытку" }
            return false
        }
    }

    private func receive(_ event: NormalPushNotificationEvent) {
        guard let mode = acceptingToken, mode.epoch == epoch, let target = repository else { return }
        switch event {
        case .token(let token):
            guard !token.isEmpty, token.count <= 4096 else { return }
            latestToken = token
            Task { [weak self] in
                guard let self else { return }
                _ = await self.serial { [self] in
                    guard mode.epoch == epoch else { return false }
                    if mode.cleanupOnly {
                        let result = await clean(target)
                        if result && !hasBindings {
                            invalidate(); enabled = false; error = nil; status = "Привязки этого приложения удалены"
                        } else { blocked() }
                        return result
                    }
                    return await register(token, target: target, generation: mode.epoch)
                }
            }
        case .authorization(let authorization):
            if !allowed(authorization) {
                invalidate(); enabled = false
                Task { [weak self] in await self?.cleanup(repository: target) }
            }
        case .failure:
            error = "iOS не выдала токен APNs. Повторите попытку"; status = "Регистрация не завершена"
        }
    }

    private func register(_ token: Data, target: any NotificationDevicesServing, generation: UUID) async -> Bool {
        guard generation == epoch, !deletionConfirmed(target) else { return false }
        do { try await load() } catch { failedStorage(); return false }
        guard generation == epoch, !deletionConfirmed(target) else { return false }
        let fingerprint = Self.tokenDigest(token)
        let existing = entry(target)
        if existing.pendingTokenFingerprint == nil, existing.registeredTokenFingerprint == fingerprint,
           !existing.deviceIDs.isEmpty, !journal.entries.contains(where: { !matches($0, target) && $0.hasBinding }) { return true }
        guard await clean(target), !hasBindings else { blocked(); return false }
        guard generation == epoch, enabled else { return false }
        do {
            var pending = entry(target); pending.pendingTokenFingerprint = fingerprint
            try await save(pending) // Must succeed before sending the token to the backend.
            guard generation == epoch, enabled, !deletionConfirmed(target) else { return false }
            let device = try await target.register(token: Self.hex(token))
            guard await saveReceipt(device.id, fingerprint: fingerprint, target: target) else { return false }
            if generation != epoch || !enabled { return await clean(target) }
            error = nil; status = "Токен сохранён сервером; доставка APNs требует настройки шлюза"
            return true
        } catch { blocked(); return false }
    }

    private func clean(_ target: any NotificationDevicesServing) async -> Bool {
        // A confirmed deletion is local replay work, never a reason to POST an old token
        // in order to recover its device ID. load() must durably prune it first.
        guard !deletionConfirmed(target) else { return !entry(target).hasBinding }
        do {
            // Never list/revoke arbitrary account devices; only receipts from this installation.
            for id in entry(target).deviceIDs {
                do { try await target.revoke(id) }
                catch APIError.httpStatus(404) { /* Already absent is confirmed cleanup. */ }
                var value = entry(target); value.deviceIDs.removeAll { $0 == id }
                if value.deviceIDs.isEmpty { value.registeredTokenFingerprint = nil }
                try await save(value)
            }
            if let fingerprint = entry(target).pendingTokenFingerprint {
                guard let latestToken, Self.tokenDigest(latestToken) == fingerprint else { return false }
                // Device identity includes the provider mode. Never recover a previous HTTP
                // registration under a changed mock/noop mode and silently lose the old receipt.
                guard try await target.capabilities().push == "http" else { return false }
                guard !deletionConfirmed(target) else { return false }
                // Same user/provider/token yields the same server ID. This recovers an unknown
                // response; a rotated token must never be substituted for the lost one.
                let recovered = try await target.register(token: Self.hex(latestToken))
                guard await saveReceipt(recovered.id, fingerprint: fingerprint, target: target) else { return false }
                do { try await target.revoke(recovered.id) }
                catch APIError.httpStatus(404) { }
                var value = entry(target); value.deviceIDs.removeAll { $0 == recovered.id }; value.registeredTokenFingerprint = nil
                try await save(value)
            }
            return !entry(target).hasBinding
        } catch { return false }
    }

    private func saveReceipt(_ id: UUID, fingerprint: String, target: any NotificationDevicesServing) async -> Bool {
        guard !deletionConfirmed(target) else {
            // Defensive handling of a caller that failed to drain before DELETE. Never
            // recreate a deleted journal scope from this stale registration callback.
            try? await target.revoke(id); return false
        }
        do {
            var value = entry(target)
            if !value.deviceIDs.contains(id) { value.deviceIDs.append(id) }
            value.pendingTokenFingerprint = nil; value.registeredTokenFingerprint = fingerprint
            try await save(value); return true
        } catch {
            // The pre-POST journal remains durable. Best-effort revoke reduces exposure; a
            // failed journal write still blocks future registrations until recovery is confirmed.
            try? await target.revoke(id); failedStorage(); return false
        }
    }

    private func requestRecoveryToken(_ target: any NotificationDevicesServing, generation: UUID) async {
        await platform.refreshAuthorization()
        guard generation == epoch, allowed(platform.authorization),
              repository.map({ same($0, target) }) == true, !deletionConfirmed(target) else { return }
        acceptingToken = (generation, true); platform.register()
    }
    private func invalidate() { epoch = UUID(); acceptingToken = nil; platform.unregister() }
    private func allowed(_ value: NormalPushAuthorization) -> Bool { [.authorized, .provisional, .ephemeral].contains(value) }
    private var hasBindings: Bool { journal.entries.contains(where: \.hasBinding) }
    private func same(_ lhs: any NotificationDevicesServing, _ rhs: any NotificationDevicesServing) -> Bool {
        lhs.origin == rhs.origin && lhs.userID == rhs.userID
    }
    private func matches(_ value: PushRegistrationEntry, _ target: any NotificationDevicesServing) -> Bool {
        value.origin == target.origin && value.userID == target.userID
    }
    private func entry(_ target: any NotificationDevicesServing) -> PushRegistrationEntry {
        journal.entries.first(where: { matches($0, target) }) ?? PushRegistrationEntry(origin: target.origin, userID: target.userID)
    }
    private func deletionConfirmed(_ target: any NotificationDevicesServing) -> Bool {
        confirmedDeletions.contains { $0.origin == target.origin && $0.userID == target.userID }
    }
    private func remember(_ confirmation: PushAccountDeletionConfirmation, pending: Bool = false) {
        if !confirmedDeletions.contains(confirmation) { confirmedDeletions.append(confirmation) }
        if pending && !pendingDeletionConfirmations.contains(confirmation) { pendingDeletionConfirmations.append(confirmation) }
        if repository.map({ $0.origin == confirmation.origin && $0.userID == confirmation.userID }) == true {
            invalidate(); enabled = false; repository = nil
        }
    }
    private func persistConfirmation(_ confirmation: PushAccountDeletionConfirmation) async throws {
        // One immediate retry covers a transient single write failure. Later explicit
        // cleanup/attach/load calls retry again; there is no unbounded background loop.
        do { try await store.recordDeletionConfirmation(confirmation) }
        catch { try await store.recordDeletionConfirmation(confirmation) }
        pendingDeletionConfirmations.removeAll { $0 == confirmation }
    }
    private func load() async throws {
        // Replay even when loaded is true and no account is attached. Proof is persisted
        // before reading/pruning the journal so its storage failure cannot erase DELETE200.
        // Do not let an unrelated/read-once ledger query failure prevent the first proof write.
        for confirmation in pendingDeletionConfirmations { try await persistConfirmation(confirmation) }
        var saved = try await store.loadDeletionConfirmations()
        _ = try PushRegistrationJournal(confirmedDeletions: saved).validated()
        for confirmation in saved { remember(confirmation) }
        for confirmation in confirmedDeletions where !saved.contains(confirmation) {
            try await persistConfirmation(confirmation); saved.append(confirmation)
        }
        if !loaded { journal = try await store.load().validated(); loaded = true }
        for confirmation in journal.confirmedDeletions where !confirmedDeletions.contains(confirmation) {
            remember(confirmation, pending: true)
            try await persistConfirmation(confirmation)
            saved.append(confirmation)
        }
        // A different confirmation may arrive while a store operation is suspended.
        // Its queued operation will persist it; do not prune or register ahead of that proof.
        guard confirmedDeletions.allSatisfy(saved.contains) else { throw ClientError.storage }
        var next = journal
        next.confirmedDeletions = confirmedDeletions
        next.entries.removeAll { entry in
            confirmedDeletions.contains { $0.origin == entry.origin && $0.userID == entry.userID }
        }
        if next != journal { try await store.save(next.validated()); journal = next }
    }
    private func save(_ value: PushRegistrationEntry) async throws {
        guard !confirmedDeletions.contains(where: { $0.origin == value.origin && $0.userID == value.userID }) else {
            throw ClientError.scopeMismatch
        }
        var next = journal
        // Keep only the already-durable ledger snapshot here. A confirmation remembered
        // during this operation is persisted by its queued replay before any scope is pruned.
        if let index = next.entries.firstIndex(where: { $0.origin == value.origin && $0.userID == value.userID }) { next.entries[index] = value }
        else { next.entries.append(value) }
        try await store.save(next); journal = next
    }
    private func serial(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        queued += 1; busy = true
        defer { queued -= 1; busy = queued > 0 }
        let previous = tail
        let work = Task { @MainActor in await previous?.value; return await operation() }
        tail = Task { _ = await work.value }
        return await work.value
    }
    private func blocked() {
        error = "Не удалось подтвердить удаление прежней push-привязки. Войдите в прежний аккаунт на том же сервере и повторите очистку"
        status = "Новая регистрация заблокирована до очистки"
    }
    private func failedStorage() { error = "Не удалось сохранить журнал push-привязок. Регистрация приостановлена"; status = "Журнал недоступен" }
    private func deletedAccount() { enabled = false; error = "Этот аккаунт удалён на сервере"; status = "Уведомления выключены" }
    private static func tokenDigest(_ token: Data) -> String { SHA256.hash(data: Data(hex(token).utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }
}
