import Foundation
import Testing
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceRealtime

private enum SimulatedDisconnect: Error { case closed }
private actor ControlledSocket: RealtimeSocket {
    let stream: AsyncThrowingStream<Data, Error>
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func receive() async throws -> Data {
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw SimulatedDisconnect.closed }
        return value
    }
    func emit(_ value: Data) { continuation.yield(value) }
    func close() { continuation.finish(throwing: SimulatedDisconnect.closed) }
}
private actor ControlledSockets: RealtimeSocketFactory {
    var sockets: [ControlledSocket] = []
    var urls: [URL] = []
    func connect(_ url: URL) -> any RealtimeSocket {
        urls.append(url); let socket = ControlledSocket(); sockets.append(socket); return socket
    }
    func emit(_ data: Data, on index: Int) async { await sockets[index].emit(data) }
    func drop(_ index: Int) async { await sockets[index].close() }
}
private actor RealtimeObservations {
    var tickets = 0
    var events = 0
    var connected = 0
    var delays: [Double] = []
    func ticket() -> String { tickets += 1; return "fixture-ticket-\(tickets)" }
    func receive(_ update: UserRealtimeUpdate) {
        switch update {
        case .event: events += 1
        case .state(.connected): connected += 1
        default: break
        }
    }
    func pause(_ delay: Double) async throws {
        delays.append(delay); try await Task.sleep(for: .milliseconds(5))
    }
}
private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw SimulatedDisconnect.closed
}

@Test func reconnectUsesFreshTicketsDeduplicatesAndStopsOnCancellation() async throws {
    let sockets = ControlledSockets(), observed = RealtimeObservations()
    let realtime = UserRealtime(origin: Fixture.origin, ticket: { await observed.ticket() },
        sockets: sockets, sleep: { try await observed.pause($0) })
    let consumer = Task { for await update in realtime.updates { await observed.receive(update) } }
    await realtime.start()
    try await eventually { await observed.connected == 1 }
    let message = try Fixture.message()
    let payload = try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(message))
    let event = try Fixture.data(["version": 1, "id": UUID().uuidString, "type": "message.created",
                                 "data": ["conversationId": Fixture.conversationID.uuidString, "message": payload]])
    await sockets.emit(event, on: 0); await sockets.emit(event, on: 0)
    try await eventually { await observed.events == 1 }
    await sockets.drop(0)
    try await eventually { await observed.connected == 2 }
    await sockets.emit(event, on: 1)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await observed.events == 1)
    #expect(await observed.tickets == 2)
    let urls = await sockets.urls
    #expect(urls.count == 2 && urls[0] != urls[1])
    #expect(urls.allSatisfy { $0.scheme == "wss" && $0.path == "/api/v1/ws" && $0.user == nil })
    #expect(await observed.delays.count == 1)
    await realtime.finish(); await consumer.value
    await realtime.start()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await sockets.urls.count == 2)
}

@Test func productionTransportsRejectUnencryptedEndpointsBeforeNetworking() async throws {
    await #expect(throws: APIError.tls) { try await URLSessionSocketFactory().connect(URL(string: "ws://127.0.0.1:1/api/v1/ws")!) }
    await #expect(throws: APIError.tls) {
        try await URLSessionRequestTransport().send(URLRequest(url: URL(string: "http://127.0.0.1:1/")!),
            limit: 10, uploadFile: nil, progress: nil)
    }
}
