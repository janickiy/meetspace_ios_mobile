import Foundation

public struct SystemCallDescriptor: Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let isVideo: Bool
    public init(id: UUID, displayName: String, isVideo: Bool) {
        self.id = id; self.displayName = displayName; self.isVideo = isVideo
    }
}

public struct SystemCallAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case start, answer, end, setMuted(Bool) }
    public let id: UUID
    public let callID: UUID
    public let kind: Kind
    public let deadline: Date
    public init(id: UUID, callID: UUID, kind: Kind, deadline: Date) {
        self.id = id; self.callID = callID; self.kind = kind; self.deadline = deadline
    }
}

public enum SystemCallEndReason: Equatable, Sendable {
    case failed, remoteEnded, unanswered, answeredElsewhere, declinedElsewhere
}

public enum SystemCallingError: Error, Equatable, Sendable {
    case unavailable, invalidDescriptor, invalidated, requestRejected, incomingRejected
}

public enum SystemCallEvent: Equatable, Sendable {
    case action(SystemCallAction)
    case timedOut(SystemCallAction)
    case reset
    case audioActivationChanged(Bool)
}

/// CallKit actions remain pending until the coordinator completes the matching identifier.
/// Framework action objects and audio sessions never escape the native adapters.
@MainActor public protocol SystemCalling: AnyObject {
    /// Each access creates an independent subscription. Cancelling one account's consumer does
    /// not terminate the process-wide provider or another account's subscription.
    var events: AsyncStream<SystemCallEvent> { get }
    var isAvailable: Bool { get }
    /// This overload invokes the system report synchronously, before returning to PushKit.
    func reportIncoming(_ descriptor: SystemCallDescriptor,
                        completion: @escaping @Sendable (Result<Void, SystemCallingError>) -> Void)
    func requestStart(_ descriptor: SystemCallDescriptor) async throws
    func requestAnswer(callID: UUID) async throws
    func requestEnd(callID: UUID) async throws
    func requestMuted(_ muted: Bool, callID: UUID) async throws
    func completeAction(id: UUID, succeeded: Bool)
    func reportConnecting(callID: UUID, at date: Date?)
    func reportConnected(callID: UUID, at date: Date?)
    func reportEnded(callID: UUID, reason: SystemCallEndReason, at date: Date?)
    func updateCall(_ descriptor: SystemCallDescriptor)
    func invalidate()
}

public extension SystemCalling {
    func reportIncoming(_ descriptor: SystemCallDescriptor) async throws {
        try await withCheckedThrowingContinuation { continuation in
            reportIncoming(descriptor) { @Sendable result in continuation.resume(with: result) }
        }
    }
    func reportConnecting(callID: UUID) { reportConnecting(callID: callID, at: nil) }
    func reportConnected(callID: UUID) { reportConnected(callID: callID, at: nil) }
    func reportEnded(callID: UUID, reason: SystemCallEndReason) { reportEnded(callID: callID, reason: reason, at: nil) }
}

@MainActor public enum SystemCallingFactory {
    public static func make() -> any SystemCalling {
        #if os(iOS)
        NativeSystemCalling()
        #else
        UnavailableSystemCalling()
        #endif
    }
}

#if !os(iOS)
@MainActor private final class UnavailableSystemCalling: SystemCalling {
    var events: AsyncStream<SystemCallEvent> { AsyncStream { $0.finish() } }
    let isAvailable = false
    func reportIncoming(_ descriptor: SystemCallDescriptor, completion: @escaping @Sendable (Result<Void, SystemCallingError>) -> Void) {
        completion(.failure(.unavailable))
    }
    func requestStart(_ descriptor: SystemCallDescriptor) async throws { throw SystemCallingError.unavailable }
    func requestAnswer(callID: UUID) async throws { throw SystemCallingError.unavailable }
    func requestEnd(callID: UUID) async throws { throw SystemCallingError.unavailable }
    func requestMuted(_ muted: Bool, callID: UUID) async throws { throw SystemCallingError.unavailable }
    func completeAction(id: UUID, succeeded: Bool) { }
    func reportConnecting(callID: UUID, at date: Date?) { }
    func reportConnected(callID: UUID, at date: Date?) { }
    func reportEnded(callID: UUID, reason: SystemCallEndReason, at date: Date?) { }
    func updateCall(_ descriptor: SystemCallDescriptor) { }
    func invalidate() { }
}
#endif
