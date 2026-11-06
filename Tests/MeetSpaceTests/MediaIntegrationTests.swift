import Foundation
import XCTest
import MeetSpaceCore
import MeetSpaceMedia
import MeetSpaceBroadcast

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
            try await media.setPublicationPermissions(microphone: true, camera: true, screen: false)
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

    func testScreenGenerationRollbackAndPolicyWithCaptureOff() async throws {
        let media = ConferenceMediaFactory.make()
        do {
            try await media.configure(ConferenceMediaConfiguration(iceServers: [], maxPeers: 2,
                mediaPeerID: UUID(), screenAllowed: true))
            var generations = Set<String>()
            for _ in 0..<3 {
                try await media.setScreenEnabled(true)
                let trackID = media.localScreenVideoTrackID
                XCTAssertTrue(generations.insert(trackID).inserted, "A restarted capture must have a new generation")
                let offer = try await media.makeOffer(iceRestart: false)
                XCTAssertEqual(offer.publications.count, 1)
                XCTAssertEqual(offer.publications.first?.source, "video/screen")
                XCTAssertEqual(offer.publications.first?.trackId, trackID)
                XCTAssertEqual(offer.sdp.components(separatedBy: "\r\nm=").count - 1, 8)
                // Screen conflict is rejected before server SetRemoteDescription: rollback locally.
                try await media.rollbackLocalOffer()
                try await media.setScreenEnabled(false)
                let withoutScreen = try await media.makeOffer(iceRestart: false)
                XCTAssertTrue(withoutScreen.publications.isEmpty)
                XCTAssertFalse(withoutScreen.sdp.contains("a=sendrecv"))
                XCTAssertEqual(withoutScreen.sdp.components(separatedBy: "\r\nm=").count - 1, 8)
                try await media.rollbackLocalOffer()
            }
            try await media.setPublicationPermissions(microphone: true, camera: false, screen: true)
            do { try await media.setScreenEnabled(true); XCTFail("Camera policy must also block screen video") }
            catch { XCTAssertEqual(error as? ConferenceMediaError, .publicationBlocked) }
            try await media.setPublicationPermissions(microphone: true, camera: true, screen: false)
            do { try await media.setScreenEnabled(true); XCTFail("Screen policy was ignored") }
            catch { XCTAssertEqual(error as? ConferenceMediaError, .publicationBlocked) }
            await media.close()
        } catch { await media.close(); throw error }
    }

    func testScreenRejectsInvalidAndStaleFrameSession() async throws {
        let media = ConferenceMediaFactory.make()
        do {
            try await media.configure(ConferenceMediaConfiguration(iceServers: [], maxPeers: 2,
                mediaPeerID: UUID(), screenAllowed: true))
            try await media.setScreenEnabled(true)
            let id = UUID()
            let valid = ScreenBroadcastFrame(sessionID: id, width: 2, height: 2, rowBytes: 8,
                timestampNs: 1, pixels: Data(repeating: 0, count: 16))
            try media.pushScreenFrame(valid)
            do {
                try media.pushScreenFrame(ScreenBroadcastFrame(sessionID: UUID(), width: 2, height: 2,
                    rowBytes: 8, timestampNs: 100_000_001, pixels: Data(repeating: 0, count: 16)))
                XCTFail("A different IPC session crossed the active screen generation")
            } catch { XCTAssertEqual(error as? ConferenceMediaError, .invalidScreenFrame) }
            do {
                try media.pushScreenFrame(ScreenBroadcastFrame(sessionID: id, width: 2, height: 2,
                    rowBytes: 8, timestampNs: 100_000_001, pixels: Data(repeating: 0, count: 15)))
                XCTFail("A truncated frame was accepted")
            } catch { XCTAssertEqual(error as? ConferenceMediaError, .invalidScreenFrame) }
            try await media.setScreenEnabled(false)
            do { try media.pushScreenFrame(valid); XCTFail("A stopped screen accepted another frame") }
            catch { XCTAssertEqual(error as? ConferenceMediaError, .screenUnavailable) }
            await media.close()
        } catch { await media.close(); throw error }
    }
}
