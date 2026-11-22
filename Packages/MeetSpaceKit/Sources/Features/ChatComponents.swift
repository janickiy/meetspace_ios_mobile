import SwiftUI
import MeetSpaceDesignSystem

struct ChatAvatar: View {
    let name: String
    var initials: String? = nil
    var size: CGFloat = 42
    var group = false

    private var colors: (Color, Color) {
        switch name {
        case "Анна Кузнецова": (Color(red: 0.97, green: 0.91, blue: 0.86), Color(red: 0.51, green: 0.32, blue: 0.20))
        case "Максим Петров", "Мария Полякова": (Color(red: 0.87, green: 0.94, blue: 0.91), Color(red: 0.17, green: 0.40, blue: 0.34))
        case "Разработка", "Дмитрий Волков": (Color(red: 0.87, green: 0.91, blue: 1), Color(red: 0.24, green: 0.36, blue: 0.62))
        default: (Color(red: 0.90, green: 0.87, blue: 0.96), Color(red: 0.41, green: 0.29, blue: 0.58))
        }
    }

    var body: some View {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        Text(initials ?? String(letters).uppercased())
            .font(MSTheme.font(size * 0.32, weight: .semibold)).foregroundStyle(colors.1)
            .frame(width: size, height: size).background(colors.0, in: RoundedRectangle(cornerRadius: size * 0.32))
            .overlay(alignment: .bottomTrailing) {
                if group {
                    Image(systemName: "person.2.fill").font(.system(size: size * 0.2))
                        .foregroundStyle(.white).padding(3).background(MSTheme.accent, in: Capsule())
                }
            }.accessibilityHidden(true)
    }
}

struct ChatRecipientLabel: View {
    let name: String
    var group = false
    var body: some View {
        HStack(spacing: 11) {
            ChatAvatar(name: name, size: 40, group: group)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(MSTheme.font(13, weight: .semibold))
                Text(tr(group ? "Групповой чат" : "Личный чат")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 14)).foregroundStyle(MSTheme.muted)
        }.padding(.horizontal, 10).frame(minHeight: 62).contentShape(Rectangle()).foregroundStyle(MSTheme.ink)
    }
}

struct ChatHeaderIcon: View {
    let name: String
    @Environment(\.workspaceWidth) private var width

    var body: some View {
        WorkspaceIcon(name, size: width >= 780 ? 22 : 20)
            .foregroundStyle(name == "phone" ? MSTheme.brandAccent : MSTheme.ink)
            .frame(width: width >= 780 ? 44 : 34, height: 48)
            .background(name == "phone" ? MSTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
    }
}

struct ChatSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white).frame(width: 48, height: 48)
            .background(MSTheme.brandAccent, in: RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.42)
    }
}

struct ChatMessageText: View {
    let text: String
    var body: some View {
        Text(text).font(MSTheme.font(12)).lineSpacing(5).padding(.vertical, 2.5)
    }
}

struct ChatFileCard: View {
    let name: String
    let size: String
    var body: some View {
        HStack(spacing: 9) {
            WorkspaceIcon("doc.text", size: 23).foregroundStyle(MSTheme.brandAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(MSTheme.font(11, weight: .semibold))
                Text(size).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
            }
            Spacer(minLength: 0)
            WorkspaceIcon("arrow.down.to.line", size: 18).frame(width: 33, height: 33)
        }.padding(10).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(MSTheme.line) }
    }
}

struct ChatSelectionHeader: View {
    let count: Int
    let allSelected: Bool
    let cancel: () -> Void
    let toggleAll: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            IconButton("xmark", label: "Отменить выбор сообщений", action: cancel)
                .accessibilityIdentifier("message.cancelSelection")
            VStack(alignment: .leading, spacing: 3) {
                Text("\(tr("Выбрано")): \(count)").font(MSTheme.font(15, weight: .semibold)).monospacedDigit()
                    .accessibilityIdentifier("message.selectionCount")
                Text(tr("Выберите сообщения")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
            }
            Spacer(minLength: 0)
            Button(tr(allSelected ? "Снять выбор" : "Выбрать все"), action: toggleAll)
                .buttonStyle(MSTextButtonStyle()).font(MSTheme.font(12, weight: .semibold))
                .accessibilityIdentifier("message.selectAll")
        }.padding(.horizontal, 12).frame(minHeight: 72).background(MSTheme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(MSTheme.line).frame(height: 1) }
    }
}

