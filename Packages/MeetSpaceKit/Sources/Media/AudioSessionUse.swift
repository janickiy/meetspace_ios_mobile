import Foundation

/// Audio checks must never take the audio session away from an active conference/call.
@MainActor public enum AudioSessionUse {
    private static var conferenceOwners = Set<UUID>()
    private static var systemCallOwners = Set<UUID>()
    public private(set) static var systemAudioActive = false
    private static var stopProbe: (() -> Void)?
    private static var probeOwner: UUID?
    public static var idle: Bool { !conferenceActive && probeOwner == nil }
    public static var conferenceActive: Bool { !conferenceOwners.isEmpty || !systemCallOwners.isEmpty || systemAudioActive }
    /// Резервирует аудиосессию для конференции и останавливает текущую проверку звука.
    /// - Parameter owner: Идентификатор владельца аудиосессии конференции.
    public static func beginConference(_ owner: UUID) {
        stopCurrentProbe()
        conferenceOwners.insert(owner)
    }
    /// Снимает отметку использования аудио завершившейся конференцией.
    /// - Parameter owner: Идентификатор, зарегистрированный этой конференцией при старте.
    public static func endConference(_ owner: UUID) { conferenceOwners.remove(owner) }
    /// Резервирует аудио для звонка CallKit ещё на этапе вызова и останавливает текущую проверку звука.
    /// - Parameter callID: Идентификатор системного звонка.
    public static func beginSystemCall(_ callID: UUID) {
        stopCurrentProbe()
        systemCallOwners.insert(callID)
    }
    /// Освобождает резерв аудиосессии для завершившегося системного звонка.
    /// - Parameter callID: Идентификатор завершившегося звонка CallKit.
    public static func endSystemCall(_ callID: UUID) { systemCallOwners.remove(callID) }
    /// Сохраняет факт системной активации аудио отдельно от жизненного цикла медиадвижка. При активации останавливает проверку звука.
    /// - Parameter active: Активировала ли система аудиосессию звонка.
    public static func setSystemAudioActive(_ active: Bool) {
        systemAudioActive = active
        if active { stopCurrentProbe() }
    }
    /// Удаляет резервы системных звонков и сбрасывает признак активации аудио.
    public static func resetSystemCalls() {
        systemCallOwners.removeAll(); systemAudioActive = false
    }
    /// Резервирует свободную от звонков аудиосессию для проверки звука и возвращает результат.
    /// - Parameters:
    ///   - owner: Идентификатор новой проверки.
    ///   - stop: Обработчик остановки проверки при следующей проверке или начале звонка.
    public static func beginProbe(owner: UUID, stop: @escaping () -> Void) -> Bool {
        guard !conferenceActive else { return false }
        stopProbe?(); stopProbe = stop; probeOwner = owner
        return true
    }
    /// Снимает резерв, если проверку завершает её текущий владелец.
    /// - Parameter owner: Идентификатор завершаемой проверки.
    public static func endProbe(owner: UUID) {
        if probeOwner == owner { stopProbe = nil; probeOwner = nil }
    }
    /// Освобождает резерв текущей проверки звука и вызывает её обработчик остановки.
    private static func stopCurrentProbe() {
        let stop = stopProbe
        stopProbe = nil; probeOwner = nil
        stop?()
    }
}
