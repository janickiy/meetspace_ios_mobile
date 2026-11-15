#if os(iOS)
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import WebRTC

/// CallKit owns activation for direct calls. This bridge records activation even when it arrives
/// before peer creation; a subsequently configured call engine can then open its audio unit.
@MainActor public enum CallAudioSessionBridge {
    public private(set) static var isActive = false
    private static var owners: Set<UUID> = []

    /// Outgoing CallKit actions can finish while the callee is still ringing, before a media
    /// engine exists. Prepare the category before fulfilling; activation remains owned by iOS.
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

    public static func endCall(_ callID: UUID) { AudioSessionUse.endSystemCall(callID) }

    public static func didActivate(_ session: AVAudioSession) {
        AudioSessionUse.setSystemAudioActive(true)
        isActive = true
        let audio = RTCAudioSession.sharedInstance()
        audio.audioSessionDidActivate(session)
        if !owners.isEmpty { audio.isAudioEnabled = true }
    }

    public static func didDeactivate(_ session: AVAudioSession) {
        isActive = false
        let audio = RTCAudioSession.sharedInstance()
        if !owners.isEmpty { audio.isAudioEnabled = false }
        audio.audioSessionDidDeactivate(session)
        AudioSessionUse.setSystemAudioActive(false)
    }

    /// A reset prevents further hardware audio until the system explicitly activates it again.
    public static func reset() {
        isActive = false
        if !owners.isEmpty { RTCAudioSession.sharedInstance().isAudioEnabled = false }
        AudioSessionUse.resetSystemCalls()
    }

    static func acquire(_ owner: UUID) {
        owners.insert(owner)
        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = isActive
    }

    static func release(_ owner: UUID) {
        guard owners.remove(owner) != nil else { return }
        if owners.isEmpty { RTCAudioSession.sharedInstance().isAudioEnabled = false }
    }
}
#endif
