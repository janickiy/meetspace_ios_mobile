import SwiftUI
import MeetSpaceDesignSystem

struct ChatAvatar: View {
    let name: String
    var initials: String? = nil
    var size: CGFloat = 42
    var group = false
    var listRow = false

    private var colors: (Color, Color) {
        switch name {
        case "Анна Кузнецова": (Color(red: 0.965, green: 0.906, blue: 0.859), Color(red: 0.675, green: 0.455, blue: 0.318))
        case "Максим Петров", "Мария Полякова": (Color(red: 0.871, green: 0.941, blue: 0.914), Color(red: 0.239, green: 0.522, blue: 0.463))
        case "Разработка", "Дмитрий Волков": (Color(red: 0.875, green: 0.910, blue: 1), Color(red: 0.302, green: 0.443, blue: 0.773))
        default: (Color(red: 0.902, green: 0.871, blue: 0.965), Color(red: 0.447, green: 0.325, blue: 0.635))
        }
    }

    var body: some View {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        Text(initials ?? String(letters).uppercased())
            .font(MSTheme.font(listRow ? 18 : size * 0.32, weight: .semibold)).foregroundStyle(colors.1)
            .frame(width: listRow ? 51 : size, height: listRow ? 53 : size)
            .background(colors.0, in: RoundedRectangle(cornerRadius: listRow ? 17 : size * 0.32, style: .circular))
            .overlay(alignment: .bottomTrailing) {
                if group {
                    let shape = RoundedRectangle(cornerRadius: listRow ? 8 : 6, style: .circular)
                    WorkspaceIcon("person.2", size: listRow ? 13 : 11)
                        .foregroundStyle(MSTheme.brandAccent).frame(width: listRow ? 22 : 18, height: listRow ? 22 : 18)
                        .background(MSTheme.accentSoft, in: shape)
                        .overlay { shape.strokeBorder(MSTheme.surface, lineWidth: 2) }.offset(x: 3, y: 3)
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
            .allowsHitTesting(false)
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
                    .accessibilityIdentifier("message.cancelLocalDelete")
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
    var attachments: [String] = []
    var reaction: String?
    var react: ((String) -> Void)?
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
                .accessibilityLabel(([tr("Выбрать сообщение"), author, time, summary] + attachments).joined(separator: ", "))
                .accessibilityValue(tr(selected ? "Выбрано" : "Не выбрано"))
                .accessibilityIdentifier("message.select.\(identifier)")
        } else {
            messageContent.accessibilityIdentifier("message.\(identifier)")
        }
    }

    private var messageContent: some View {
        let wide = width >= 780
        let compactLogWidth = max(0, width - 24)
        let bubbleInset: CGFloat = wide ? 16 : 13
        return HStack(alignment: .top, spacing: wide ? 10 : 7) {
            if own { Spacer(minLength: selecting ? 0 : (wide ? 44 : max(0, compactLogWidth * 0.12 - 7))) }
            else { ChatAvatar(name: author, size: wide ? 30 : 25).padding(.top, 3) }
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    VStack(alignment: .leading, spacing: 5) {
                        if let forwarded {
                            Label("\(tr("Переслано от")) \(forwarded)", systemImage: "arrow.right")
                                .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).allowsHitTesting(false)
                        }
                        if !own {
                            Text(author).font(MSTheme.font(11, weight: .semibold)).foregroundStyle(MSTheme.accent)
                                .frame(minHeight: 18).allowsHitTesting(false)
                        }
                        content().font(MSTheme.font(12))
                    }.frame(minWidth: 100 - 2 * bubbleInset, alignment: .leading)
                }
                GridRow {
                    HStack(spacing: 5) {
                        if pinned { Image(systemName: "pin").accessibilityLabel(tr("Закреплено")) }
                        if edited { Text(tr("изменено")) }
                        Text(time)
                        if own { ChatDeliveryMark().accessibilityLabel(tr("Отправлено")) }
                    }.font(MSTheme.font(9)).foregroundStyle(MSTheme.muted)
                        .fixedSize().gridCellAnchor(.trailing).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, bubbleInset).padding(.top, wide ? 14 : 12).padding(.bottom, 10)
            .modifier(MessageMenuTrigger(enabled: actionable && !selecting, own: own, author: author, time: time, summary: summary,
                                         attachments: attachments, reaction: reaction, react: react, identifier: identifier, actions: actions))
            .background(own ? MSTheme.accentSoft : MSTheme.surface, in: shape)
            .overlay { shape.strokeBorder(own ? .clear : MSTheme.line).allowsHitTesting(false) }
            .padding(.bottom, reaction == nil ? 0 : 34)
            .overlay(alignment: own ? .bottomTrailing : .bottomLeading) {
                if let reaction, let react {
                    Button { react(reaction) } label: {
                        Text("\(reaction) 1").font(MSTheme.font(11))
                            .padding(.horizontal, 9).frame(minHeight: 28)
                            .background(MSTheme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(MSTheme.line))
                            .frame(minWidth: 44, minHeight: 44, alignment: .bottom)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(selecting).accessibilityLabel("\(tr("Снять реакцию")) \(reaction)")
                }
            }
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

func chatGroupSubtitle(_ count: Int) -> String {
    "\(tr("Группа")) · \(chatMemberCount(count))"
}

func chatMemberCount(_ count: Int) -> String {
    let noun: String = switch (count % 100, count % 10) {
    case (11...14, _): "участников"
    case (_, 1): "участник"
    case (_, 2...4): "участника"
    default: "участников"
    }
    return "\(count) \(tr(noun))"
}

struct ChatListRow: View {
    let name: String
    var initials: String?
    var group = false
    var subtitle: String?
    let preview: String
    let time: String
    let unread: Int
    var muted = false
    var selected = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.workspaceWidth) private var width
    var body: some View {
        let wide = width >= 780
        let inset: CGFloat = wide ? 14 : 15
        let shape = RoundedRectangle(cornerRadius: wide ? 14 : 0, style: .circular)
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 10) {
                ChatAvatar(name: name, initials: initials, group: group, listRow: true)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(name).font(MSTheme.font(15, weight: .semibold))
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                        if muted {
                            Image(systemName: "bell.slash").font(.system(size: 12)).foregroundStyle(MSTheme.muted)
                                .accessibilityLabel(tr("Уведомления выключены"))
                        }
                    }.frame(minHeight: 21.75)
                    if let subtitle {
                        Text(subtitle).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted)
                            .frame(minHeight: 15).padding(.top, 1)
                    }
                    Text(preview).font(MSTheme.font(13)).foregroundStyle(MSTheme.muted)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2).lineSpacing(3)
                        .padding(.vertical, 1.25).padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: (group ? 98 : 87) - 2 * inset - 1, alignment: .center)
            VStack(alignment: .trailing, spacing: 10) {
                Text(time).font(MSTheme.font(10)).foregroundStyle(MSTheme.muted).frame(minHeight: 15)
                if unread > 0 {
                    Text("\(unread)").font(MSTheme.font(10, weight: .semibold)).padding(.horizontal, 4)
                        .frame(minWidth: 18, minHeight: 18).foregroundStyle(.white)
                        .background(MSTheme.brandAccent, in: RoundedRectangle(cornerRadius: 7, style: .circular))
                } else if !time.isEmpty {
                    WorkspaceIcon("checkmark.double", size: 14).foregroundStyle(MSTheme.muted.opacity(0.6))
                }
            }.padding(.top, 2).frame(minWidth: wide ? 36 : nil, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)
        }.padding(.horizontal, wide ? 12 : 0).padding(.vertical, inset).padding(.bottom, 1)
            .background {
                shape.fill(MSTheme.line)
                shape.fill(selected ? MSTheme.accentSoft : MSTheme.surface).padding(.bottom, 1)
            }
            .foregroundStyle(MSTheme.ink).contentShape(Rectangle()).accessibilityElement(children: .combine)
            .padding(.leading, wide ? 0 : -1).padding(.trailing, wide ? 1 : 0).padding(.bottom, wide ? 4 : 0)
    }
}

