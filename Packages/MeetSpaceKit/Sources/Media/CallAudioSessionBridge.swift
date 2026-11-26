#if os(iOS)
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import WebRTC

/// CallKit owns activation for direct calls. This bridge records activation even when it arrives
/// before peer creation; a subsequently configured call engine can then open its audio unit.
@MainActor public enum CallAudioSessionBridge {
    public private(set) static var isActive = false
    private static var owners: Set<UUID> = []

    /// Настраивает режим голосового чата до подтверждения действия CallKit. Активацией звука управляет iOS, даже если ещё идёт вызов.
    /// - Parameter callID: Идентификатор звонка, для которого резервируется аудиосессия.
    public static func prepareForCall(_ callID: UUID) throws {
        AudioSessionUse.beginSystemCall(callID)
        guard owners.isEmpty else { return } // An existing call engine already configured its route.
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration(); defer { audio.unlockForConfiguration() }
        audio.useManualAudio = true; audio.isAudioEnabled = false
        do {
            try audio.setCategory(AVAudioSession.Category.playAndRecord, mode: AVAudioSession.Mode.voiceChat,
                                  options: [.allowBluetooth, .defaultToSpeaker])
        } catch {
            AudioSessionUse.endSystemCall(callID)
            throw ConferenceMediaError.audioSession
        }
    }

    /// Освобождает резерв аудиосессии, созданный при подготовке звонка.
    /// - Parameter callID: Идентификатор завершённого системного звонка.
    public static func endCall(_ callID: UUID) { AudioSessionUse.endSystemCall(callID) }

    /// Сообщает WebRTC об активации аудиосессии и разрешает звук зарегистрированным медиадвижкам.
    /// - Parameter session: Аудиосессия, активированная CallKit.
    public static func didActivate(_ session: AVAudioSession) {
        AudioSessionUse.setSystemAudioActive(true)
        isActive = true
        let audio = RTCAudioSession.sharedInstance()
        audio.audioSessionDidActivate(session)
        if !owners.isEmpty { audio.isAudioEnabled = true }
    }

    /// Отключает звук медиадвижков звонка и передаёт деактивацию в WebRTC.
    /// - Parameter session: Аудиосессия, которую деактивировал CallKit.
    public static func didDeactivate(_ session: AVAudioSession) {
        isActive = false
        let audio = RTCAudioSession.sharedInstance()
        if !owners.isEmpty { audio.isAudioEnabled = false }
        audio.audioSessionDidDeactivate(session)
        AudioSessionUse.setSystemAudioActive(false)
    }

    /// Сбрасывает резервы звонков и останавливает их аппаратный звук до следующей активации системой.
    public static func reset() {
        isActive = false
        if !owners.isEmpty { RTCAudioSession.sharedInstance().isAudioEnabled = false }
        AudioSessionUse.resetSystemCalls()
    }

    /// Подключает медиадвижок к ручному управлению аудио и учитывает текущую активацию CallKit.
    /// - Parameter owner: Идентификатор медиадвижка звонка.
    static func acquire(_ owner: UUID) {
        owners.insert(owner)
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = isActive
    }

    /// Удаляет владельца и отключает аудио WebRTC, когда завершился последний звонок.
    /// - Parameter owner: Идентификатор освобождаемого медиадвижка.
    static func release(_ owner: UUID) {
        guard owners.remove(owner) != nil else { return }
        if owners.isEmpty { RTCAudioSession.sharedInstance().isAudioEnabled = false }
    }
}
#endif
