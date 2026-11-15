import Foundation
import Testing
import MeetSpaceMedia
@testable import MeetSpaceFeatures

@MainActor @Test func audioChecksCannotStealAnActiveConferenceSession() {
    let first = UUID(), second = UUID(), conference = UUID()
    var stopped = 0
    #expect(AudioSessionUse.beginProbe(owner: first) { stopped += 1 })
    #expect(AudioSessionUse.beginProbe(owner: second) { stopped += 10 })
    #expect(stopped == 1)
    AudioSessionUse.endProbe(owner: first) // A disappearing older view must not unregister the current probe.
    AudioSessionUse.beginConference(conference)
    #expect(stopped == 11)
    #expect(!AudioSessionUse.beginProbe(owner: first) {})
    AudioSessionUse.endConference(conference)
    #expect(AudioSessionUse.beginProbe(owner: first) {})
    AudioSessionUse.endProbe(owner: first)
}

@MainActor @Test func audioChecksUseFiniteMeterAndBoundedInMemoryTone() {
    #expect(AudioSettingsModel.normalizedLevel(-Float.infinity) == 0)
    #expect(AudioSettingsModel.normalizedLevel(.nan) == 0)
    #expect(AudioSettingsModel.normalizedLevel(-20) == 0.1)
    #expect(AudioSettingsModel.normalizedLevel(10) == 1)
    let speaker = AudioSettingsModel.testTone(signals: false)
    let signals = AudioSettingsModel.testTone(signals: true)
    #expect(speaker.count == 48044)
    #expect(String(data: speaker.prefix(4), encoding: .utf8) == "RIFF")
    #expect(String(data: speaker[8..<12], encoding: .utf8) == "WAVE")
    #expect(signals.count == speaker.count)
    #expect(signals != speaker)
}

@MainActor @Test func audioChecksWaitForPreparedCallAndSystemDeactivation() {
    let probe = UUID(), call = UUID(), media = UUID()
    var stopped = 0
    defer {
        AudioSessionUse.endSystemCall(call); AudioSessionUse.endConference(media)
        AudioSessionUse.setSystemAudioActive(false); AudioSessionUse.endProbe(owner: probe)
    }
    #expect(AudioSessionUse.beginProbe(owner: probe) { stopped += 1 })
    AudioSessionUse.beginSystemCall(call) // Start/answer is fulfilled before a peer exists.
    #expect(stopped == 1)
    #expect(!AudioSessionUse.beginProbe(owner: probe) {})
    AudioSessionUse.beginConference(media)
    AudioSessionUse.endConference(media) // Early engine teardown must not release CallKit's claim.
    #expect(!AudioSessionUse.beginProbe(owner: probe) {})
    AudioSessionUse.setSystemAudioActive(true)
    AudioSessionUse.setSystemAudioActive(false) // An interruption is not the end of the call.
    #expect(!AudioSessionUse.beginProbe(owner: probe) {})
    AudioSessionUse.setSystemAudioActive(true)
    AudioSessionUse.endSystemCall(call)
    #expect(!AudioSessionUse.beginProbe(owner: probe) {}) // End can precede didDeactivate.
    AudioSessionUse.setSystemAudioActive(false)
    #expect(AudioSessionUse.beginProbe(owner: probe) {})
}

@MainActor @Test func lateSystemActivationStopsProbeWithoutReleasingOtherAudioOwners() {
    let probe = UUID(), call = UUID(), media = UUID()
    var activatedBeforeStop = false
    defer {
        AudioSessionUse.resetSystemCalls(); AudioSessionUse.endConference(media)
        AudioSessionUse.endProbe(owner: probe)
    }
    #expect(AudioSessionUse.beginProbe(owner: probe) { activatedBeforeStop = AudioSessionUse.systemAudioActive })
    AudioSessionUse.setSystemAudioActive(true)
    #expect(activatedBeforeStop) // Probe cleanup must know not to deactivate CallKit's active session.
    #expect(!AudioSessionUse.beginProbe(owner: probe) {})
    AudioSessionUse.beginSystemCall(call)
    AudioSessionUse.beginConference(media)
    AudioSessionUse.resetSystemCalls()
    #expect(!AudioSessionUse.systemAudioActive)
    #expect(!AudioSessionUse.beginProbe(owner: probe) {}) // Provider reset must not clear a conference owner.
    AudioSessionUse.endConference(media)
    #expect(AudioSessionUse.beginProbe(owner: probe) {})
}
