import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LibraryView: View {
    @Bindable var model: AppModel
    let route: AppRoute
    @State private var query: String = ""
    private let recordings = ["Продукт. Следующая глава", "Дизайн-ревью мобильного приложения", "Планы на октябрь"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if case .recording(let index) = route {
                    Text(tr(recordings[index])).font(MSTheme.font(25, weight: .semibold, relativeTo: .title))
                    cover.largeCover
                    Label("00:00 / 42:18", systemImage: "play.circle").foregroundStyle(MSTheme.muted)
                    FeatureNotice("Видеоплеер будет подключён к серверным записям. Демо не содержит медиафайла.")
                    Text(tr("Участники")).font(MSTheme.font(18, weight: .semibold))
                    HStack { Avatar("АС"); Avatar("АК"); Avatar("МП"); Avatar("ДВ") }
                    FeatureNotice("Расшифровка и ИИ-итоги отсутствуют в текущем API.")
                } else if route == .folders {
                    SearchBox(text: $query, placeholder: "Поиск папок")
                    Text(tr("Всё нужное — вместе")).font(MSTheme.font(24, weight: .semibold, relativeTo: .title))
                    Text(tr("Соберите встречи и чаты по проектам.")).foregroundStyle(MSTheme.muted)
                    ForEach(["Команда продукта", "Запуск продукта", "Личное"].filter { query.isEmpty || tr($0).localizedCaseInsensitiveContains(query) }, id: \.self) { title in
                        Button { model.notice = "Папки объединяют чаты и встречи. Серверные папки будут доступны после входа." } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(MSTheme.accent)
                                Text(tr(title)).font(MSTheme.font(14, weight: .semibold)); Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(MSTheme.muted)
                            }.msCard()
                        }.buttonStyle(.plain)
                    }
                    FeatureNotice("Папки видны только вам. Чаты и встречи могут находиться сразу в нескольких папках.")
                } else {
                    FeatureNotice("Готовые записи хранятся 7 дней. Данные ниже — пример из макетов.")
                    SearchBox(text: $query, placeholder: "Поиск записей")
                    ForEach(recordings.indices, id: \.self) { index in
                        if query.isEmpty || tr(recordings[index]).localizedCaseInsensitiveContains(query) {
                            Button { model.navigate(.recording(index)) } label: {
                                HStack(spacing: 14) {
                                    cover.frame(width: 86, height: 64)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(tr(recordings[index])).font(MSTheme.font(14, weight: .semibold))
                                        Text(tr("15 октября 2026 · 42:18")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                                    }
                                    Spacer(minLength: 0)
                                }.msCard()
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(24).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }.background(MSTheme.background)
    }
    private var cover: some View {
        RoundedRectangle(cornerRadius: 12).fill(MSTheme.accentSoft)
            .overlay { Image(systemName: "play.rectangle").font(.system(size: 28)).foregroundStyle(MSTheme.accent) }
            .accessibilityHidden(true)
    }
}

private extension View {
    var largeCover: some View { self.aspectRatio(16 / 9, contentMode: .fit) }
}
