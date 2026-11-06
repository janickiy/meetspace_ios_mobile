import Foundation
import Observation
import MeetSpaceCore
import MeetSpaceAPI

@MainActor @Observable public final class CalendarModel {
    public let repository: CalendarRepository
    public private(set) var preferences = CalendarPreferences()
    public private(set) var selectedDay: Date
    public private(set) var scope: ConferenceTimelineScope = .all
    public private(set) var meetings: [Conference] = []
    public private(set) var state: LoadState = .empty
    public private(set) var loading = false
    public private(set) var busy = false
    public private(set) var creationUncertain = false
    public private(set) var feedErrors: [String] = []
    public var error: String?
    @ObservationIgnored private let store: any CalendarPreferencesStore
    @ObservationIgnored private var pages: [ConferenceTimelineView: ConferenceTimelinePage] = [:]
    @ObservationIgnored private var errorsByView: [ConferenceTimelineView: String] = [:]
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var restored = false

    public init(repository: CalendarRepository, preferences: any CalendarPreferencesStore = MemoryCalendarPreferencesStore(), now: Date = Date()) {
        self.repository = repository; store = preferences; selectedDay = now
    }
    public var zone: TimeZone { TimeZone(identifier: preferences.timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)! }
    public var calendar: Calendar { MeetingCalendar.calendar(in: zone) }
    public var interval: DateInterval { MeetingCalendar.interval(containing: selectedDay, mode: preferences.displayMode, in: zone) }
    public var hasMore: Bool { pages.values.contains { $0.nextCursor != nil } }
    public var dayMeetings: [Conference] { meetings.filter { calendar.isDate(MeetingCalendar.timelineDate($0), inSameDayAs: selectedDay) } }
    public func canManage(_ meeting: Conference) -> Bool { meeting.ownerId == repository.userID && meeting.status == "scheduled" }
    public func initialize() async {
        guard !closed else { return }
        if !restored {
            restored = true
            do { let value = try await store.load().validated(); guard !closed else { return }; preferences = value }
            catch { guard !closed else { return }; self.error = "Не удалось восстановить настройки календаря." }
        }
        await load()
    }
    public func selectDay(_ date: Date) async {
        guard !closed, MeetingCalendar.isValidInstant(date) else { return }
        let previous = interval; selectedDay = date
        if previous != interval { await load() }
    }
    public func movePeriod(_ offset: Int) async {
        guard let next = calendar.date(byAdding: preferences.displayMode == .week ? .weekOfYear : .month, value: offset, to: selectedDay) else { return }
        await selectDay(next)
    }
    public func selectScope(_ value: ConferenceTimelineScope) async { guard !closed else { return }; scope = value; await load() }
    public func selectMode(_ mode: CalendarDisplayMode) async {
        guard !closed, preferences.displayMode != mode else { return }
        preferences.displayMode = mode; await savePreferences(); await load()
    }
    public func selectTimeZone(_ identifier: String) async {
        guard !closed, TimeZone(identifier: identifier) != nil, preferences.timeZoneIdentifier != identifier else { return }
        // Keep the selected instant: changing presentation timezone must not move a meeting.
        preferences.timeZoneIdentifier = identifier; await savePreferences(); await load()
    }
    private func savePreferences() async {
        do { try await store.save(preferences) }
        catch { if !closed { self.error = "Не удалось сохранить настройки календаря." } }
    }
    public func load(more: Bool = false) async {
        guard !closed, !more || !loading else { return }
        let generation = UUID(); epoch = generation
        let requestedInterval = interval; let requestedScope = scope; let repository = repository
        let requests = ConferenceTimelineView.allCases.compactMap { view -> (ConferenceTimelineView, String?)? in
            if more { guard let cursor = pages[view]?.nextCursor else { return nil }; return (view, cursor) }
            return (view, nil)
        }
        guard !requests.isEmpty else { return }
        loading = true; if !more { state = .loading; pages = [:]; meetings = []; feedErrors = []; errorsByView = [:] }
        let results = await withTaskGroup(of: (ConferenceTimelineView, Result<ConferenceTimelinePage, Error>).self) { group in
            for (view, cursor) in requests {
                group.addTask {
                    do { return (view, .success(try await repository.timeline(view: view, scope: requestedScope, interval: requestedInterval, cursor: cursor))) }
                    catch { return (view, .failure(error)) }
                }
            }
            var results: [(ConferenceTimelineView, Result<ConferenceTimelinePage, Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
        guard !closed, epoch == generation else { return }
        loading = false
        for (view, result) in results {
            switch result {
            case .success(let page):
                errorsByView[view] = nil
                let previous = more ? pages[view]?.items ?? [] : []
                var merged: [UUID: Conference] = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
                for meeting in page.items { merged[meeting.id] = meeting }
                pages[view] = ConferenceTimelinePage(items: Array(merged.values), nextCursor: page.nextCursor)
            case .failure(let failure): errorsByView[view] = userMessage(failure)
            }
        }
        feedErrors = Array(Set(errorsByView.values)).sorted()
        var all: [UUID: Conference] = [:]
        for page in pages.values {
            for meeting in page.items where all[meeting.id].map({ $0.updatedAt < meeting.updatedAt }) ?? true { all[meeting.id] = meeting }
        }
        meetings = all.values.sorted {
            let a = MeetingCalendar.timelineDate($0), b = MeetingCalendar.timelineDate($1)
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
        state = pages.isEmpty && !feedErrors.isEmpty ? .failed : meetings.isEmpty ? .empty : .content
    }
    public func create(title: String, at: Date, duration: Int?, waitingRoom: Bool) async -> Bool {
        guard !busy, !closed, !creationUncertain else { return false }
        busy = true; error = nil; defer { busy = false }
        do {
            let item = try await repository.create(title: title, at: at, duration: duration, waitingRoom: waitingRoom)
            guard !closed else { return false }
            selectedDay = item.scheduledAt ?? at; await load(); return true
        } catch {
            guard !closed else { return false }
            // There is no creation idempotency key in this server contract.
            switch error {
            case ClientError.invalidInput, ClientError.missingSession, ClientError.sessionExpired, ClientError.accountMismatch: break
            case APIError.httpStatus(let status) where (400...499).contains(status) && status != 408: break
            default: creationUncertain = true
            }
            self.error = creationUncertain ? "Результат создания не подтверждён. Обновите календарь и проверьте список перед повтором." : userMessage(error)
            return false
        }
    }
    public func acknowledgeCreationCheck() { creationUncertain = false; error = nil }
    public func reschedule(_ meeting: Conference, at: Date, duration: Int?) async -> Bool {
        guard !busy, !closed, canManage(meeting) else { return false }
        busy = true; error = nil; defer { busy = false }
        do {
            _ = try await repository.reschedule(meeting.id, at: at, duration: duration)
            guard !closed else { return false }; selectedDay = at; await load(); return true
        } catch { if !closed { self.error = userMessage(error) }; return false }
    }
    public func cancel(_ meeting: Conference) async {
        guard !busy, !closed, canManage(meeting) else { return }
        busy = true; error = nil; defer { busy = false }
        do { _ = try await repository.cancel(meeting.id); guard !closed else { return }; await load() }
        catch { if !closed { self.error = userMessage(error) } }
    }
    public func close() {
        closed = true; epoch = UUID(); pages = [:]; meetings = []; feedErrors = []; errorsByView = [:]; error = nil
        loading = false; state = .empty
    }
}
