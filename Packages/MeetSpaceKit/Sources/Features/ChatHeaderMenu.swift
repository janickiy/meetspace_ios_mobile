import SwiftUI
import MeetSpaceDesignSystem

enum ChatHeaderAction: String, Identifiable {
    case info, selfCard, select, edit, mute, folder, clear, hide, leave

    var id: Self { self }

    /// Возвращает заголовок действия в меню чата.
    /// - Parameter muted: Отключены ли уведомления у чата.
    func title(muted: Bool = false) -> String {
        switch self {
        case .info: "Информация"
        case .selfCard: "Моя карточка"
        case .select: "Выбрать сообщения"
        case .edit: "Редактировать группу"
        case .mute: muted ? "Включить уведомления" : "Без уведомлений"
        case .folder: "Добавить в папку"
        case .clear: "Очистить историю"
        case .hide: "Удалить чат"
        case .leave: "Покинуть группу"
        }
    }

    /// Возвращает имя значка для действия в меню чата.
    /// - Parameter muted: Отключены ли уведомления у чата.
    func symbol(muted: Bool) -> String {
        switch self {
        case .info: "info.circle"
        case .selfCard: "person"
        case .select: "checkmark.circle"
        case .edit: "pencil"
        case .mute: muted ? "bell" : "bell.slash"
        case .folder: "folder.badge.plus"
        case .clear: "eraser"
        case .hide: "trash"
        case .leave: "rectangle.portrait.and.arrow.right"
        }
    }

    var confirmation: String {
        switch self {
        case .hide: "Чат исчезнет из вашего списка. У собеседника переписка сохранится."
        case .clear: "История будет очищена только у вас. У собеседника переписка сохранится."
        case .leave: "Чтобы вернуться в группу, потребуется приглашение."
        default: ""
        }
    }
}

private struct ChatActionAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    /// Сохраняет последнее доступное положение кнопки, к которой привязано меню.
    /// - Parameters:
    ///   - value: Накопленная привязка к границам кнопки.
    ///   - nextValue: Привязка следующего дочернего представления.
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let anchor = nextValue() { value = anchor }
    }
}

struct ChatActionTrigger: View {
    let active: Bool
    let toggle: () -> Void
    @Environment(\.workspaceWidth) private var width

    var body: some View {
        Button(action: toggle) {
            WorkspaceIcon("ellipsis", size: width >= 780 ? 22 : 20)
                .foregroundStyle(active ? MSTheme.brandAccent : MSTheme.ink)
                .frame(width: width >= 780 ? 44 : 34, height: width >= 780 ? 44 : 48)
                .background(active ? MSTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 12))
                .anchorPreference(key: ChatActionAnchor.self, value: .bounds) { $0 }
                .padding(.horizontal, width >= 780 ? 0 : 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, width >= 780 ? 0 : -5)
        .accessibilityLabel(tr("Действия с чатом"))
        .accessibilityIdentifier("chat.menu")
    }
}