enum ChatFilter: String, CaseIterable { case all = "Все", direct = "Личные", unread = "Новые", groups = "Группы" }

struct ChatFilterBar: View {
    @Binding var filter: ChatFilter
    let unread: String
    let folders: () -> Void
    @Environment(\.workspaceWidth) private var width
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 23) {
                ForEach([ChatFilter.all, .direct, .unread], id: \.self) { value in
                    Button { filter = value } label: {
                        HStack(spacing: 5) {
                            Text(tr(value.rawValue)).font(MSTheme.font(14, weight: .semibold))
                            if value == .unread {
                                Text(unread).font(MSTheme.font(11)).padding(.horizontal, 5).frame(minHeight: 18.5)
                                    .background(MSTheme.surfaceSecondary, in: Capsule()).foregroundStyle(MSTheme.muted)
                            }
                        }.frame(minHeight: 51)
                            .foregroundStyle(filter == value ? MSTheme.ink : MSTheme.muted)
                            .overlay(alignment: .bottom) { if filter == value { Rectangle().fill(MSTheme.brandAccent).frame(height: 3) } }
                    }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
                        .accessibilityIdentifier("messages.filter.\(String(describing: value))")
                }
                Menu {
                    Button(tr("Папки"), systemImage: "folder", action: folders)
                    Button(tr("Группы"), systemImage: "person.2") { filter = .groups }
                } label: {
                    HStack(spacing: 4) {
                        Text(tr(filter == .groups ? "Группы" : "Папки")).font(MSTheme.font(14, weight: .semibold))
                        WorkspaceIcon("chevron.down", size: 13)
                    }.frame(minHeight: 50)
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).foregroundStyle(filter == .groups ? MSTheme.ink : MSTheme.muted)
            }.padding(.horizontal, width >= 780 ? 16 : 17).padding(.bottom, 1)
        }.scrollIndicators(.hidden).overlay(alignment: .bottom) { Rectangle().fill(MSTheme.line).frame(height: 1) }
            .padding(.bottom, width >= 780 ? 16 : 15)
    }
}