struct ChatSelectionBar<Share: View>: View {
    let count: Int
    let remove: () -> Void
    @ViewBuilder var share: () -> Share
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { countLabel; Spacer(minLength: 0); share(); deleteButton }
            VStack(spacing: 6) { HStack { countLabel; Spacer(); share() }; deleteButton }
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 76)
            .background(MSTheme.surface).overlay(alignment: .top) { Rectangle().fill(MSTheme.line).frame(height: 1) }
    }
    private var countLabel: some View {
        Text("\(tr("Выбрано")): \(count)").font(MSTheme.font(12)).monospacedDigit().foregroundStyle(MSTheme.muted)
    }
    private var deleteButton: some View {
        Button(role: .destructive, action: remove) {
            Label("\(tr("Удалить")) (\(count))", systemImage: "trash")
                .font(MSTheme.font(13, weight: .semibold)).frame(minHeight: 46).padding(.horizontal, 16)
                .foregroundStyle(.white).background(MSTheme.danger, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain).disabled(count == 0).opacity(count == 0 ? 0.45 : 1)
            .accessibilityIdentifier("message.deleteSelected")
    }
}

struct ChatDeleteConfirmation: View {
    let count: Int
    var busy = false
    var error: String?
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text(tr("Удалить выбранные сообщения?")).font(MSTheme.font(20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    IconButton("xmark", label: "Закрыть", action: cancel)
                }
                Text("\(tr("Выбрано сообщений")): \(count).")
                Text(tr("Сообщения будут удалены из вашей истории на этом устройстве. У других участников они останутся."))
                    .foregroundStyle(MSTheme.muted)
                if let error { Text(tr(error)).foregroundStyle(MSTheme.danger) }
                if busy { ProgressView() }
                Button(role: .destructive, action: confirm) {
                    Label("\(tr("Удалить у меня")) (\(count))", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(.white)
                        .background(MSTheme.danger, in: RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(.plain).disabled(count == 0).accessibilityIdentifier("message.confirmLocalDelete")
                Button(tr("Отмена"), action: cancel).buttonStyle(MSButtonStyle(primary: false))
            }.padding(20).font(MSTheme.font(14)).foregroundStyle(MSTheme.ink)
        }.background(MSTheme.surface).disabled(busy).interactiveDismissDisabled(busy)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

/// The entire row toggles selection. Embedded file and action controls are inert in selection mode.
struct ChatMessageRow<Content: View, Actions: View>: View {
    let own: Bool
    let author: String
    let time: String
    let selecting: Bool
    let selected: Bool
    var actionable = true
    var pinned = false
    var edited = false
    var forwarded: String?
    let identifier: String
    let summary: String
    let toggle: () -> Void
    @Environment(\.workspaceWidth) private var width
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        if selecting && actionable {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    messageContent.allowsHitTesting(false)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24)).foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
                        .frame(width: 44, height: 44)
                }.padding(.horizontal, 3).padding(.vertical, 7).contentShape(Rectangle())
                    .background(selected ? MSTheme.accentSoft.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 15))
                    .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(selected ? MSTheme.accent.opacity(0.28) : .clear) }
            }.buttonStyle(.plain).accessibilityElement(children: .combine)
                .accessibilityLabel("\(tr("Выбрать сообщение")), \(author), \(time), \(summary)")
                .accessibilityValue(tr(selected ? "Выбрано" : "Не выбрано"))
                .accessibilityIdentifier("message.select.\(identifier)")
        } else {
            messageContent.accessibilityIdentifier("message.\(identifier)")
        }
    }

    private var messageContent: some View {
        let wide = width >= 780
        let compactLogWidth = max(0, width - 24)
        return HStack(alignment: .top, spacing: wide ? 10 : 7) {
            if own { Spacer(minLength: selecting ? 0 : (wide ? 44 : max(0, compactLogWidth * 0.12 - 7))) }
            else { ChatAvatar(name: author, size: wide ? 30 : 25).padding(.top, 3) }
            VStack(alignment: .leading, spacing: 5) {
                if let forwarded {
                    Label("\(tr("Переслано от")) \(forwarded)", systemImage: "arrow.right")
                        .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                }
                if !own { Text(author).font(MSTheme.font(11, weight: .semibold)).foregroundStyle(MSTheme.accent).frame(minHeight: 18) }
                content().font(MSTheme.font(12))
            }
            .padding(.horizontal, wide ? 16 : 13).padding(.top, wide ? 14 : 12).padding(.bottom, wide ? 37 : 35)
            .frame(minWidth: 100, alignment: .leading)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 5) {
                    if pinned { Image(systemName: "pin").accessibilityLabel(tr("Закреплено")) }
                    if edited { Text(tr("изменено")) }
                    Text(time)
                    if own { ChatDeliveryMark().accessibilityLabel(tr("Отправлено")) }
                }.font(MSTheme.font(9)).foregroundStyle(MSTheme.muted).padding(.trailing, 12).padding(.bottom, 10)
            }
            .background(own ? MSTheme.accentSoft : MSTheme.surface, in: shape)
            .overlay { shape.strokeBorder(own ? .clear : MSTheme.line) }
            .modifier(MessageMenuTrigger(enabled: actionable && !selecting, own: own, author: author, time: time, summary: summary,
                                         identifier: identifier, wide: wide, actions: actions))
            .frame(maxWidth: wide ? 500 : nil, alignment: own ? .trailing : .leading)
            if !own { Spacer(minLength: selecting ? 0 : (wide ? 22 : max(0, compactLogWidth * 0.06 - 7))) }
        }.foregroundStyle(MSTheme.ink)
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: own ? 17 : 4,
                               bottomTrailingRadius: own ? 4 : 17, topTrailingRadius: 17)
    }
}

