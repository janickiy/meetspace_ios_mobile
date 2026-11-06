import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceRealtime

private actor StressRealtimeSocket: RealtimeSocket {
    let stream: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var closed = false
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func receive() async throws -> Data {
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw RealtimeError.disconnected }
        return value
    }
    func emit(_ data: Data) { continuation.yield(data) }
    func close() { closed = true; continuation.finish() }
}
private actor StressRealtimeSockets: RealtimeSocketFactory {
    var sockets: [StressRealtimeSocket] = []
    var tickets: Set<String> = []
    var overlap = false
    func connect(_ url: URL) async -> any RealtimeSocket {
        if let last = sockets.last, await !last.closed { overlap = true }
        let ticket = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ticket" }?.value ?? ""
        #expect(!ticket.isEmpty && tickets.insert(ticket).inserted)
        let socket = StressRealtimeSocket(); sockets.append(socket); return socket
    }
}
private actor StressRealtimeCounter {
    var connected = 0, events = 0
    func record(_ update: UserRealtimeUpdate) {
        switch update { case .state(.connected): connected += 1; case .event: events += 1; default: break }
    }
}
private func stressRealtimeWait(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<500 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(2)) }
    throw APIError.timeout
}
@Test func stage08ThirtyReconnectsUseFreshTicketsWithoutSocketOverlap() async throws {
    let sockets = StressRealtimeSockets(), counter = StressRealtimeCounter()
    let realtime = UserRealtime(origin: Fixture.origin, ticket: { UUID().uuidString }, sockets: sockets,
        sleep: { _ in try Task.checkCancellation(); await Task.yield() })
    let consumer = Task { for await update in realtime.updates { await counter.record(update) } }
    await realtime.start()
    let payload = try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(Fixture.message()))
    let event = try Fixture.data(["version": 1, "id": UUID().uuidString, "type": "message.created",
        "data": ["conversationId": Fixture.conversationID.uuidString, "message": payload]])
    for index in 0...30 {
        try await stressRealtimeWait { await counter.connected == index + 1 }
        let socket = await sockets.sockets[index]
        await socket.emit(event) // Same event survives all reconnects without duplicate delivery.
        if index == 0 { try await stressRealtimeWait { await counter.events == 1 } }
        if index < 30 { await socket.close() }
    }
    await realtime.finish(); await consumer.value
    #expect(await counter.events == 1)
    #expect(await sockets.sockets.count == 31)
    #expect(await sockets.tickets.count == 31)
    #expect(await !sockets.overlap)
    for socket in await sockets.sockets { #expect(await socket.closed) }
    await realtime.start(); await Task.yield()
    #expect(await sockets.sockets.count == 31)
}
