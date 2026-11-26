#if os(iOS)
import Foundation
import MeetSpaceMedia
@preconcurrency import CallKit
@preconcurrency import AVFoundation

@MainActor final class NativeSystemCalling: NSObject, SystemCalling {
    private let provider: CXProvider
    private let controller = CXCallController(queue: .main)
    private let hub = SystemCallEventHub()
    private var descriptors: [UUID: SystemCallDescriptor] = [:]
    private var outgoing: Set<UUID> = []
    private var pending: [UUID: (action: CXCallAction, value: SystemCallAction)] = [:]
    private var invalidated = false
    var isAvailable: Bool { !invalidated }
    var events: AsyncStream<SystemCallEvent> {
        hub.subscribe(replay: pending.values.sorted { $0.value.deadline < $1.value.deadline }.map { .action($0.value) }
            + [.audioActivationChanged(CallAudioSessionBridge.isActive)])
    }

    /// Создаёт провайдер CallKit для одного звонка и назначает его делегата на главной очереди.
    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        // Generic handles are call UUIDs, not a verified account-scoped redial destination.
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        // An explicit queue also defines reportIncoming's completion queue (nil uses a private one).
        provider.setDelegate(self, queue: .main)
    }

    /// Немедленно сообщает CallKit о входящем звонке и передаёт обработчику результат, учитывая повторные уведомления.
    /// - Parameters:
    ///   - descriptor: Идентификатор, имя собеседника и тип звонка.
    ///   - completion: Обработчик результата регистрации звонка в системе.
    func reportIncoming(_ descriptor: SystemCallDescriptor,
                        completion: @escaping @Sendable (Result<Void, SystemCallingError>) -> Void) {
        guard !invalidated else { completion(.failure(.invalidated)); return }
        guard valid(descriptor) else { completion(.failure(.invalidDescriptor)); return }
        let existed = descriptors[descriptor.id] != nil
        descriptors[descriptor.id] = descriptor
        // This invocation must remain synchronous: no account restore, network call, or actor hop
        // may precede it on the PushKit path. Even duplicate pushes are reported to the system.
        provider.reportNewIncomingCall(with: descriptor.id, update: update(descriptor)) { @Sendable [weak self] error in
            let duplicate = (error as NSError?)?.domain == CXErrorDomainIncomingCall &&
                (error as NSError?)?.code == CXErrorCodeIncomingCallError.callUUIDAlreadyExists.rawValue
            let accepted = error == nil || (existed && duplicate)
            MainActor.assumeIsolated {
                if !accepted { self?.descriptors[descriptor.id] = nil }
            }
            completion(accepted ? .success(()) : .failure(.incomingRejected))
        }
    }

    /// Регистрирует описание исходящего звонка и отправляет транзакцию запуска в CallKit.
    /// - Parameter descriptor: Идентификатор, имя собеседника и тип исходящего звонка.
    func requestStart(_ descriptor: SystemCallDescriptor) async throws {
        guard !invalidated else { throw SystemCallingError.invalidated }
        guard valid(descriptor), descriptors[descriptor.id] == nil else { throw SystemCallingError.invalidDescriptor }
        descriptors[descriptor.id] = descriptor; outgoing.insert(descriptor.id)
        let action = CXStartCallAction(call: descriptor.id, handle: CXHandle(type: .generic, value: descriptor.id.uuidString))
        action.isVideo = descriptor.isVideo
        do {
            try await request(action)
            if !invalidated { provider.reportCall(with: descriptor.id, updated: update(descriptor)) }
        } catch {
            descriptors[descriptor.id] = nil; outgoing.remove(descriptor.id)
            CallAudioSessionBridge.endCall(descriptor.id)
            throw error
        }
    }
    /// Запрашивает ответ на входящий звонок.
    /// - Parameter callID: Идентификатор звонка, который нужно принять.
    func requestAnswer(callID: UUID) async throws { try await request(CXAnswerCallAction(call: callID)) }
    /// Запрашивает завершение звонка через системный интерфейс.
    /// - Parameter callID: Идентификатор завершаемого звонка.
    func requestEnd(callID: UUID) async throws { try await request(CXEndCallAction(call: callID)) }
    /// Запрашивает изменение состояния микрофона звонка.
    /// - Parameters:
    ///   - muted: Значение true отключает микрофон.
    ///   - callID: Идентификатор звонка, в котором меняется состояние.
    func requestMuted(_ muted: Bool, callID: UUID) async throws { try await request(CXSetMutedCallAction(call: callID, muted: muted)) }

    /// Отправляет транзакцию CallKit и ожидает решения системного контроллера.
    /// - Parameter action: Действие над системным звонком.
    private func request(_ action: CXCallAction) async throws {
        guard !invalidated else { throw SystemCallingError.invalidated }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            controller.request(CXTransaction(action: action)) { @Sendable error in
                if error == nil { continuation.resume() }
                else { continuation.resume(throwing: SystemCallingError.requestRejected) }
            }
        }
    }

    /// Завершает ожидающее действие CallKit с результатом, полученным от приложения.
    /// - Parameters:
    ///   - id: Идентификатор ожидающего действия.
    ///   - succeeded: Удалось ли приложению выполнить запрос системы.
    func completeAction(id: UUID, succeeded: Bool) {
        guard let value = pending.removeValue(forKey: id), !value.action.isComplete else { return }
        guard value.value.deadline > Date() else {
            // System timeouts are already failures; never fulfill or fail an expired CXAction.
            hub.yield(.timedOut(value.value)); return
        }
        if succeeded && (value.value.kind == .start || value.value.kind == .answer) {
            do { try CallAudioSessionBridge.prepareForCall(value.value.callID) }
            catch {
                value.action.fail()
                reportEnded(callID: value.value.callID, reason: .failed, at: nil)
                hub.yield(.reset) // Coordinator must also end the corresponding server attempt.
                return
            }
        }
        if succeeded { value.action.fulfill() } else { value.action.fail() }
        if value.value.kind == .end && succeeded {
            descriptors[value.value.callID] = nil; outgoing.remove(value.value.callID)
            CallAudioSessionBridge.endCall(value.value.callID)
        }
    }
    /// Отмечает начало соединения для исходящего звонка.
    /// - Parameters:
    ///   - callID: Идентификатор исходящего звонка.
    ///   - date: Время начала соединения или nil для системного времени по умолчанию.
    func reportConnecting(callID: UUID, at date: Date?) {
        guard !invalidated, outgoing.contains(callID) else { return }
        provider.reportOutgoingCall(with: callID, startedConnectingAt: date)
    }
    /// Отмечает установление соединения исходящего звонка.
    /// - Parameters:
    ///   - callID: Идентификатор исходящего звонка.
    ///   - date: Время подключения или nil для системного времени по умолчанию.
    func reportConnected(callID: UUID, at date: Date?) {
        guard !invalidated, outgoing.contains(callID) else { return }
        provider.reportOutgoingCall(with: callID, connectedAt: date)
    }
    /// Сообщает системе время и причину завершения звонка.
    /// - Parameters:
    ///   - callID: Идентификатор завершённого звонка.
    ///   - reason: Причина, определяющая итоговый статус системного звонка.
    ///   - date: Время завершения или nil для системного времени по умолчанию.
    func reportEnded(callID: UUID, reason: SystemCallEndReason, at date: Date?) {
        guard !invalidated else { return }
        let native: CXCallEndedReason
        switch reason {
        case .failed: native = .failed
        case .remoteEnded: native = .remoteEnded
        case .unanswered: native = .unanswered
        case .answeredElsewhere: native = .answeredElsewhere
        case .declinedElsewhere: native = .declinedElsewhere
        }
        provider.reportCall(with: callID, endedAt: date, reason: native)
        descriptors[callID] = nil; outgoing.remove(callID)
        CallAudioSessionBridge.endCall(callID)
        for id in pending.filter({ $0.value.value.callID == callID }).map(\.key) { completeAction(id: id, succeeded: false) }
    }
    /// Обновляет сведения о звонке в системном интерфейсе.
    /// - Parameter descriptor: Новое описание звонка с его прежним идентификатором.
    func updateCall(_ descriptor: SystemCallDescriptor) {
        guard !invalidated, descriptors[descriptor.id] != nil, valid(descriptor) else { return }
        descriptors[descriptor.id] = descriptor
        provider.reportCall(with: descriptor.id, updated: update(descriptor))
    }
    /// Завершает работу провайдера CallKit и освобождает состояние его звонков и подписок.
    func invalidate() {
        guard !invalidated else { return }; invalidated = true
        for value in pending.values where !value.action.isComplete && value.value.deadline > Date() { value.action.fail() }
        pending.removeAll(); descriptors.removeAll(); outgoing.removeAll()
        CallAudioSessionBridge.reset()
        provider.invalidate(); hub.finish()
    }

    /// Проверяет допустимость отображаемого имени перед регистрацией звонка.
    /// - Parameter descriptor: Описание звонка для регистрации в CallKit.
    private func valid(_ descriptor: SystemCallDescriptor) -> Bool {
        !descriptor.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            descriptor.displayName.utf8.count <= 1024 &&
            !descriptor.displayName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    /// Формирует обновление CallKit с именем, типом звонка и доступными действиями.
    /// - Parameter descriptor: Актуальное описание звонка MeetSpace.
    private func update(_ descriptor: SystemCallDescriptor) -> CXCallUpdate {
        let value = CXCallUpdate()
        value.remoteHandle = CXHandle(type: .generic, value: descriptor.id.uuidString)
        value.localizedCallerName = descriptor.displayName; value.hasVideo = descriptor.isVideo
        value.supportsDTMF = false; value.supportsHolding = false
        value.supportsGrouping = false; value.supportsUngrouping = false
        return value
    }
    /// Сохраняет запрос CallKit до подтверждения приложением и уведомляет подписчиков.
    /// - Parameters:
    ///   - action: Системный объект, который затем нужно подтвердить или отклонить.
    ///   - kind: Соответствующее действие MeetSpace.
    private func receive(_ action: CXCallAction, kind: SystemCallAction.Kind) {
        guard !invalidated, descriptors[action.callUUID] != nil else { action.fail(); return }
        let value = SystemCallAction(id: action.uuid, callID: action.callUUID, kind: kind, deadline: action.timeoutDate)
        pending[action.uuid] = (action, value); hub.yield(.action(value))
    }
}

