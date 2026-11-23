import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI
import MeetSpaceRealtime
import MeetSpaceMedia
import MeetSpaceBroadcast

@MainActor @Observable public final class ConferenceWorkspace {
    public let repository: ConferenceRepository
    public private(set) var meetings: [Conference] = []
    public private(set) var hasMore = false
    public private(set) var loadingMore = false
    @ObservationIgnored private var nextOffset = 0
    private let pageSize = 50
    public private(set) var call: ConferenceSession?
    public private(set) var state: LoadState = .empty
    public private(set) var busy = false
    public var error: String?
    @ObservationIgnored private let sockets: any ConferenceSocketFactory
    @ObservationIgnored private let makeMedia: @MainActor @Sendable () -> any ConferenceMediaEngine
    @ObservationIgnored private let makeBroadcast: @MainActor @Sendable () -> any ScreenBroadcastController
    @ObservationIgnored private let canUseMedia: @MainActor () -> Bool
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var departing: ConferenceSession?
    public init(repository: ConferenceRepository, sockets: any ConferenceSocketFactory,
                makeMedia: @escaping @MainActor @Sendable () -> any ConferenceMediaEngine,
                makeBroadcast: @escaping @MainActor @Sendable () -> any ScreenBroadcastController = { BroadcastControllerFactory.make() },
                canUseMedia: @escaping @MainActor () -> Bool = { true }) {
        self.repository = repository; self.sockets = sockets; self.makeMedia = makeMedia; self.makeBroadcast = makeBroadcast
        self.canUseMedia = canUseMedia
    }
    public func load() async {
        guard !closed else { return }
        let current = UUID(); epoch = current; state = .loading
        loadingMore = false
        do {
            let result = try await repository.list(limit: pageSize)
            guard !closed, epoch == current else { return }
            nextOffset = result.count; hasMore = result.count == pageSize
            meetings = result; state = result.isEmpty ? .empty : .content; error = nil
        } catch {
            guard !closed, epoch == current else { return }
            state = .failed; self.error = userMessage(error)
        }
    }

    public func loadMore() async {
        guard !closed, hasMore, !loadingMore, state == .content else { return }
        let current = epoch
        loadingMore = true
        defer { if epoch == current { loadingMore = false } }
        do {
            let page = try await repository.list(limit: pageSize, offset: nextOffset)
            guard !closed, epoch == current else { return }
            var known = Set(meetings.map(\.id))
            meetings.append(contentsOf: page.filter { known.insert($0.id).inserted })
            nextOffset += page.count; hasMore = page.count == pageSize
            error = nil
        } catch {
            guard !closed, epoch == current else { return }
            self.error = userMessage(error)
        }
    }
    public func create(title: String, waitingRoom: Bool) async -> Bool {
        guard !busy, !closed, call == nil, mediaAvailable() else { return false }
        busy = true; error = nil; defer { busy = false }
        guard await completeDeparture() else { return false }
        do {
            let created = try await repository.create(title: title, waitingRoomEnabled: waitingRoom)
            guard !closed else { return false }
            let started = try await repository.transition(created.id, action: "start")
            guard !closed else { return false }
            let membership = try await repository.join(started.id)
            guard !closed else { _ = try? await repository.leave(started.id); return false }
            install(started, membership: membership); await load(); return true
        } catch { if !closed { self.error = userMessage(error) }; return false }
    }
    public func join(_ conference: Conference) async {
        guard !busy, !closed, call == nil, mediaAvailable() else { return }
        busy = true; error = nil; defer { busy = false }
        guard await completeDeparture() else { return }
        do {
            var current = try await repository.read(conference.id)
            guard !closed else { return }
            if ["created", "scheduled"].contains(current.status), current.ownerId == repository.userID {
                current = try await repository.transition(current.id, action: "start")
            }
            guard !closed else { return }
            let membership = try await repository.join(current.id)
            guard !closed else { _ = try? await repository.leave(current.id); return }
            install(current, membership: membership)
        } catch { if !closed { self.error = userMessage(error) } }
    }
    func updateMembership(in conference: Conference, leave: Bool) async throws -> ConferenceParticipant {
        guard !closed, !busy, call == nil, !conference.isClosed else { throw ClientError.invalidInput }
        busy = true
        defer { busy = false }
        guard await completeDeparture() else { throw ClientError.invalidInput }
        let member = try await (leave ? repository.leave(conference.id) : repository.join(conference.id))
        guard !closed else {
            if !leave { _ = try? await repository.leave(conference.id) }
            throw CancellationError()
        }
        return member
    }

    public func joinInvitation(_ input: String) async -> Bool {
        guard !busy, !closed, call == nil, mediaAvailable() else { return false }
        busy = true; error = nil; defer { busy = false }
        guard await completeDeparture() else { return false }
        do {
            let code = try ConferenceInviteGateway.inviteCode(from: input, origin: repository.origin)
            let membership = try await repository.joinInvite(code: code)
            guard !closed else { _ = try? await repository.leave(membership.conferenceId); return false }
            var conference = try await repository.read(membership.conferenceId)
            guard !closed else { _ = try? await repository.leave(membership.conferenceId); return false }
            if ["created", "scheduled"].contains(conference.status), conference.ownerId == repository.userID {
                conference = try await repository.transition(conference.id, action: "start")
            }
            guard !closed else { _ = try? await repository.leave(membership.conferenceId); return false }
            install(conference, membership: membership); return true
        } catch { if !closed { self.error = userMessage(error) }; return false }
    }
    @discardableResult
    public func finish(_ conference: Conference) async -> Bool {
        guard !busy, !closed, conference.ownerId == repository.userID,
              ["created", "scheduled", "active"].contains(conference.status) else { return false }
        error = nil
        busy = true; defer { busy = false }
        do {
            _ = try await repository.transition(conference.id, action: ["created", "scheduled"].contains(conference.status) ? "cancel" : "finish")
            if call?.conferenceID == conference.id { await dismissCall() }
            await load()
            return true
        } catch {
            if !closed { self.error = userMessage(error) }
            return false
        }
    }
    private func install(_ conference: Conference, membership: ConferenceParticipant) {
        call = ConferenceSession(repository: repository, title: conference.title, participant: membership,
                                 startedAt: conference.startedAt, invitationCode: conference.inviteCode,
                                 sockets: sockets, makeMedia: makeMedia, makeBroadcast: makeBroadcast)
        call?.observeLobby()
    }
    private func mediaAvailable() -> Bool {
        guard canUseMedia() else {
            error = "Сначала завершите текущий звонок."
            return false
        }
        return true
    }
    public func dismissCall() async {
        guard let previous = call else { return }
        await previous.leave()
        if call?.id == previous.id { departing = previous; call = nil }
    }
    private func completeDeparture() async -> Bool {
        guard let departing else { return !closed }
        guard await departing.awaitDeparture() else {
            error = "Сервер не подтвердил предыдущий выход. Повторный вход пока недоступен."
            return false
        }
        self.departing = nil
        return !closed
    }
    public func close() async {
        closed = true; epoch = UUID()
        hasMore = false; loadingMore = false; nextOffset = 0
        await dismissCall(); meetings = []
    }
}
