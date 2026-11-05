import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

/// Fixtures are reachable only after explicit entry into the demo workspace.
enum DemoData {
    struct Meeting: Identifiable {
        let id: Int; let title: String; let day: String; let month: String; let time: String; let count: Int
        var status = 0
        var owner = "Анна Кузнецова"
    }
    static let meetings = [
        Meeting(id: 1, title: "Дизайн-синхронизация", day: "12", month: "ОКТ", time: "10:00 – 10:45", count: 5),
        Meeting(id: 2, title: "Обсуждение новой версии", day: "12", month: "ОКТ", time: "13:30 – 14:00", count: 8, owner: "Вы"),
        Meeting(id: 3, title: "Планы на неделю", day: "13", month: "ОКТ", time: "11:00 – 11:30", count: 4, owner: "Вы"),
        Meeting(id: 4, title: "Рабочая встреча разработки", day: "12", month: "ОКТ", time: "09:30 – 10:30", count: 3, status: 1, owner: "Максим Петров"),
        Meeting(id: 5, title: "Продукт. Следующая глава", day: "09", month: "ОКТ", time: "14:00 – 14:45", count: 6, status: 2, owner: "Вы"),
        Meeting(id: 6, title: "Демо новой версии", day: "08", month: "ОКТ", time: "11:00 – 12:00", count: 8, status: 2)
    ]
    static let people = [("Анна Кузнецова", "АК", "Да, до встречи!"),
                         ("Команда продукта", "П", "Мария: собрала всё в одном файле"),
                         ("Максим Петров", "МП", "Вы: Спасибо, посмотрю сегодня")]
}

struct MeetingsView: View {
    @Bindable var model: AppModel
    @State private var query: String = ""
    @State private var selection: Int = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700 && !typeSize.isAccessibilitySize
            VStack(spacing: 0) {
                PageHeader(title: "Встречи") {
                    IconButton("calendar", label: "Календарь") { model.navigate(.calendar) }
                    IconButton("bell", label: "Уведомления") { model.navigate(.notificationSettings) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        LazyVGrid(columns: wide ? Array(repeating: GridItem(.flexible()), count: 3) : [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 250 : 145))], spacing: 10) {
                            action("Новая встреча", "video.badge.plus", primary: true, route: .newMeeting)
                            action("Запланировать", "calendar.badge.plus", primary: false, route: .scheduleMeeting)
                            if wide { action("По ссылке", "link", primary: false, route: .joinMeeting) }
                        }
                        HStack(spacing: 10) {
                            shortcut("Записи встреч", "play.rectangle", .recordings)
                            shortcut("Папки", "folder", .folders)
                        }
                        HStack {
                            Text(tr("Мои встречи")).font(MSTheme.font(19, weight: .semibold, relativeTo: .title2))
                            Spacer()
                            if !wide { Button(tr("По ссылке")) { model.navigate(.joinMeeting) }.font(MSTheme.font(12)).frame(minHeight: 44) }
                        }
                        SearchBox(text: $query, placeholder: "Поиск встреч")
                        Picker(tr("Статус встречи"), selection: $selection) {
                            Text(tr("Предстоящие")).tag(0); Text(tr("Активные")).tag(1); Text(tr("Завершённые")).tag(2)
                        }.pickerStyle(.segmented).labelsHidden()
                        StateContent(state: model.contentState, retry: { model.contentState = .content }) {
                            let filtered = DemoData.meetings.filter { $0.status == selection && (query.isEmpty || tr($0.title).localizedCaseInsensitiveContains(query)) }
                                if filtered.isEmpty { StateContent(state: .empty, retry: {}) { EmptyView() } }
                                ForEach(filtered) { meeting in
                                    Button { model.navigate(.meetingDetails(meeting.id)) } label: { MeetingRow(meeting: meeting, wide: wide) }
                                        .buttonStyle(.plain).accessibilityIdentifier("meeting.\(meeting.id)")
                                }
                        }
                    }.padding(wide ? 28 : 20).frame(maxWidth: 1120).frame(maxWidth: .infinity)
                }.background(MSTheme.background)
            }
        }.toolbar(.hidden).accessibilityIdentifier("screen.meetings")
    }
    private func action(_ title: String, _ icon: String, primary: Bool, route: AppRoute) -> some View {
        Button { model.navigate(route) } label: {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: icon).font(.system(size: 24))
                Text(tr(title)).font(MSTheme.font(14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 80, alignment: .leading).padding(18)
                .foregroundStyle(primary ? MSTheme.surface : MSTheme.ink)
                .background(primary ? MSTheme.accent : MSTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private func shortcut(_ title: String, _ icon: String, _ route: AppRoute) -> some View {
        Button { model.navigate(route) } label: {
            Label(tr(title), systemImage: icon).font(MSTheme.font(12, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 8).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).foregroundStyle(MSTheme.accent)
    }
}

private struct MeetingRow: View {
    let meeting: DemoData.Meeting
    let wide: Bool
    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 3) {
                Text(meeting.day).font(MSTheme.font(23, weight: .semibold, relativeTo: .title2))
                Text(tr(meeting.month)).font(MSTheme.font(9, weight: .semibold, relativeTo: .caption))
            }.foregroundStyle(MSTheme.accent).padding(10).background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 7) {
                Text(tr(meeting.title)).font(MSTheme.font(14, weight: .semibold)).foregroundStyle(MSTheme.ink)
                Text(meeting.time).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                if !wide { Label("\(meeting.count)", systemImage: "person.2").font(MSTheme.font(11)).foregroundStyle(MSTheme.muted) }
            }
            Spacer(minLength: 0)
            if wide { Label("\(meeting.count)", systemImage: "person.2").font(MSTheme.font(12)).foregroundStyle(MSTheme.muted) }
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(MSTheme.muted)
        }.msCard().accessibilityElement(children: .combine)
    }
}
