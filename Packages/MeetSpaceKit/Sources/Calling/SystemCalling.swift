import Foundation

public struct SystemCallDescriptor: Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let isVideo: Bool
    /// Описывает звонок для системного интерфейса вызовов.
    /// - Parameters:
    ///   - id: Идентификатор звонка в CallKit.
    ///   - displayName: Имя собеседника для отображения.
    ///   - isVideo: Признак видеозвонка.
    public init(id: UUID, displayName: String, isVideo: Bool) {
        self.id = id; self.displayName = displayName; self.isVideo = isVideo
    }
}

public struct SystemCallAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case start, answer, end, setMuted(Bool) }
    public let id: UUID
    public let callID: UUID
    public let kind: Kind
    public let deadline: Date
    /// Описывает действие CallKit, ожидающее подтверждения от приложения.
    /// - Parameters:
    ///   - id: Идентификатор действия, используемый при подтверждении.
    ///   - callID: Идентификатор звонка, над которым выполняется действие.
    ///   - kind: Запрос системы, например ответ или завершение звонка.
    ///   - deadline: Крайнее время подтверждения действия.
    public init(id: UUID, callID: UUID, kind: Kind, deadline: Date) {
        self.id = id; self.callID = callID; self.kind = kind; self.deadline = deadline
    }
}

public enum SystemCallEndReason: Equatable, Sendable {
    case failed, remoteEnded, unanswered, answeredElsewhere, declinedElsewhere
}

public enum SystemCallingError: Error, Equatable, Sendable {
    case unavailable, invalidDescriptor, invalidated, requestRejected, incomingRejected
}

public enum SystemCallEvent: Equatable, Sendable {
    case action(SystemCallAction)
    case timedOut(SystemCallAction)
    case reset
    case audioActivationChanged(Bool)
}

/// CallKit actions remain pending until the coordinator completes the matching identifier.
/// Framework action objects and audio sessions never escape the native adapters.
@MainActor public protocol SystemCalling: AnyObject {
    /// Each access creates an independent subscription. Cancelling one account's consumer does
    /// not terminate the process-wide provider or another account's subscription.
    var events: AsyncStream<SystemCallEvent> { get }
    var isAvailable: Bool { get }
    /// Синхронно передаёт входящий звонок системному провайдеру до возврата в PushKit.
    /// - Parameters:
    ///   - descriptor: Идентификатор, имя собеседника и тип звонка.
    ///   - completion: Обработчик результата регистрации звонка в системе.
    func reportIncoming(_ descriptor: SystemCallDescriptor,
                        completion: @escaping @Sendable (Result<Void, SystemCallingError>) -> Void)
    /// Запрашивает начало исходящего системного звонка.
    /// - Parameter descriptor: Идентификатор, имя собеседника и тип исходящего звонка.
    func requestStart(_ descriptor: SystemCallDescriptor) async throws
    /// Запрашивает ответ на входящий звонок.
    /// - Parameter callID: Идентификатор звонка, который нужно принять.
    func requestAnswer(callID: UUID) async throws
    /// Запрашивает завершение звонка через системный интерфейс.
    /// - Parameter callID: Идентификатор завершаемого звонка.
    func requestEnd(callID: UUID) async throws
    /// Запрашивает изменение состояния микрофона звонка.
    /// - Parameters:
    ///   - muted: Значение true отключает микрофон.
    ///   - callID: Идентификатор звонка, в котором меняется состояние.
    func requestMuted(_ muted: Bool, callID: UUID) async throws
    /// Завершает ожидающее действие CallKit с результатом, полученным от приложения.
    /// - Parameters:
    ///   - id: Идентификатор ожидающего действия.
    ///   - succeeded: Удалось ли приложению выполнить запрос системы.
    func completeAction(id: UUID, succeeded: Bool)
    /// Отмечает начало соединения для исходящего звонка.
    /// - Parameters:
    ///   - callID: Идентификатор исходящего звонка.
    ///   - date: Время начала соединения или nil для системного времени по умолчанию.
    func reportConnecting(callID: UUID, at date: Date?)
    /// Отмечает установление соединения исходящего звонка.
    /// - Parameters:
    ///   - callID: Идентификатор исходящего звонка.
    ///   - date: Время подключения или nil для системного времени по умолчанию.
    func reportConnected(callID: UUID, at date: Date?)
    /// Сообщает системе время и причину завершения звонка.
    /// - Parameters:
    ///   - callID: Идентификатор завершённого звонка.
    ///   - reason: Причина, определяющая итоговый статус системного звонка.
    ///   - date: Время завершения или nil для системного времени по умолчанию.
    func reportEnded(callID: UUID, reason: SystemCallEndReason, at date: Date?)
    /// Обновляет сведения о звонке в системном интерфейсе.
    /// - Parameter descriptor: Новое описание звонка с его прежним идентификатором.
    func updateCall(_ descriptor: SystemCallDescriptor)
    /// Прекращает обслуживание звонков этим провайдером.
    func invalidate()
}

