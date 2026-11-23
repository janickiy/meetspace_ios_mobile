import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct LibraryView: View {
    @Bindable var model: AppModel
    let route: AppRoute
    @State private var query: String = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
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
                    libraryHeading("ЛИЧНОЕ ПРОСТРАНСТВО", title: "Всё нужное — вместе", subtitle: "Соберите встречи и чаты по проектам.")
                    SearchBox(text: $query, placeholder: "Поиск папок")
                    ForEach(["Команда продукта", "Запуск продукта", "Личное"].filter { query.isEmpty || tr($0).localizedCaseInsensitiveContains(query) }, id: \.self) { title in
                        Button { model.notice = "Папки объединяют чаты и встречи. Серверные папки будут доступны после входа." } label: {
                            HStack(spacing: 16) {
                                WorkspaceIcon("folder", size: 25).foregroundStyle(MSTheme.accent)
                                    .frame(width: 48, height: 44)
                                    .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                                Text(tr(title)).font(MSTheme.font(15, weight: .semibold)); Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(MSTheme.muted)
                            }.frame(minHeight: 84).msCard().contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    FeatureNotice("Папки видны только вам. Чаты и встречи могут находиться сразу в нескольких папках.")
                } else {
                    libraryHeading("БИБЛИОТЕКА ВСТРЕЧ", title: "Важное остаётся с вами", subtitle: "Видео, аудио и материалы ваших встреч.")
                    SearchBox(text: $query, placeholder: "Поиск записей")
                    ForEach(recordings.indices, id: \.self) { index in
                        if query.isEmpty || tr(recordings[index]).localizedCaseInsensitiveContains(query) {
                            Button { model.navigate(.recording(index)) } label: {
                                HStack(spacing: 14) {
                                    cover.frame(width: 84, height: 84)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(tr(recordings[index])).font(MSTheme.font(14, weight: .semibold))
                                        Text(tr("15 октября 2026 · 42:18")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                                    }
                                    Spacer(minLength: 0)
                                }.msCard(padding: 10).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    FeatureNotice("Готовые записи хранятся 7 дней. Данные ниже — пример из макетов.")
                }
            }.padding(.horizontal, sizeClass == .compact ? 16 : 24).padding(.vertical, 16)
                .frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }.background(MSTheme.background)
    }
    private func libraryHeading(_ label: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(tr(label)).font(MSTheme.font(10, weight: .semibold)).tracking(1.2).foregroundStyle(MSTheme.accent)
            Text(tr(title)).font(MSTheme.font(24, weight: .semibold, relativeTo: .title2)).accessibilityAddTraits(.isHeader)
            Text(tr(subtitle)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
        }
    }
    private var cover: some View {
        RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.14, green: 0.17, blue: 0.26))
            .overlay { Image(systemName: "play.circle").font(.system(size: 28)).foregroundStyle(.white) }
            .accessibilityHidden(true)
    }
}

private extension View {
    var largeCover: some View { self.aspectRatio(16 / 9, contentMode: .fit) }
}