struct ChatPinnedBar: View {
    let preview: String
    let count: Int
    let jump: () -> Void
    var body: some View {
        Button(action: jump) {
            HStack(spacing: 11) {
                Image(systemName: "pin")
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Закреплённое сообщение")).font(MSTheme.font(11, weight: .semibold))
                    Text(preview).font(MSTheme.font(11)).lineLimit(1)
                }
                Spacer()
                Text("\(count)").font(MSTheme.font(12))
                Image(systemName: "chevron.right").font(.caption)
            }.padding(.horizontal, 16).frame(minHeight: 61).foregroundStyle(MSTheme.accent)
                .background(MSTheme.accentSoft).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct ChatDeliveryMark: View {
    var body: some View {
        ZStack {
            Image(systemName: "checkmark").offset(x: -2)
            Image(systemName: "checkmark").offset(x: 2)
        }.frame(width: 15)
    }
}

struct ChatListRow: View {
    let name: String
    var initials: String?
    var group = false
    var subtitle: String?
    let preview: String
    let time: String
    let unread: Int
    var selected = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.workspaceWidth) private var width
    var body: some View {
        HStack(spacing: 10) {
            ChatAvatar(name: name, initials: initials, size: 51, group: group)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(MSTheme.font(15, weight: .semibold))
                if let subtitle { Text(subtitle).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted) }
                Text(preview).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 8) {
                Text(time).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
                if unread > 0 {
                    Text("\(unread)").font(MSTheme.font(10, weight: .semibold)).padding(.horizontal, 5).frame(minHeight: 18)
                        .foregroundStyle(.white).background(MSTheme.accent, in: Capsule())
                } else if !time.isEmpty {
                    ChatDeliveryMark().font(.system(size: 9)).foregroundStyle(MSTheme.muted).accessibilityHidden(true)
                }
            }
        }.padding(.horizontal, width >= 780 ? 12 : 0).padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: group ? 98 : 87).background(selected ? MSTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .bottom) { Rectangle().fill(MSTheme.line).frame(height: 1) }.foregroundStyle(MSTheme.ink).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

enum ChatFilter: String, CaseIterable { case all = "Все", direct = "Личные", unread = "Новые", groups = "Группы" }

