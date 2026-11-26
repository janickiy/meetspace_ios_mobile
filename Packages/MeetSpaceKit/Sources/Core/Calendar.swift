import Foundation

public enum CalendarDisplayMode: String, Codable, CaseIterable, Sendable { case week, month, list }
public enum ConferenceTimelineView: String, CaseIterable, Sendable { case upcoming, active, past }
public enum ConferenceTimelineScope: String, CaseIterable, Sendable { case all, owned, participating }

public struct ConferenceTimelinePage: Decodable, Sendable {
    public let items: [Conference]
    public let nextCursor: String?
    /// Объединяет встречи одной страницы с курсором продолжения.
    /// - Parameters:
    ///   - items: Встречи, вошедшие в текущую страницу.
    ///   - nextCursor: Курсор следующей страницы, если выдача продолжается.
    public init(items: [Conference], nextCursor: String? = nil) { self.items = items; self.nextCursor = nextCursor }
}

public struct CalendarPreferences: Codable, Equatable, Sendable {
    public var timeZoneIdentifier: String
    public var displayMode: CalendarDisplayMode
    /// Задаёт часовой пояс и режим отображения календаря.
    /// - Parameters:
    ///   - timeZoneIdentifier: Системный идентификатор часового пояса.
    ///   - displayMode: Режим календаря — неделя, месяц или список.
    public init(timeZoneIdentifier: String = TimeZone.current.identifier, displayMode: CalendarDisplayMode = .week) {
        self.timeZoneIdentifier = timeZoneIdentifier; self.displayMode = displayMode
    }
    /// Проверяет, что сохранённый часовой пояс распознаётся системой.
    public func validated() throws -> Self {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw ClientError.invalidInput }
        return self
    }
}

public protocol CalendarPreferencesStore: Sendable {
    /// Возвращает сохранённый часовой пояс и режим календаря.
    func load() async throws -> CalendarPreferences
    /// Сохраняет пользовательские параметры календаря.
    /// - Parameter preferences: Сохраняемые настройки часового пояса и отображения.
    func save(_ preferences: CalendarPreferences) async throws
}

public actor MemoryCalendarPreferencesStore: CalendarPreferencesStore {
    private var value: CalendarPreferences
    /// Создаёт хранилище настроек календаря в памяти.
    /// - Parameter value: Исходные настройки календаря в памяти.
    public init(_ value: CalendarPreferences = CalendarPreferences()) { self.value = value }
    /// Возвращает сохранённый часовой пояс и режим календаря.
    public func load() -> CalendarPreferences { value }
    /// Сохраняет пользовательские параметры календаря.
    /// - Parameter preferences: Сохраняемые настройки часового пояса и отображения.
    public func save(_ preferences: CalendarPreferences) throws { value = try preferences.validated() }
}

/// The server stores an instant, not a wall-clock time or a named timezone.
public enum MeetingCalendar {
    /// Настраивает григорианский календарь с понедельником в начале недели.
    /// - Parameter zone: Часовой пояс отображения календаря.
    public static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone; calendar.locale = Locale(identifier: "ru_RU")
        calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
    /// Возвращает границы недели или месяца, в который входит выбранная дата.
    /// - Parameters:
    ///   - date: Дата, для которой выполняется календарный расчёт.
    ///   - mode: Режим отображения календаря, определяющий длительность периода.
    ///   - zone: Часовой пояс отображения календаря.
    public static func interval(containing date: Date, mode: CalendarDisplayMode, in zone: TimeZone) -> DateInterval {
        let calendar = calendar(in: zone)
        // Calendar arithmetic preserves local midnight on 23/25-hour DST days.
        return calendar.dateInterval(of: mode == .week ? .weekOfYear : .month, for: date)!
    }
    /// Перечисляет дни заданного периода с учётом местного времени.
    /// - Parameters:
    ///   - interval: Период с включённым началом и исключённой верхней границей.
    ///   - zone: Часовой пояс отображения календаря.
    public static func days(in interval: DateInterval, zone: TimeZone) -> [Date] {
        let calendar = calendar(in: zone)
        var values: [Date] = []; var current = interval.start
        while current < interval.end, values.count < 42 {
            values.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current), next > current else { break }
            current = next
        }
        return values
    }
    /// Проверяет принадлежность момента полуоткрытому временному интервалу.
    /// - Parameters:
    ///   - instant: Проверяемый момент времени.
    ///   - interval: Период с включённым началом и исключённой верхней границей.
    public static func includes(_ instant: Date, interval: DateInterval) -> Bool {
        instant >= interval.start && instant < interval.end
    }
    /// Выбирает дату для календаря по завершению, расписанию или созданию встречи.
    /// - Parameter meeting: Встреча, данные которой используются для операции.
    public static func timelineDate(_ meeting: Conference) -> Date {
        meeting.finishedAt ?? meeting.scheduledAt ?? meeting.createdAt
    }
    /// Проверяет, что момент конечен и находится в поддерживаемом диапазоне лет.
    /// - Parameter date: Дата, для которой выполняется календарный расчёт.
    public static func isValidInstant(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 >= -62_135_596_800 && date.timeIntervalSince1970 < 253_402_300_800
    }
    /// Проверяет будущую дату начала встречи и допустимую длительность в минутах.
    /// - Parameters:
    ///   - at: Планируемое время начала встречи.
    ///   - duration: Плановая длительность встречи в минутах, если она задана.
    ///   - now: Момент, относительно которого проверяется дата.
    public static func validateSchedule(at: Date, duration: Int?, now: Date = Date()) throws {
        guard isValidInstant(at), at > now, duration.map({ (1...1440).contains($0) }) ?? true else { throw ClientError.invalidInput }
    }
}
