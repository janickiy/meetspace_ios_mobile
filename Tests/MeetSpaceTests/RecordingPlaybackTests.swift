import XCTest
import AVFoundation
@testable import MeetSpace

private struct RecordingPlaybackMetadata: Sendable {
    let playable: Bool
    let duration: Double
    let audioTracks: Int
}

@MainActor final class RecordingPlaybackTests: XCTestCase {
    func testActualServerAACArtifactAdvancesNativePlayerTime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try UITestRecordingFixture.audioData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = try await Self.inspect(url)
        XCTAssertTrue(metadata.playable); XCTAssertEqual(metadata.audioTracks, 1)
        XCTAssertEqual(metadata.duration, 8.252333, accuracy: 0.1)
        let player = AVPlayer(url: url)
        player.isMuted = true; player.play()
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        for _ in 0..<100 {
            if player.status == .failed || player.currentItem?.status == .failed { break }
            if player.currentTime().seconds >= 0.2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 0.2)
    }

    // SDK 18.5's AVAssetTrack is not Sendable. Keep assets/tracks on the generic
    // executor and return values only; the actual player stays on MainActor.
    private nonisolated static func inspect(_ url: URL) async throws -> RecordingPlaybackMetadata {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        return RecordingPlaybackMetadata(playable: playable, duration: duration.seconds, audioTracks: tracks.count)
    }
}