struct ChatFilterBar: View {
    @Binding var filter: ChatFilter
    var unread: Int?
    let folders: () -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 22) {
                ForEach([ChatFilter.all, .direct, .unread], id: \.self) { value in
                    Button { filter = value } label: {
                        HStack(spacing: 4) {
                            Text(tr(value.rawValue)).font(MSTheme.font(14, weight: .semibold))
                            if value == .unread, let unread {
                                Text("\(unread)").font(MSTheme.font(11)).padding(.horizontal, 5)
                                    .background(MSTheme.surfaceSecondary, in: Capsule()).foregroundStyle(MSTheme.muted)
                            }
                        }.frame(minHeight: 50)
                            .foregroundStyle(filter == value ? MSTheme.ink : MSTheme.muted)
                            .overlay(alignment: .bottom) { if filter == value { Rectangle().fill(MSTheme.accent).frame(height: 3) } }
                    }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
                }
                Menu {
                    Button(tr("Папки"), systemImage: "folder", action: folders)
                    Button(tr("Группы"), systemImage: "person.2") { filter = .groups }
                } label: {
                    HStack(spacing: 4) {
                        Text(tr(filter == .groups ? "Группы" : "Папки")).font(MSTheme.font(14, weight: .semibold))
                        Image(systemName: "chevron.down").font(.caption)
                    }.frame(minHeight: 50)
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).foregroundStyle(filter == .groups ? MSTheme.ink : MSTheme.muted)
            }.padding(.horizontal, 16)
        }.scrollIndicators(.hidden).overlay(alignment: .bottom) { Rectangle().fill(MSTheme.line).frame(height: 1) }
    }
}

struct ChatNewButton: View {
    var compact = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            let layout = compact ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Image(systemName: "plus").font(.system(size: compact ? 20 : 17))
                Text(tr("Новый чат")).font(MSTheme.font(13, weight: .semibold))
            }.padding(.horizontal, 17)
                .frame(minHeight: compact ? 53 : 46).foregroundStyle(.white)
                .background(MSTheme.accent, in: RoundedRectangle(cornerRadius: compact ? 18 : 15))
        }.buttonStyle(.plain).accessibilityIdentifier("newChat")
    }
}

struct ChatThreadHeading<Actions: View>: View {
    let name: String
    var initials: String?
    var subtitle: String?
    var group = false
    var back: (() -> Void)?
    let info: () -> Void
    @Environment(\.workspaceWidth) private var width
    @ViewBuilder let actions: () -> Actions
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if let back { Button(action: back) { ChatHeaderIcon(name: "arrow.left") }.buttonStyle(.plain).accessibilityLabel(tr("Назад к чатам")).accessibilityIdentifier("chat.back") }
                Button(action: info) {
                    HStack(spacing: width >= 780 ? 8 : 6) {
                        ChatAvatar(name: name, initials: initials, size: width >= 780 ? 42 : 32, group: group)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(MSTheme.font(width >= 780 ? 14 : 13, weight: .semibold)).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            if let subtitle { Text(subtitle).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted) }
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("chat.info")
                if !typeSize.isAccessibilitySize { actions() }
            }
            if typeSize.isAccessibilitySize { HStack { Spacer(); actions() } }
        }.padding(.horizontal, width >= 780 ? 24 : 12).padding(.vertical, 8).frame(minHeight: 73)
            .background(MSTheme.surface).overlay(alignment: .bottom) { Rectangle().fill(MSTheme.line).frame(height: 1) }
    }
}

struct ForwardPreview: View {
    let author: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(author).font(MSTheme.font(11, weight: .semibold)).foregroundStyle(MSTheme.muted)
            Text(text).font(MSTheme.font(12)).lineLimit(4)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(MSTheme.background, in: RoundedRectangle(cornerRadius: 13))
    }
}

struct ChatGestureHint: View {
    let selecting: Bool
    var body: some View {
        Text(tr(selecting ? "Нажмите на сообщения для выбора" : "Удерживайте сообщение, чтобы открыть действия"))
            .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).frame(maxWidth: .infinity)
    }
}

struct ChatInviteCard: View {
    let url: URL
    @State private var hidden = false
    var body: some View {
        if !hidden {
            HStack(spacing: 6) {
                ShareLink(item: url) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tr("Пригласите свою команду")).font(MSTheme.font(14, weight: .semibold))
                            Text(tr("Общайтесь и встречайтесь в MeetSpace")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                        }
                        Spacer()
                        Image(systemName: "person.badge.plus").font(.system(size: 25)).foregroundStyle(MSTheme.accent)
                    }.frame(minHeight: 70).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.padding(.horizontal, 15).frame(minHeight: 84)
                .background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .topTrailing) {
                    Button { hidden = true } label: {
                        Image(systemName: "xmark").font(.system(size: 14)).frame(width: 28, height: 28)
                            .background(MSTheme.surface, in: Circle()).frame(width: 40, height: 40)
                    }.buttonStyle(.plain).accessibilityLabel(tr("Скрыть приглашение")).offset(x: 8, y: -8)
                }
                .padding(.top, 15).padding(.bottom, 14)
        }
    }
}
