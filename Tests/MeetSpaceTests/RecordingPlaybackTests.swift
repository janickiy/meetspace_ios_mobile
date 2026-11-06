import XCTest
import AVFoundation
@testable import MeetSpace

@MainActor final class RecordingPlaybackTests: XCTestCase {
    func testActualServerAACArtifactAdvancesNativePlayerTime() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try UITestRecordingFixture.audioData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(playable); XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(duration.seconds, 8.252333, accuracy: 0.1)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
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
}
