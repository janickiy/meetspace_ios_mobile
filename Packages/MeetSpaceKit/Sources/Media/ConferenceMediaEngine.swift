import Foundation
import SwiftUI
import MeetSpaceCore

public struct ConferenceMediaConfiguration: Sendable {
    public var iceServers: [ICEServer]
    public var iceTransportPolicy: String
    public var maxPeers: Int
    public var mediaPeerID: UUID
    public var maxWidth: Int
    public var maxHeight: Int
    public var maxFrameRate: Int
    public var microphoneAllowed: Bool
    public var cameraAllowed: Bool
    public init(iceServers: [ICEServer], iceTransportPolicy: String = "all", maxPeers: Int = 8,
                mediaPeerID: UUID, maxWidth: Int = 1280, maxHeight: Int = 720, maxFrameRate: Int = 30,
                microphoneAllowed: Bool = true, cameraAllowed: Bool = true) {
        self.iceServers = iceServers; self.iceTransportPolicy = iceTransportPolicy
        self.maxPeers = maxPeers; self.mediaPeerID = mediaPeerID
        self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxFrameRate = maxFrameRate
        self.microphoneAllowed = microphoneAllowed; self.cameraAllowed = cameraAllowed
    }
}

public struct ConferenceICECandidate: Codable, Equatable, Sendable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int32
    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        self.candidate = candidate; self.sdpMid = sdpMid; self.sdpMLineIndex = sdpMLineIndex
    }
}

public struct ConferenceMediaPublication: Codable, Equatable, Sendable {
    public let mid: String
    public let source: String
    public let trackId: String
    public init(mid: String, source: String, trackId: String) {
        self.mid = mid; self.source = source; self.trackId = trackId
    }
}

public struct ConferenceMediaOffer: Equatable, Sendable {
    public let sdp: String
    public let publications: [ConferenceMediaPublication]
    public init(sdp: String, publications: [ConferenceMediaPublication]) {
        self.sdp = sdp; self.publications = publications
    }
}

/// The view model resolves remote IDs/MIDs against the server's media catalog before displaying a tile.
public struct ConferenceVideoTrack: Identifiable, Equatable, Sendable {
    public let id: String
    public let mid: String?
    public let streamID: String?
    public let isLocal: Bool
    public init(id: String, mid: String?, streamID: String?, isLocal: Bool) {
        self.id = id; self.mid = mid; self.streamID = streamID; self.isLocal = isLocal
    }
}

public enum ConferenceMediaConnectionState: String, Equatable, Sendable {
    case new, connecting, connected, disconnected, failed, closed
}

public enum ConferenceMediaError: Error, Equatable, Sendable {
    case unavailable, invalidConfiguration, notConfigured, negotiation, invalidCandidate, publicationBlocked
    case microphonePermissionDenied, cameraPermissionDenied, cameraUnavailable, capture, audioSession, interrupted
}

public enum ConferenceMediaEvent: Equatable, Sendable {
    case candidate(ConferenceICECandidate)
    case iceGatheringComplete
    case negotiationNeeded
    case connectionState(ConferenceMediaConnectionState)
    case videoTrackAdded(ConferenceVideoTrack)
    case videoTrackRemoved(String)
    case captureState(microphone: Bool, camera: Bool, frontCamera: Bool)
    case audioRoute(String)
    case interrupted(Bool)
    case networkPathChanged
    case failure(ConferenceMediaError)
}

/// One engine belongs to one conference attempt. Capture starts only after an explicit enabled action.
/// `close` is final, drains camera shutdown, detaches renderers and releases the peer/audio session.
@MainActor public protocol ConferenceMediaEngine: AnyObject {
    var events: AsyncStream<ConferenceMediaEvent> { get }
    var localVideoTrackID: String { get }
    func configure(_ configuration: ConferenceMediaConfiguration) async throws
    func makeOffer(iceRestart: Bool) async throws -> ConferenceMediaOffer
    func applyAnswer(_ sdp: String) async throws
    func addRemoteCandidate(_ candidate: ConferenceICECandidate) async throws
    func setPublicationPermissions(microphone: Bool, camera: Bool) async throws
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func setCameraEnabled(_ enabled: Bool) async throws
    func switchCamera() async throws
    func setSpeakerEnabled(_ enabled: Bool) throws
    func suspend() async
    func close() async
    func videoView(trackID: String, mirrored: Bool) -> AnyView
}

@MainActor public enum ConferenceMediaFactory {
    public static func make() -> any ConferenceMediaEngine {
        #if os(iOS)
        NativeConferenceMediaEngine()
        #else
        UnavailableConferenceMediaEngine()
        #endif
    }
}

public enum WebRTCLibrary {
    public static let version = "156.0.0"
    public static var licenseText: String {
        ["WebRTC-LICENSE", "WebRTC-PATENTS", "WebRTC-Distribution-LICENSE", "WebRTC-THIRD-PARTY-NOTICES"].compactMap { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n")
    }
}

/// Host previews/tests never silently pretend that WebRTC media is available on macOS.
#if !os(iOS)
@MainActor private final class UnavailableConferenceMediaEngine: ConferenceMediaEngine {
    let events = AsyncStream<ConferenceMediaEvent> { $0.finish() }
    let localVideoTrackID = "unavailable"
    func configure(_ configuration: ConferenceMediaConfiguration) async throws { throw ConferenceMediaError.unavailable }
    func makeOffer(iceRestart: Bool) async throws -> ConferenceMediaOffer { throw ConferenceMediaError.unavailable }
    func applyAnswer(_ sdp: String) async throws { throw ConferenceMediaError.unavailable }
    func addRemoteCandidate(_ candidate: ConferenceICECandidate) async throws { throw ConferenceMediaError.unavailable }
    func setPublicationPermissions(microphone: Bool, camera: Bool) async throws { throw ConferenceMediaError.unavailable }
    func setMicrophoneEnabled(_ enabled: Bool) async throws { throw ConferenceMediaError.unavailable }
    func setCameraEnabled(_ enabled: Bool) async throws { throw ConferenceMediaError.unavailable }
    func switchCamera() async throws { throw ConferenceMediaError.unavailable }
    func setSpeakerEnabled(_ enabled: Bool) throws { throw ConferenceMediaError.unavailable }
    func suspend() async { }
    func close() async { }
    func videoView(trackID: String, mirrored: Bool) -> AnyView { AnyView(Color.clear) }
}
#endif
