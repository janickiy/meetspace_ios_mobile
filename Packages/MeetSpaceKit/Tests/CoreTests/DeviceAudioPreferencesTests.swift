import Foundation
import Testing
@testable import MeetSpaceCore

@Test func audioPreferencesPersistValidatedDeviceChoices() throws {
    let suite = "meetspace.audio.test." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(DeviceAudioPreferences.load(defaults: defaults).mutedOnJoin)
    var value = DeviceAudioPreferences()
    value.mutedOnJoin = false; value.noiseSuppression = false
    value.preferredInputUID = "connected-input"; value.inputGain = 0.45
    value.save(defaults: defaults)
    #expect(DeviceAudioPreferences.load(defaults: defaults) == value)
    value.inputGain = 8; value.preferredInputUID = "invalid\ninput"
    value.save(defaults: defaults)
    #expect(DeviceAudioPreferences.load(defaults: defaults).inputGain == 1)
    #expect(DeviceAudioPreferences.load(defaults: defaults).preferredInputUID == nil)
    defaults.set(Data("bad json".utf8), forKey: "meetspace.audio.v1")
    #expect(DeviceAudioPreferences.load(defaults: defaults) == DeviceAudioPreferences())
}

@Test func previousAudioPreferencesPreserveExistingLevelsAndUseUnityForNewOutputs() throws {
    let previous = Data(#"{"mutedOnJoin":false,"noiseSuppression":false,"preferredInputUID":"headset","inputGain":0.35}"#.utf8)
    let decoded = try JSONDecoder().decode(DeviceAudioPreferences.self, from: previous)
    #expect(decoded.mutedOnJoin == false)
    #expect(decoded.noiseSuppression == false)
    #expect(decoded.preferredInputUID == "headset")
    #expect(decoded.inputGain == 0.35)
    #expect(decoded.speakerVolume == 1)
    #expect(decoded.signalVolume == 1)
}
