import Foundation

@MainActor public enum BroadcastControllerFactory {
    public static func make() -> any ScreenBroadcastController {
        let info = Bundle.main.infoDictionary ?? [:]
        let group = info[BroadcastInstallation.groupInfoKey] as? String ?? ""
        let identifier = info[BroadcastInstallation.extensionInfoKey] as? String
        #if os(iOS)
        return AppGroupScreenBroadcastController(directory: BroadcastWire.groupDirectory(group), extensionBundleID: identifier)
        #else
        return AppGroupScreenBroadcastController(directory: nil, extensionBundleID: nil)
        #endif
    }
}

/// The app owns the SFU connection. ReplayKit does not grant background execution to this process.
/// Its main-actor heartbeat intentionally expires if the app is suspended, terminated or stuck.
@MainActor public final class AppGroupScreenBroadcastController: ScreenBroadcastController {
    public let events: AsyncStream<ScreenBroadcastEvent>
    public let frames: AsyncStream<ScreenBroadcastFrame>
    public let extensionBundleID: String?
    public private(set) var sessionID: UUID?
    public var isAvailable: Bool {
        guard let directory, let extensionBundleID, !extensionBundleID.isEmpty else { return false }
        return (try? BroadcastWire.address(directory)) != nil
    }
    private let directory: URL?
    private let eventContinuation: AsyncStream<ScreenBroadcastEvent>.Continuation
    private let frameContinuation: AsyncStream<ScreenBroadcastFrame>.Continuation
    private var channel: BroadcastHostChannel?
    private var heartbeat: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private static var owner: UUID?

    /// Explicit directory injection is for host transport tests. Production resolves the signed app group.
    public init(directory: URL?, extensionBundleID: String?) {
        self.directory = directory; self.extensionBundleID = extensionBundleID
        let lifecycle = AsyncStream<ScreenBroadcastEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        events = lifecycle.stream; eventContinuation = lifecycle.continuation
        let video = AsyncStream<ScreenBroadcastFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = video.stream; frameContinuation = video.continuation
    }
    deinit {
        heartbeat?.cancel(); channel?.shutdown()
        eventContinuation.finish(); frameContinuation.finish()
        let previous = channel, id = sessionID
        Task { @MainActor in
            await previous?.stop()
            if AppGroupScreenBroadcastController.owner == id { AppGroupScreenBroadcastController.owner = nil }
        }
    }
    public func prepare(configuration: ScreenBroadcastConfiguration = .init()) async throws {
        try configuration.validated()
        guard isAvailable, let directory else { throw ScreenBroadcastError.unavailable }
        await stopping?.value
        try Task.checkCancellation()
        guard sessionID == nil, Self.owner == nil else { throw ScreenBroadcastError.alreadyInUse }
        let id = UUID(); Self.owner = id; sessionID = id
        let output = frameContinuation
        let next = BroadcastHostChannel(directory: directory, configuration: configuration, sessionID: id,
            event: { [weak self] event in Task { @MainActor [weak self] in self?.receive(event, lease: id) } },
            frame: { frame in output.yield(frame) })
        channel = next
        do {
            try await next.start()
            try Task.checkCancellation()
            guard sessionID == id else { throw CancellationError() }
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.sessionID == id else { return }
                    // Sending is nonblocking apart from a bounded socket deadline on a utility queue.
                    let channel = self.channel
                    DispatchQueue.global(qos: .utility).async { channel?.heartbeat() }
                }
            }
        } catch {
            if sessionID == id { await stop() }
            throw error
        }
    }
    public func stop() async {
        if let stopping { await stopping.value; return }
        guard let id = sessionID else { return }
        sessionID = nil; heartbeat?.cancel(); heartbeat = nil
        let previous = channel; channel = nil
        let task = Task { @MainActor in
            await previous?.stop()
            if Self.owner == id { Self.owner = nil }
        }
        stopping = task; await task.value; stopping = nil
        eventContinuation.yield(.stopped(id, .user))
    }
    private func receive(_ event: ScreenBroadcastEvent, lease: UUID) {
        guard sessionID == lease else { return }
        eventContinuation.yield(event)
        if case .stopped = event {
            Task { [weak self] in
                guard let self, self.sessionID == lease else { return }
                await self.stop()
            }
        }
    }
}
