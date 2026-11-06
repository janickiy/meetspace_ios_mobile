import Foundation
import Darwin

/// One listener, one authenticated extension, one latest-frame stream. No network credentials or pixels on disk.
final class BroadcastHostChannel: @unchecked Sendable {
    let descriptor: BroadcastWire.Descriptor
    private let directory: URL
    private let event: @Sendable (ScreenBroadcastEvent) -> Void
    private let frame: @Sendable (ScreenBroadcastFrame) -> Void
    private let queue = DispatchQueue(label: "meetspace.broadcast.host", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: BroadcastSocket?
    private var client: BroadcastSocket?
    private var cancelled = false
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(directory: URL, configuration: ScreenBroadcastConfiguration, sessionID: UUID,
         event: @escaping @Sendable (ScreenBroadcastEvent) -> Void,
         frame: @escaping @Sendable (ScreenBroadcastFrame) -> Void) {
        self.directory = directory; self.event = event; self.frame = frame
        descriptor = BroadcastWire.Descriptor(version: 1, sessionID: sessionID,
            nonce: (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased(),
            expiresAt: Date().addingTimeInterval(90), configuration: configuration)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.run(ready: continuation) }
        }
    }
    func heartbeat() {
        guard let socket = lock.withLock({ cancelled ? nil : client }) else { return }
        do { _ = try socket.send(.heartbeat, dropIfBusy: true) } catch { socket.shutdown() }
    }
    func stop() async {
        shutdown()
        await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if completed { return true }; waiters.append(continuation); return false
            }
            if done { continuation.resume() }
        }
    }
    func shutdown() {
        let sockets = lock.withLock { () -> (BroadcastSocket?, BroadcastSocket?) in
            cancelled = true; return (listener, client)
        }
        // Shutdown is immediate and wakes blocked workers; no UI-thread wait for a receiver.
        sockets.0?.shutdown(); sockets.1?.shutdown()
    }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func run(ready: CheckedContinuation<Void, any Error>) {
        var readySent = false
        var lockFD: Int32 = -1
        var ownsFiles = false
        var reason = ScreenBroadcastStopReason.user
        defer {
            let sockets = lock.withLock { (listener, client) }
            sockets.0?.shutdown(); sockets.1?.shutdown()
            if ownsFiles {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(BroadcastWire.descriptorName))
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(BroadcastWire.socketName))
            }
            if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
            let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                listener = nil; client = nil; completed = true
                let list = waiters; waiters = []; return list
            }
            event(.stopped(descriptor.sessionID, isCancelled ? .user : reason))
            for continuation in continuations { continuation.resume() }
        }
        do {
            try descriptor.configuration.validated()
            var address = try BroadcastWire.address(directory)
            lockFD = open(directory.appendingPathComponent(BroadcastWire.lockName).path,
                O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ScreenBroadcastError.alreadyInUse }
            guard !isCancelled else { throw CancellationError() }
            ownsFiles = true
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(BroadcastWire.socketName))
            let server = try BroadcastSocket(fd: socket(AF_UNIX, SOCK_STREAM, 0))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0, listen(server.fd, 2) == 0 else { throw ScreenBroadcastError.unavailable }
            _ = chmod(directory.appendingPathComponent(BroadcastWire.socketName).path, S_IRUSR | S_IWUSR)
            lock.withLock { listener = server }
            let url = directory.appendingPathComponent(BroadcastWire.descriptorName)
            try JSONEncoder().encode(descriptor).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            #endif
            guard !isCancelled else { throw CancellationError() }
            readySent = true; ready.resume()
            let deadline = DispatchTime.now().uptimeNanoseconds + 90_000_000_000
            var accepted: BroadcastSocket?
            while !isCancelled, accepted == nil {
                try server.wait(Int16(POLLIN), until: deadline)
                let fd = accept(server.fd, nil, nil)
                if fd < 0, [EAGAIN, EINTR, EWOULDBLOCK].contains(errno) { continue }
                let connection = try BroadcastSocket(fd: fd)
                do {
                    let (kind, bytes) = try connection.readPacket(timeout: 2)
                    guard kind == .hello, let hello = try? JSONDecoder().decode(BroadcastWire.Hello.self, from: bytes),
                          hello.sessionID == descriptor.sessionID, hello.nonce == descriptor.nonce else {
                        throw ScreenBroadcastError.staleSession
                    }
                    guard !isCancelled else { throw CancellationError() }
                    _ = try connection.send(.welcome)
                    accepted = connection
                } catch { connection.shutdown() }
            }
            guard let connection = accepted, !isCancelled else { throw CancellationError() }
            lock.withLock { client = connection }
            event(.started(descriptor.sessionID))
            var lastTimestamp: Int64 = -1
            var paused = false
            while !isCancelled {
                let (kind, bytes) = try connection.readPacket(timeout: 6)
                switch kind {
                case .heartbeat: guard bytes.isEmpty else { throw ScreenBroadcastError.invalidFrame }
                case .frame:
                    let value = try BroadcastWire.frame(bytes, descriptor: descriptor)
                    guard value.timestampNs > lastTimestamp else { throw ScreenBroadcastError.invalidFrame }
                    lastTimestamp = value.timestampNs
                    if !paused { frame(value) }
                case .paused:
                    guard bytes.isEmpty else { throw ScreenBroadcastError.invalidFrame }
                    paused = true; event(.paused(descriptor.sessionID))
                case .resumed:
                    guard bytes.isEmpty else { throw ScreenBroadcastError.invalidFrame }
                    paused = false; event(.resumed(descriptor.sessionID))
                case .stopped:
                    guard let value = String(data: bytes, encoding: .utf8).flatMap(ScreenBroadcastStopReason.init(rawValue:)) else {
                        throw ScreenBroadcastError.invalidFrame
                    }
                    reason = value; return
                default: throw ScreenBroadcastError.invalidFrame
                }
            }
        } catch {
            if !readySent { ready.resume(throwing: error) }
            switch error {
            case ScreenBroadcastError.timedOut: reason = .timedOut
            case ScreenBroadcastError.invalidFrame, ScreenBroadcastError.staleSession: reason = .invalidFrame
            case ScreenBroadcastError.unavailable, ScreenBroadcastError.alreadyInUse: reason = .unavailable
            default: reason = .connectionLost
            }
        }
    }
}
