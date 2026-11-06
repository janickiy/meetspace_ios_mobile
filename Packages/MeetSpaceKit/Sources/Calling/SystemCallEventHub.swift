import Foundation

/// The provider outlives account coordinators. Each coordinator gets its own cancellable stream.
@MainActor final class SystemCallEventHub {
    private var subscribers: [UUID: AsyncStream<SystemCallEvent>.Continuation] = [:]
    private var finished = false

    func subscribe(replay: [SystemCallEvent] = []) -> AsyncStream<SystemCallEvent> {
        let id = UUID()
        // These low-volume system actions must never silently drop an end/reset behind UI events.
        let pair = AsyncStream.makeStream(of: SystemCallEvent.self)
        guard !finished else { pair.continuation.finish(); return pair.stream }
        subscribers[id] = pair.continuation
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.subscribers[id] = nil }
        }
        for event in replay { pair.continuation.yield(event) }
        return pair.stream
    }

    func yield(_ event: SystemCallEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    func finish() {
        finished = true
        let old = subscribers; subscribers.removeAll()
        for continuation in old.values { continuation.finish() }
    }
}
