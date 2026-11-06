import Foundation
import Testing
@testable import MeetSpaceBroadcast

// A separate host channel avoids the process-wide UI controller owner shared by other tests.
// The socket protocol and files are real; no ReplayKit extension or signed App Group is involved.
@Test func stage08ThirtyBroadcastSocketLeasesReleaseDescriptorsAndFenceOldFrames() async throws {
    let directory = URL(fileURLWithPath: "/tmp/msb-stress-" + UUID().uuidString.prefix(12))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    var leases = Set<UUID>()
    for _ in 0..<30 {
        let lease = UUID(); #expect(leases.insert(lease).inserted)
        let frames = AsyncStream<ScreenBroadcastFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let host = BroadcastHostChannel(directory: directory, configuration: .init(), sessionID: lease,
            event: { _ in }, frame: { frames.continuation.yield($0) })
        try await host.start()
        let connection = BroadcastUploadConnection(directory: directory)
        _ = try await Task.detached { try connection.start(onStop: { _ in }) }.value
        let frame = ScreenBroadcastFrame(sessionID: lease, width: 2, height: 2, rowBytes: 8,
            timestampNs: 1, pixels: Data(repeating: 42, count: 16))
        #expect(try connection.send(frame: frame))
        var iterator = frames.stream.makeAsyncIterator()
        #expect(await iterator.next() == frame)
        // Real FPS gate deliberately drops an immediate second frame rather than queueing it.
        let tooSoon = ScreenBroadcastFrame(sessionID: lease, width: 2, height: 2, rowBytes: 8,
            timestampNs: 2, pixels: frame.pixels)
        #expect(try !connection.send(frame: tooSoon))
        connection.finish()
        await host.stop(); frames.continuation.finish()
        #expect(connection.sessionID == nil)
        #expect(throws: ScreenBroadcastError.staleSession) { try connection.send(frame: frame) }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(BroadcastWire.descriptorName).path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(BroadcastWire.socketName).path))
        // The lock file is intentionally reusable; only a closed FD lets the next lease lock it.
    }
}
