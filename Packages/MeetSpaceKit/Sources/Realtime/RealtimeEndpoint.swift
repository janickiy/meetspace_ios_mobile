import Foundation
import MeetSpaceCore

/// Audited WSS endpoint construction; tickets are never logged.
public enum RealtimeEndpoint {
    public enum Scope: Sendable { case user, conference(UUID) }
    public enum EndpointError: Error { case emptyTicket }

    /// Строит защищённый WebSocket-адрес для потока событий пользователя или конференции.
    /// - Parameters:
    ///   - origin: Базовый HTTPS-адрес сервера MeetSpace.
    ///   - scope: Поток событий пользователя или указанной конференции.
    ///   - ticket: Билет доступа к потоку событий, выданный сервером.
    public static func url(origin: ServerOrigin, scope: Scope, ticket: String) throws -> URL {
        guard !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EndpointError.emptyTicket }
        var parts = URLComponents(url: origin.url, resolvingAgainstBaseURL: false)!
        parts.scheme = "wss"
        switch scope {
        case .user: parts.path = "/api/v1/ws"
        case .conference(let id): parts.path = "/api/v1/conferences/\(id.uuidString.lowercased())/ws"
        }
        parts.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        return parts.url!
    }
}

public enum RealtimeState: Equatable, Sendable { case disconnected, connecting, connected, reconnecting }

public protocol RealtimeConnection: Sendable {
    /// Разрывает текущее соединение с сервером событий.
    func disconnect() async
    var states: AsyncStream<RealtimeState> { get async }
}
