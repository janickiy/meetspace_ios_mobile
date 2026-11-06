import Foundation

/// Bounds are applied in either orientation. ReplayKit audio buffers are never transported.
public struct ScreenBroadcastConfiguration: Codable, Equatable, Sendable {
    public let maxWidth: Int
    public let maxHeight: Int
    public let maxFrameRate: Int
    public init(maxWidth: Int = 1280, maxHeight: Int = 720, maxFrameRate: Int = 10) {
        self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxFrameRate = maxFrameRate
    }
    @discardableResult public func validated() throws -> Self {
        guard (2...1280).contains(maxWidth), (2...1280).contains(maxHeight),
              maxWidth * maxHeight <= 1280 * 720, (1...10).contains(maxFrameRate) else {
            throw ScreenBroadcastError.invalidConfiguration
        }
        return self
    }
}

/// Upright, tightly packed BGRA. The lease ID fences queued frames across stop/restart/account changes.
public struct ScreenBroadcastFrame: Equatable, Sendable {
    public let sessionID: UUID
    public let width: Int
    public let height: Int
    public let rowBytes: Int
    public let timestampNs: Int64
    public let pixels: Data
    public init(sessionID: UUID, width: Int, height: Int, rowBytes: Int, timestampNs: Int64, pixels: Data) {
        self.sessionID = sessionID; self.width = width; self.height = height
        self.rowBytes = rowBytes; self.timestampNs = timestampNs; self.pixels = pixels
    }
    @discardableResult public func validated(configuration: ScreenBroadcastConfiguration = .init()) throws -> Self {
        try configuration.validated()
        guard (2...1280).contains(width), (2...1280).contains(height),
              max(width, height) <= max(configuration.maxWidth, configuration.maxHeight),
              min(width, height) <= min(configuration.maxWidth, configuration.maxHeight),
              rowBytes == width * 4, timestampNs >= 0, pixels.count == rowBytes * height else {
            throw ScreenBroadcastError.invalidFrame
        }
        return self
    }
}

public enum ScreenBroadcastStopReason: String, Codable, Equatable, Sendable {
    case user, hostUnavailable, timedOut, memoryPressure, invalidFrame, connectionLost, unavailable
}
public enum ScreenBroadcastError: Error, Equatable, Sendable {
    case unavailable, alreadyInUse, invalidConfiguration, invalidFrame, staleSession, connectionLost, timedOut
}
public enum ScreenBroadcastEvent: Equatable, Sendable {
    case started(UUID), paused(UUID), resumed(UUID), stopped(UUID, ScreenBroadcastStopReason)
}

/// Lifecycle and frames use separate bounded streams so a busy frame consumer cannot lose stop.
@MainActor public protocol ScreenBroadcastController: AnyObject {
    var events: AsyncStream<ScreenBroadcastEvent> { get }
    var frames: AsyncStream<ScreenBroadcastFrame> { get }
    var isAvailable: Bool { get }
    var extensionBundleID: String? { get }
    var sessionID: UUID? { get }
    func prepare(configuration: ScreenBroadcastConfiguration) async throws
    func stop() async
}

public enum BroadcastInstallation {
    public static let groupInfoKey = "MeetSpaceBroadcastAppGroup"
    public static let extensionInfoKey = "MeetSpaceBroadcastExtension"
}
