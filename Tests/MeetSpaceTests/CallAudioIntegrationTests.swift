import Foundation
import XCTest
import MeetSpaceMedia

/// Actual iOS WebRTC binary; no fake system activation and no capture/permission request.
@MainActor final class CallAudioIntegrationTests: XCTestCase {
    func testDirectCallCanNegotiateBeforeCallKitActivatesAudio() async throws {
        CallAudioSessionBridge.reset()
        let engine = ConferenceMediaFactory.make()
        do {
            try await engine.configure(ConferenceMediaConfiguration(iceServers: [], maxPeers: 2,
                mediaPeerID: UUID(), audioActivation: .callKit))
            XCTAssertFalse(CallAudioSessionBridge.isActive)
            let offer = try await engine.makeOffer(iceRestart: false)
            XCTAssertTrue(offer.publications.isEmpty)
            XCTAssertTrue(offer.sdp.contains("opus/48000"))
            XCTAssertFalse(CallAudioSessionBridge.isActive)
            await engine.close()
        } catch {
            await engine.close(); throw error
        }
    }
}