public extension SystemCalling {
    /// Передаёт входящий звонок системе и ожидает результата его регистрации.
    /// - Parameter descriptor: Идентификатор, имя собеседника и тип звонка.
    func reportIncoming(_ descriptor: SystemCallDescriptor) async throws {
        try await withCheckedThrowingContinuation { continuation in
            reportIncoming(descriptor) { @Sendable result in continuation.resume(with: result) }
        }
    }
    /// Отмечает начало соединения исходящего звонка с системным временем по умолчанию.
    /// - Parameter callID: Идентификатор исходящего звонка.
    func reportConnecting(callID: UUID) { reportConnecting(callID: callID, at: nil) }
    /// Отмечает установление исходящего звонка с системным временем по умолчанию.
    /// - Parameter callID: Идентификатор подключённого звонка.
    func reportConnected(callID: UUID) { reportConnected(callID: callID, at: nil) }
    /// Регистрирует завершение звонка с системным временем по умолчанию.
    /// - Parameters:
    ///   - callID: Идентификатор завершённого звонка.
    ///   - reason: Причина завершения для системного интерфейса.
    func reportEnded(callID: UUID, reason: SystemCallEndReason) { reportEnded(callID: callID, reason: reason, at: nil) }
}

@MainActor public enum SystemCallingFactory {
    /// Выбирает реализацию системных звонков, доступную на текущей платформе.
    public static func make() -> any SystemCalling {
        #if os(iOS)
        NativeSystemCalling()
        #else
        UnavailableSystemCalling()
        #endif
    }
}

#if !os(iOS)
@MainActor private final class UnavailableSystemCalling: SystemCalling {
    var events: AsyncStream<SystemCallEvent> { AsyncStream { $0.finish() } }
    let isAvailable = false
    /// Возвращает обработчику ошибку недоступности системных звонков на этой платформе.
    /// - Parameters:
    ///   - descriptor: Идентификатор, имя собеседника и тип звонка.
    ///   - completion: Обработчик результата регистрации звонка в системе.
    func reportIncoming(_ descriptor: SystemCallDescriptor, completion: @escaping @Sendable (Result<Void, SystemCallingError>) -> Void) {
        completion(.failure(.unavailable))
    }
    /// Сообщает о недоступности исходящих системных звонков.
    /// - Parameter descriptor: Идентификатор, имя собеседника и тип исходящего звонка.
    func requestStart(_ descriptor: SystemCallDescriptor) async throws { throw SystemCallingError.unavailable }
    /// Сообщает о недоступности системного ответа на звонок.
    /// - Parameter callID: Идентификатор звонка, который нужно принять.
    func requestAnswer(callID: UUID) async throws { throw SystemCallingError.unavailable }
    /// Сообщает о недоступности системного завершения звонка.
    /// - Parameter callID: Идентификатор завершаемого звонка.
    func requestEnd(callID: UUID) async throws { throw SystemCallingError.unavailable }
    /// Сообщает о недоступности системного управления микрофоном.
    /// - Parameters:
    ///   - muted: Значение true отключает микрофон.
    ///   - callID: Идентификатор звонка, в котором меняется состояние.
    func requestMuted(_ muted: Bool, callID: UUID) async throws { throw SystemCallingError.unavailable }
    /// Пропускает подтверждение действия на платформе без CallKit.
    /// - Parameters:
    ///   - id: Идентификатор ожидающего действия.
    ///   - succeeded: Удалось ли приложению выполнить запрос системы.
    func completeAction(id: UUID, succeeded: Bool) { }
    /// Пропускает уведомление о начале соединения на платформе без CallKit.
    /// - Parameters:
    ///   - callID: Идентификатор исходящего звонка.
    ///   - date: Время начала соединения или nil для системного времени по умолчанию.
    func reportConnecting(callID: UUID, at date: Date?) { }
    /// Пропускает уведомление об установленном соединении на платформе без CallKit.
    /// - Parameters:
    ///   - callID: Идентификатор исходящего звонка.
    ///   - date: Время подключения или nil для системного времени по умолчанию.
    func reportConnected(callID: UUID, at date: Date?) { }
    /// Пропускает уведомление о завершении звонка на платформе без CallKit.
    /// - Parameters:
    ///   - callID: Идентификатор завершённого звонка.
    ///   - reason: Причина, определяющая итоговый статус системного звонка.
    ///   - date: Время завершения или nil для системного времени по умолчанию.
    func reportEnded(callID: UUID, reason: SystemCallEndReason, at date: Date?) { }
    /// Пропускает обновление описания звонка на платформе без CallKit.
    /// - Parameter descriptor: Новое описание звонка с его прежним идентификатором.
    func updateCall(_ descriptor: SystemCallDescriptor) { }
    /// Завершает работу адаптера без зарегистрированных системных ресурсов.
    func invalidate() { }
}
#endif