extension View {
    /// Показывает меню у кнопки заголовка с действиями, доступными для этого чата.
    /// - Parameters:
    ///   - open: Привязка к видимости меню.
    ///   - group: Открыта ли группа.
    ///   - editable: Разрешено ли редактирование группы.
    ///   - muted: Отключены ли уведомления чата.
    ///   - perform: Обработчик выбранного пункта.
    func chatHeaderMenu(open: Binding<Bool>, group: Bool, editable: Bool = false, muted: Bool,
                        perform: @escaping (ChatHeaderAction) -> Void) -> some View {
        accessibilityHidden(open.wrappedValue)
            .overlayPreferenceValue(ChatActionAnchor.self) { anchor in
                if open.wrappedValue, let anchor {
                    GeometryReader { geometry in
                        let trigger = geometry[anchor]
                        let width = min(280, max(0, geometry.size.width - 32))
                        let top = trigger.maxY + 8
                        let left = min(max(12, trigger.maxX - width), max(12, geometry.size.width - width - 12))
                        let height = max(0, min(360, geometry.size.height * 0.65, geometry.size.height - top - 8))
                        ZStack(alignment: .topLeading) {
                            Color.clear.contentShape(Rectangle()).onTapGesture { open.wrappedValue = false }
                                .accessibilityHidden(true)
                            ChatHeaderMenu(group: group, editable: editable, muted: muted) { action in
                                open.wrappedValue = false
                                perform(action)
                            }
                            .frame(width: width)
                            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(MSTheme.line) }
                            .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                            .frame(maxHeight: height, alignment: .top)
                            .offset(x: left, y: top)
                            .accessibilityAddTraits(.isModal)
                            .accessibilityAction(.escape) { open.wrappedValue = false }
                        }
                    }
                }
            }
    }

    /// Запрашивает подтверждение действия с чатом перед его выполнением.
    /// - Parameters:
    ///   - pending: Действие, ожидающее подтверждения.
    ///   - perform: Обработчик подтверждённого действия.
    func confirmChatAction(_ pending: Binding<ChatHeaderAction?>,
                           perform: @escaping (ChatHeaderAction) -> Void) -> some View {
        sheet(item: pending) { action in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(tr(action.title())).font(MSTheme.font(20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(tr(action.confirmation)).font(MSTheme.font(14)).foregroundStyle(MSTheme.muted)
                    Button(role: .destructive) {
                        pending.wrappedValue = nil
                        perform(action)
                    } label: {
                        Text(tr(action.title())).font(MSTheme.font(14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(.white)
                            .background(MSTheme.danger, in: RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(.plain).accessibilityIdentifier("chat.confirm.apply")
                    Button(tr("Отмена")) { pending.wrappedValue = nil }
                        .buttonStyle(MSButtonStyle(primary: false)).accessibilityIdentifier("chat.confirm.cancel")
                }.padding(20).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }.background(MSTheme.surface).foregroundStyle(MSTheme.ink)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }
}

private struct ChatHeaderMenu: View {
    let group: Bool
    let editable: Bool
    let muted: Bool
    let perform: (ChatHeaderAction) -> Void

    private var actions: [ChatHeaderAction] {
        if group { return [.info, .selfCard, .select] + (editable ? [.edit] : []) + [.folder, .leave] }
        return [.info, .selfCard, .select, .mute, .folder, .clear, .hide]
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            rows.fixedSize(horizontal: false, vertical: true)
            ScrollView { rows }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(actions, id: \.self) { action in
                Button { perform(action) } label: {
                    HStack(spacing: 12) {
                        WorkspaceIcon(action.symbol(muted: muted), size: 20)
                        Text(tr(action.title(muted: muted))).font(MSTheme.font(14)).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(action == .hide || action == .leave ? MSTheme.danger : MSTheme.ink)
                .accessibilityIdentifier(action == .select ? "message.selectMode" : "chat.action.\(action.rawValue)")
            }
        }.padding(8)
    }
}

struct ChatOwnCard: View {
    let name: String
    let email: String
    let bio: String?
    let photo: Data?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("Моя карточка")).font(MSTheme.font(17, weight: .semibold))
                Spacer()
                IconButton("xmark", label: "Закрыть") { dismiss() }
            }.padding(.horizontal, 16).frame(minHeight: 56)
            ScrollView {
                VStack(spacing: 12) {
                    ProfileAvatar(name: name, size: 64, photo: photo)
                    Text(name).font(MSTheme.font(22, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(tr("Вы")).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                    VStack(alignment: .leading, spacing: 12) {
                        field("Имя", name)
                        field("О себе", bio.flatMap { $0.isEmpty ? nil : $0 } ?? tr("Не указано"))
                        field("Email", email)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(MSTheme.background, in: RoundedRectangle(cornerRadius: 16))
                }.padding(16).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
        }.background(MSTheme.surface).presentationDetents([.medium, .large])
    }
    /// Показывает подписанное поле со сведениями о чате.
    /// - Parameters:
    ///   - key: Название поля.
    ///   - value: Отображаемое значение поля.
    private func field(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tr(key)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
            Text(value).font(MSTheme.font(14)).textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }
}