extension NativeSystemCalling: CXProviderDelegate {
    /// Сбрасывает состояние звонков и аудиосессии, затем уведомляет подписчиков.
    /// - Parameter provider: Провайдер CallKit, сообщивший о сбросе.
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            pending.removeAll(); descriptors.removeAll(); outgoing.removeAll()
            CallAudioSessionBridge.reset(); hub.yield(.audioActivationChanged(false)); hub.yield(.reset)
        }
    }
    /// Передаёт координатору запрос CallKit на исходящий звонок.
    /// - Parameters:
    ///   - provider: Провайдер, делегировавший действие.
    ///   - action: Системный запрос на начало звонка.
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated { receive(action, kind: .start) }
    }
    /// Передаёт координатору запрос CallKit на ответ.
    /// - Parameters:
    ///   - provider: Провайдер, делегировавший действие.
    ///   - action: Системный запрос на ответ на входящий звонок.
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated { receive(action, kind: .answer) }
    }
    /// Передаёт координатору запрос CallKit на завершение звонка.
    /// - Parameters:
    ///   - provider: Провайдер, делегировавший действие.
    ///   - action: Системный запрос на окончание звонка.
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated { receive(action, kind: .end) }
    }
    /// Передаёт координатору запрошенное CallKit состояние микрофона.
    /// - Parameters:
    ///   - provider: Провайдер, делегировавший действие.
    ///   - action: Системный запрос с новым состоянием микрофона.
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated { receive(action, kind: .setMuted(action.isMuted)) }
    }
    /// Отклоняет неподдерживаемый запрос CallKit на удержание звонка.
    /// - Parameters:
    ///   - provider: Провайдер, делегировавший действие.
    ///   - action: Запрос удержания, которому возвращается отказ.
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) { action.fail() }
    /// Отклоняет неподдерживаемый запрос CallKit на группировку звонков.
    /// - Parameters:
    ///   - provider: Провайдер, делегировавший действие.
    ///   - action: Запрос группировки, которому возвращается отказ.
    nonisolated func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) { action.fail() }
    /// Отклоняет неподдерживаемый запрос воспроизведения тонального сигнала DTMF.
    /// - Parameters:
    ///   - provider: Провайдер, делегировавший действие.
    ///   - action: Запрос набора тонов, которому возвращается отказ.
    nonisolated func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) { action.fail() }
    /// Удаляет просроченное действие из ожидающих и сообщает о тайм-ауте.
    /// - Parameters:
    ///   - provider: Провайдер, сообщивший об истечении срока.
    ///   - action: Действие, для которого истекло время подтверждения.
    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        MainActor.assumeIsolated {
            if let value = pending.removeValue(forKey: action.uuid) { hub.yield(.timedOut(value.value)) }
        }
    }
    /// Передаёт активацию аудиосессии в WebRTC и уведомляет подписчиков.
    /// - Parameters:
    ///   - provider: Провайдер, активировавший звук звонка.
    ///   - audioSession: Аудиосессия, активированная CallKit.
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            CallAudioSessionBridge.didActivate(audioSession); hub.yield(.audioActivationChanged(true))
        }
    }
    /// Передаёт деактивацию аудиосессии в WebRTC и уведомляет подписчиков.
    /// - Parameters:
    ///   - provider: Провайдер, отключивший звук звонка.
    ///   - audioSession: Аудиосессия, деактивированная CallKit.
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            CallAudioSessionBridge.didDeactivate(audioSession); hub.yield(.audioActivationChanged(false))
        }
    }
}
#endif
