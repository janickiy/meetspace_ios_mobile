import Foundation
import XCTest
import MeetSpaceCore
import MeetSpaceMedia

/// Hosted iOS tests load the actual M156 binary. They deliberately do not request camera/microphone
/// access, and therefore do not replace the required physical-device capture/interoperability tests.
@MainActor final class MediaIntegrationTests: XCTestCase {
    func testNativePeerOfferAndCloseCyclesWithCaptureOff() async throws {
        for _ in 0..<4 {
            let media = ConferenceMediaFactory.make()
            do {
                try await media.configure(ConferenceMediaConfiguration(iceServers: [], maxPeers: 4, mediaPeerID: UUID()))
                // These operations must also work before a camera capturer/permission exists.
                try await media.setCameraEnabled(false)
                try await media.setMicrophoneEnabled(false)
                try await media.switchCamera()
                try await media.switchCamera()
                let offer = try await media.makeOffer(iceRestart: false)
                XCTAssertEqual(offer.publications.count, 0, "No publication exists before explicit capture enable")
                XCTAssertEqual(offer.sdp.components(separatedBy: "\r\nm=").count - 1, 16)
                XCTAssertTrue(offer.sdp.contains("opus/48000"))
                XCTAssertTrue(offer.sdp.contains("VP8/90000"))
                XCTAssertFalse(offer.sdp.contains("H264/90000"))
                XCTAssertFalse(offer.sdp.contains("VP9/90000"))
                XCTAssertFalse(offer.sdp.contains("AV1/90000"))
                XCTAssertFalse(offer.sdp.contains("a=sendrecv"))
                await media.close()
                await media.close()
                do {
                    _ = try await media.makeOffer(iceRestart: false)
                    XCTFail("A closed media engine accepted negotiation")
                } catch { XCTAssertEqual(error as? ConferenceMediaError, .notConfigured) }
                var closed = false
                for await event in media.events {
                    if case .connectionState(.closed) = event { closed = true }
                    if case .captureState(let microphone, let camera, _) = event {
                        XCTAssertFalse(microphone); XCTAssertFalse(camera)
                    }
                }
                XCTAssertTrue(closed)
            } catch {
                await media.close()
                throw error
            }
        }
    }

    func testBlockedSourcesNeverRequestPermissionsOrAppearInOffer() async throws {
        let media = ConferenceMediaFactory.make()
        do {
            try await media.configure(ConferenceMediaConfiguration(iceServers: [], maxPeers: 2,
                mediaPeerID: UUID(), microphoneAllowed: false, cameraAllowed: false))
            do {
                try await media.setMicrophoneEnabled(true)
                XCTFail("Blocked microphone was enabled")
            } catch { XCTAssertEqual(error as? ConferenceMediaError, .publicationBlocked) }
            do {
                try await media.setCameraEnabled(true)
                XCTFail("Blocked camera was enabled")
            } catch { XCTAssertEqual(error as? ConferenceMediaError, .publicationBlocked) }
            try await media.setPublicationPermissions(microphone: true, camera: true)
            let offer = try await media.makeOffer(iceRestart: false)
            XCTAssertTrue(offer.publications.isEmpty, "Unblocking must not silently enable capture")
            XCTAssertFalse(offer.sdp.contains("a=sendrecv"))
            XCTAssertFalse(WebRTCLibrary.licenseText.isEmpty)
            await media.close()
        } catch {
            await media.close()
            throw error
        }
    }
}
