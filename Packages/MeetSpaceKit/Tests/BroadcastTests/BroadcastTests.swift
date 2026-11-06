import Foundation
import Testing
@testable import MeetSpaceBroadcast

@Suite(.serialized) struct BroadcastTests {
    @Test func frameBoundsAndWireLease() throws {
        let id = UUID(), configuration = ScreenBroadcastConfiguration()
        let descriptor = BroadcastWire.Descriptor(version: 1, sessionID: id, nonce: String(repeating: "a", count: 64),
            expiresAt: Date().addingTimeInterval(90), configuration: configuration)
        let frame = ScreenBroadcastFrame(sessionID: id, width: 4, height: 2, rowBytes: 16, timestampNs: 100, pixels: Data(0..<32))
        #expect(try BroadcastWire.frame(BroadcastWire.frameData(frame), descriptor: descriptor) == frame)
        #expect(throws: ScreenBroadcastError.invalidFrame) {
            try ScreenBroadcastFrame(sessionID: id, width: Int.max, height: 2, rowBytes: 1,
                timestampNs: 0, pixels: Data()).validated()
        }
        #expect(throws: ScreenBroadcastError.invalidConfiguration) { try ScreenBroadcastConfiguration(maxFrameRate: 30).validated() }
        var bytes = try BroadcastWire.frameData(frame)
        bytes.replaceSubrange(0..<36, with: Data(UUID().uuidString.utf8))
        #expect(throws: ScreenBroadcastError.staleSession) { try BroadcastWire.frame(bytes, descriptor: descriptor) }
        #expect(throws: ScreenBroadcastError.invalidFrame) { try BroadcastWire.frame(Data(bytes.prefix(51)), descriptor: descriptor) }
    }

    @Test @MainActor func localSocketFramesPauseStopAndNewLease() async throws {
        let directory = URL(fileURLWithPath: "/tmp/msb-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppGroupScreenBroadcastController(directory: directory, extensionBundleID: "test.broadcast")
        try await controller.prepare(configuration: .init())
        let original = try #require(controller.sessionID)
        let extensionConnection = BroadcastUploadConnection(directory: directory)
        let config = try await Task.detached { try extensionConnection.start(onStop: { _ in }) }.value
        #expect(config.maxFrameRate == 10)
        var lifecycle = controller.events.makeAsyncIterator()
        #expect(await lifecycle.next() == .started(original))
        let frame = ScreenBroadcastFrame(sessionID: original, width: 2, height: 2, rowBytes: 8,
            timestampNs: 10, pixels: Data(repeating: 0x72, count: 16))
        #expect(try await Task.detached { try extensionConnection.send(frame: frame) }.value)
        var video = controller.frames.makeAsyncIterator()
        #expect(await video.next() == frame)
        extensionConnection.pause()
        #expect(await lifecycle.next() == .paused(original))
        extensionConnection.resume()
        #expect(await lifecycle.next() == .resumed(original))
        await controller.stop()
        #expect(controller.sessionID == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(BroadcastWire.descriptorName).path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(BroadcastWire.socketName).path))
        try await controller.prepare(configuration: .init())
        #expect(controller.sessionID != original)
        #expect(throws: ScreenBroadcastError.self) { try extensionConnection.send(frame: frame) }
        await controller.stop()
    }

    @Test @MainActor func onlyOnePreparedOwnerAndCancelBeforeExtension() async throws {
        let directory = URL(fileURLWithPath: "/tmp/msb-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AppGroupScreenBroadcastController(directory: directory, extensionBundleID: "test")
        let second = AppGroupScreenBroadcastController(directory: directory, extensionBundleID: "test")
        try await first.prepare(configuration: .init())
        await #expect(throws: ScreenBroadcastError.alreadyInUse) { try await second.prepare(configuration: .init()) }
        await first.stop()
        try await second.prepare(configuration: .init())
        await second.stop()
    }

    @Test func extensionExpiresWithoutHostHeartbeat() async throws {
        let directory = URL(fileURLWithPath: "/tmp/msb-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = BroadcastHostChannel(directory: directory, configuration: .init(), sessionID: UUID(), event: { _ in }, frame: { _ in })
        try await host.start()
        let connection = BroadcastUploadConnection(directory: directory)
        let result = AsyncStream<ScreenBroadcastStopReason>.makeStream()
        _ = try connection.start(onStop: { result.continuation.yield($0); result.continuation.finish() })
        var iterator = result.stream.makeAsyncIterator()
        #expect(await iterator.next() == .timedOut)
        await host.stop()
    }
}