struct ChatNewButton: View {
    var compact = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            let layout = compact ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Image(systemName: "plus").font(.system(size: compact ? 23 : 17)).accessibilityHidden(true)
                Text(tr("Новый чат")).font(MSTheme.font(13, weight: .semibold))
            }.padding(.horizontal, 17)
                .frame(minHeight: compact ? 53 : 46).foregroundStyle(scheme == .dark ? MSTheme.background : Color.white)
                .background(MSTheme.accent, in: RoundedRectangle(cornerRadius: compact ? 18 : 15))
                .shadow(color: Color.black.opacity(compact ? 0.12 : 0), radius: 11, y: 6)
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
        Text(tr(selecting ? "Нажмите на сообщения для выбора" : "Нажмите на сообщение, чтобы открыть действия"))
            .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).frame(maxWidth: .infinity)
    }
}

struct ChatInviteCard: View {
    let url: URL
    @State private var hidden = false
    @Environment(\.workspaceWidth) private var width

    var body: some View {
        if !hidden {
            ShareLink(item: url) {
                HStack(spacing: 13) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(tr("Пригласите свою команду")).font(MSTheme.font(14, weight: .semibold)).frame(minHeight: 21)
                        Text(tr("Общайтесь и встречайтесь в MeetSpace")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                            .frame(minHeight: 15.4)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    WorkspaceIcon("person.badge.plus", size: 30).foregroundStyle(MSTheme.brandAccent)
                }.padding(.horizontal, 15).padding(.vertical, 19).frame(minHeight: 84).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("messages.invite")
                .background(MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 18, style: .circular))
                .overlay(alignment: .topTrailing) {
                    Button { hidden = true } label: {
                        WorkspaceIcon("xmark", size: 17).frame(width: 33, height: 33)
                            .background(MSTheme.surface, in: Circle()).frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(tr("Скрыть приглашение")).offset(x: 13.5, y: -13.5)
                }.padding(.leading, width >= 780 ? 0 : -1).padding(.trailing, width >= 780 ? 1 : 0)
                .padding(.bottom, 14)
        }
    }
}
