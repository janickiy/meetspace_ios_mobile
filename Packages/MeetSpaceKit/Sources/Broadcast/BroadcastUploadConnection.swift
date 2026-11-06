import Foundation
import Darwin

/// Extension-side IPC only. Audio samples, account credentials, URLs and WebRTC never enter this API.
public final class BroadcastUploadConnection: @unchecked Sendable {
    private let directory: URL?
    private let lock = NSLock()
    private var socket: BroadcastSocket?
    private var descriptor: BroadcastWire.Descriptor?
    private var finished = false
    private var starting = false
    private var onStop: (@Sendable (ScreenBroadcastStopReason) -> Void)?
    private var lastFrameTimestamp: Int64 = -1
    public var sessionID: UUID? { lock.withLock { descriptor?.sessionID } }

    public init(appGroupIdentifier: String) { directory = BroadcastWire.groupDirectory(appGroupIdentifier) }
    /// For deterministic IPC tests; production always resolves the signed group container.
    public init(directory: URL) { self.directory = directory }
    deinit { socket?.shutdown() }

    public func start(onStop: @escaping @Sendable (ScreenBroadcastStopReason) -> Void) throws -> ScreenBroadcastConfiguration {
        let allowed = lock.withLock { () -> Bool in
            guard !starting, !finished, socket == nil else { return false }
            starting = true; self.onStop = onStop; return true
        }
        guard allowed else { throw ScreenBroadcastError.alreadyInUse }
        defer { lock.withLock { starting = false } }
        do {
            guard let directory else { throw ScreenBroadcastError.unavailable }
            let descriptor = try BroadcastWire.descriptor(at: directory)
            var address = try BroadcastWire.address(directory)
            let connection = try BroadcastSocket(fd: Darwin.socket(AF_UNIX, SOCK_STREAM, 0))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(connection.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw ScreenBroadcastError.connectionLost }
            let installed = lock.withLock { () -> Bool in
                guard !finished else { return false }
                self.descriptor = descriptor; socket = connection; return true
            }
            guard installed else { connection.shutdown(); throw ScreenBroadcastError.staleSession }
            _ = try connection.send(.hello, payload: JSONEncoder().encode(BroadcastWire.Hello(sessionID: descriptor.sessionID, nonce: descriptor.nonce)))
            let (kind, data) = try connection.readPacket(timeout: 3)
            guard kind == .welcome, data.isEmpty, !lock.withLock({ finished }) else { throw ScreenBroadcastError.staleSession }
            DispatchQueue(label: "meetspace.broadcast.extension.control", qos: .userInitiated).async { [weak self] in
                self?.readControls(connection)
            }
            return descriptor.configuration
        } catch {
            terminate((error as? ScreenBroadcastError) == .timedOut ? .timedOut : .hostUnavailable, notify: false)
            throw error
        }
    }

    /// False means the frame was deliberately dropped (FPS/backpressure). No frame is queued here.
    @discardableResult public func send(frame: ScreenBroadcastFrame) throws -> Bool {
        let state = try lock.withLock { () throws -> (BroadcastSocket, BroadcastWire.Descriptor)? in
            guard !finished, let socket, let descriptor, frame.sessionID == descriptor.sessionID else { throw ScreenBroadcastError.staleSession }
            try frame.validated(configuration: descriptor.configuration)
            let interval = Int64(1_000_000_000 / descriptor.configuration.maxFrameRate)
            guard lastFrameTimestamp < 0 || frame.timestampNs > lastFrameTimestamp else { throw ScreenBroadcastError.invalidFrame }
            guard lastFrameTimestamp < 0 || frame.timestampNs - lastFrameTimestamp >= interval else { return nil }
            lastFrameTimestamp = frame.timestampNs
            return (socket, descriptor)
        }
        guard let state else { return false }
        do { return try state.0.send(.frame, payload: BroadcastWire.frameData(frame), dropIfBusy: true) }
        catch { terminate(.connectionLost, notify: true); throw error }
    }
    public func pause() { control(.paused) }
    public func resume() { control(.resumed) }
    public func finish(reason: ScreenBroadcastStopReason = .user) {
        let connection = lock.withLock { socket }
        _ = try? connection?.send(.stopped, payload: Data(reason.rawValue.utf8))
        terminate(reason, notify: false)
    }
    private func control(_ kind: BroadcastWire.Kind) {
        guard let connection = lock.withLock({ finished ? nil : socket }) else { return }
        do { _ = try connection.send(kind) } catch { terminate(.connectionLost, notify: true) }
    }
    private func readControls(_ connection: BroadcastSocket) {
        do {
            while !lock.withLock({ finished }) {
                let (kind, bytes) = try connection.readPacket(timeout: 5)
                guard kind == .heartbeat, bytes.isEmpty else { throw ScreenBroadcastError.invalidFrame }
                // A paused extension still answers liveness; heartbeat writes do not queue behind video.
                _ = try connection.send(.heartbeat, dropIfBusy: true)
            }
        } catch {
            terminate((error as? ScreenBroadcastError) == .timedOut ? .timedOut : .hostUnavailable, notify: true)
        }
    }
    private func terminate(_ reason: ScreenBroadcastStopReason, notify: Bool) {
        let result = lock.withLock { () -> (BroadcastSocket?, (@Sendable (ScreenBroadcastStopReason) -> Void)?) in
            guard !finished else { return (nil, nil) }
            finished = true
            let result = (socket, notify ? onStop : nil)
            socket = nil; descriptor = nil; onStop = nil
            return result
        }
        result.0?.shutdown(); result.1?(reason)
    }
}
