import Foundation

/// Audio checks must never take the audio session away from an active conference/call.
@MainActor public enum AudioSessionUse {
    private static var conferenceOwners = Set<UUID>()
    private static var systemCallOwners = Set<UUID>()
    public private(set) static var systemAudioActive = false
    private static var stopProbe: (() -> Void)?
    private static var probeOwner: UUID?
    public static var conferenceActive: Bool { !conferenceOwners.isEmpty || !systemCallOwners.isEmpty || systemAudioActive }
    public static func beginConference(_ owner: UUID) {
        stopCurrentProbe()
        conferenceOwners.insert(owner)
    }
    public static func endConference(_ owner: UUID) { conferenceOwners.remove(owner) }
    /// CallKit prepares audio before its media engine exists (for example while ringing).
    public static func beginSystemCall(_ callID: UUID) {
        stopCurrentProbe()
        systemCallOwners.insert(callID)
    }
    public static func endSystemCall(_ callID: UUID) { systemCallOwners.remove(callID) }
    /// Activation can outlive the end action, or arrive before a media engine is configured.
    public static func setSystemAudioActive(_ active: Bool) {
        systemAudioActive = active
        if active { stopCurrentProbe() }
    }
    public static func resetSystemCalls() {
        systemCallOwners.removeAll(); systemAudioActive = false
    }
    public static func beginProbe(owner: UUID, stop: @escaping () -> Void) -> Bool {
        guard !conferenceActive else { return false }
        stopProbe?(); stopProbe = stop; probeOwner = owner
        return true
    }
    public static func endProbe(owner: UUID) {
        if probeOwner == owner { stopProbe = nil; probeOwner = nil }
    }
    private static func stopCurrentProbe() {
        let stop = stopProbe
        stopProbe = nil; probeOwner = nil
        stop?()
    }
}
