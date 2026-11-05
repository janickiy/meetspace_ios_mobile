import SwiftUI
import MeetSpaceCore
import MeetSpaceDesignSystem

struct CallPreviewView: View {
    @Bindable var model: AppModel
    let route: AppRoute
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                FeatureNotice("Просмотр экрана звонка. Камера, микрофон и соединение не включены.")
                if route == .personalCall {
                    Spacer(minLength: 40)
                    Avatar("АК", size: 108)
                    Text(tr("Анна Кузнецова")).font(MSTheme.font(27, weight: .semibold, relativeTo: .title))
                    Text(tr("Предпросмотр звонка")).foregroundStyle(MSTheme.muted)
                    Spacer(minLength: 40)
                } else if route == .prejoin {
                    Text(tr("Дизайн-синхронизация")).font(MSTheme.font(25, weight: .semibold, relativeTo: .title))
                    tile("АС").frame(minHeight: 220)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                        ForEach(["АС", "АК", "МП", "ДВ"], id: \.self) { tile($0).frame(minHeight: 175) }
                    }
                }
                HStack(spacing: 14) {
                    control("mic.slash", "Микрофон выключен")
                    control("video.slash", "Камера выключена")
                    if route != .prejoin { control("rectangle.on.rectangle", "Демонстрация экрана недоступна") }
                    Button { dismiss() } label: {
                        Image(systemName: "phone.down.fill").font(.system(size: 22)).frame(width: 54, height: 48)
                            .foregroundStyle(.white).background(MSTheme.danger, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityLabel(tr("Закрыть предпросмотр"))
                }
                if route == .prejoin {
                    Button(tr("Посмотреть экран встречи")) { model.navigate(.call) }.buttonStyle(MSButtonStyle()).frame(maxWidth: 420)
                }
            }.padding(24).frame(maxWidth: 1080).frame(maxWidth: .infinity)
        }.background(MSTheme.background)
    }
    private func tile(_ initials: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18).fill(MSTheme.surfaceSecondary)
            Avatar(initials, size: 70).frame(maxWidth: .infinity, maxHeight: .infinity)
            Label(tr(initials == "АС" ? "Вы" : "Участник"), systemImage: "mic.slash").font(MSTheme.font(11)).padding(14)
        }
    }
    private func control(_ icon: String, _ label: String) -> some View {
        Image(systemName: icon).font(.system(size: 20)).frame(width: 50, height: 48)
            .background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(MSTheme.muted)
            .accessibilityLabel(tr(label))
    }
}
