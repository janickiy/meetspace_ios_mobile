import SwiftUI
import MeetSpaceDesignSystem
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ConferenceRoomPanelTab: CaseIterable {
    case chat, participants
    var title: String { self == .chat ? "Чат" : "Участники" }
}

enum ConferenceRoomPanelColors {
    static let card = MSTheme.surface
    static let feed = Color(light: 0xF4EFF6, dark: 0x24202C)
    static let muted = MSTheme.muted
    static let accent = Color(light: 0x6E477C, dark: 0xD5B2E4)
    static let outgoing = Color(light: 0xF0E6F4, dark: 0x45344E)
}

private extension Color {
    /// Создаёт цвет панели с отдельными значениями для светлой и тёмной темы.
    /// - Parameters:
    ///   - light: Цвет RGB для светлой темы в формате 0xRRGGBB.
    ///   - dark: Цвет RGB для тёмной темы в формате 0xRRGGBB.
    init(light: UInt32, dark: UInt32) {
        #if os(iOS)
        self = Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
        #else
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
        #endif
    }
}

struct ConferenceRoomPanel<Content: View>: View {
    let selected: ConferenceRoomPanelTab
    let participantCount: Int
    let select: (ConferenceRoomPanelTab) -> Void
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        return VStack(spacing: 0) {
            HStack {
                Text(tr(selected == .chat ? "Чат встречи" : "Участники встречи"))
                    .font(MSTheme.font(17, weight: .semibold, relativeTo: .headline))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(selected == .chat ? "conferenceChatHeading" : "conferenceParticipantsHeading")
                Spacer(minLength: 0)
                Button(action: close) { WorkspaceIcon("xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(ConferenceRoomPanelColors.muted)
                    .accessibilityLabel(tr("Закрыть")).accessibilityIdentifier("conferencePanelClose")
            }.padding(.leading, 16).padding(.trailing, 6)
            ScrollView(.horizontal) {
                HStack(spacing: 18) {
                    ForEach(ConferenceRoomPanelTab.allCases, id: \.self) { tab in
                        Button { select(tab) } label: {
                            Text(tab == .participants ? "\(tr(tab.title)) (\(participantCount))" : tr(tab.title))
                                .font(MSTheme.font(13, weight: selected == tab ? .semibold : .regular))
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minHeight: 44).padding(.horizontal, 2)
                                .foregroundStyle(selected == tab ? ConferenceRoomPanelColors.accent : ConferenceRoomPanelColors.muted)
                                .overlay(alignment: .bottom) {
                                    if selected == tab { Capsule().fill(ConferenceRoomPanelColors.accent).frame(height: 2) }
                                }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(selected == tab ? .isSelected : [])
                    }
                }.padding(.horizontal, 16)
            }.fixedSize(horizontal: false, vertical: true).scrollIndicators(.hidden)
            Rectangle().fill(MSTheme.line).frame(height: 1)
            content()
        }.foregroundStyle(MSTheme.ink)
            .background(ConferenceRoomPanelColors.card, in: shape)
            .clipShape(shape).overlay(shape.strokeBorder(MSTheme.line))
    }
}

private enum ConferenceInvitationColors {
    static let surface = Color(light: 0xFFFFFF, dark: 0x25202B)
    static let card = Color(light: 0xF3EFF5, dark: 0x302936)
    static let line = Color(light: 0xE6DFE9, dark: 0x493D50)
    static let ink = Color(light: 0x27222D, dark: 0xF6F0F8)
    static let muted = Color(light: 0x685D70, dark: 0xC4B8CB)
    static let accent = Color(light: 0x693D78, dark: 0xD8B3E6)
    static let accentSoft = Color(light: 0xEEE5F2, dark: 0x46334F)
    static let buttonInk = Color(light: 0xFFFFFF, dark: 0x271A2D)
}

struct ConferenceInvitationSheet: View {
    let title: String
    let url: URL
    var demo = false
    let close: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var copied = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width <= 600
            let inset: CGFloat = compact ? 12 : 20
            let width = min(680, max(0, geometry.size.width - 2 * inset))
            let shape = RoundedRectangle(cornerRadius: 20, style: .circular)
            ZStack {
                Color(red: 21 / 255, green: 16 / 255, blue: 27 / 255).opacity(158 / 255)
                    .ignoresSafeArea().onTapGesture(perform: close).accessibilityHidden(true)
                ViewThatFits(in: .vertical) {
                    contents(compact: compact).fixedSize(horizontal: false, vertical: true)
                    ScrollView { contents(compact: compact) }
                        .scrollBounceBehavior(.basedOnSize)
                }.frame(width: width)
                    .background(ConferenceInvitationColors.surface, in: shape)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(ConferenceInvitationColors.line).allowsHitTesting(false))
                    .shadow(color: .black.opacity(0.15), radius: 26, y: 12)
                    .padding(.vertical, inset)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("conferenceInvitation")
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.foregroundStyle(ConferenceInvitationColors.ink)
            .tint(ConferenceInvitationColors.accent)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, close)
            .onAppear { headingFocused = true }
    }

    /// Собирает заголовок, карточку ссылки с QR-кодом и кнопку отправки приглашения.
    /// - Parameter compact: Использовать ли отступы и одноколоночную компоновку смартфона.
    private func contents(compact: Bool) -> some View {
        let stacked = compact || typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(spacing: 22))
        let card = RoundedRectangle(cornerRadius: 16, style: .circular)
        let qrSize: CGFloat = compact ? 140 : 162
        return VStack(alignment: .leading, spacing: compact ? 14 : 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(tr("Поделиться встречей"))
                        .font(MSTheme.font(compact ? 20 : 25, weight: .semibold, relativeTo: .title2)).bold()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                    Spacer(minLength: 0)
                    Button(action: close) {
                        WorkspaceIcon("xmark", size: 20).frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(ConferenceInvitationColors.muted)
                        .accessibilityLabel(tr("Закрыть")).accessibilityIdentifier("conferenceInviteClose")
                        .padding(.trailing, -8).padding(.vertical, -7)
                }
                Text(verbatim: title).font(MSTheme.font(13)).foregroundStyle(ConferenceInvitationColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            layout {
                invitationLink
                MeetingInviteQR(url: url, size: qrSize, inset: qrSize * 0.12, line: ConferenceInvitationColors.line,
                                muted: ConferenceInvitationColors.muted)
                    .frame(width: stacked ? nil : qrSize)
            }.padding(compact ? 14 : 20).frame(maxWidth: .infinity)
                .background(ConferenceInvitationColors.card, in: card)
                .overlay(card.strokeBorder(ConferenceInvitationColors.line).allowsHitTesting(false))
            VStack(spacing: compact ? 14 : 18) {
                Rectangle().fill(ConferenceInvitationColors.line).frame(height: 1)
                ShareLink(item: url) {
                    HStack(spacing: 8) {
                        WorkspaceIcon("envelope", size: 20)
                        Text(tr("Пригласить участников")).font(MSTheme.font(14, weight: .semibold))
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }.padding(.horizontal, compact ? 10 : 16).padding(.vertical, 8)
                        .frame(maxWidth: compact ? .infinity : nil, minHeight: 44)
                        .foregroundStyle(ConferenceInvitationColors.buttonInk)
                        .background(ConferenceInvitationColors.accent, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityIdentifier("conferenceShareInvitation")
            }
        }.padding(compact ? 18 : 28)
    }

    private var invitationLink: some View {
        let hint = tr("По ссылке можно присоединиться без аккаунта.")
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Ссылка на встречу")).font(MSTheme.font(15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(tr("Поделитесь ссылкой или отсканируйте QR-код, чтобы присоединиться с другого устройства."))
                    .font(MSTheme.font(13)).lineSpacing(4).foregroundStyle(ConferenceInvitationColors.muted)
            }
            copyField
            Text(verbatim: demo ? hint + " " + tr("Адрес демонстрационный.") : hint)
                .font(MSTheme.font(12)).lineSpacing(3).foregroundStyle(ConferenceInvitationColors.muted)
        }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var copyField: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        let shape = RoundedRectangle(cornerRadius: 10, style: .circular)
        return layout {
            Text(verbatim: url.absoluteString).font(MSTheme.font(13)).lineLimit(1).textSelection(.enabled)
                .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(tr("Ссылка на встречу")).accessibilityValue(url.absoluteString)
                .accessibilityIdentifier("conferenceInviteURL")
            Button(action: copy) {
                HStack(spacing: 6) {
                    WorkspaceIcon(copied ? "checkmark" : "doc.on.doc", size: 16)
                    Text(tr(copied ? "Скопировано" : "Копировать")).font(MSTheme.font(12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(minHeight: 44)
                    .foregroundStyle(ConferenceInvitationColors.accent)
                    .background(ConferenceInvitationColors.accentSoft, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).accessibilityIdentifier("conferenceCopyInvitation")
                .layoutPriority(1)
        }.padding(4).background(ConferenceInvitationColors.surface, in: shape)
            .overlay(shape.strokeBorder(ConferenceInvitationColors.line).allowsHitTesting(false))
    }

    /// Копирует ссылку на встречу и сохраняет результат для подтверждения в интерфейсе.
    private func copy() {
        copied = copyMeetingLink(url)
    }
}

struct ConferenceRoomComposer: View {
    @Binding var draft: String
    var disabled = false
    let send: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            TextField(tr("Написать сообщение…"), text: $draft, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.plain).font(MSTheme.font(13))
                .padding(.horizontal, 8).frame(minHeight: 37)
                .accessibilityIdentifier("conferenceChatInput")
            HStack(spacing: 3) {
                Menu {
                    ForEach(["😊", "👍", "❤️", "👏", "🎉"], id: \.self) { emoji in
                        Button(emoji) {
                            if draft.unicodeScalars.count + emoji.unicodeScalars.count <= 4_000 { draft += emoji }
                        }
                    }
                } label: {
                    WorkspaceIcon("face.smiling", size: 18).frame(width: 44, height: 44)
                }.buttonStyle(.plain).menuStyle(.button).menuIndicator(.hidden)
                    .foregroundStyle(ConferenceRoomPanelColors.muted).accessibilityLabel(tr("Добавить эмодзи"))
                Spacer(minLength: 0)
                let canSend = !disabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: send) {
                    WorkspaceIcon("paperplane", size: 17).frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(ConferenceRoomPanelColors.accent, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(!canSend).opacity(canSend ? 1 : 0.45)
                    .accessibilityLabel(tr("Отправить сообщение")).accessibilityIdentifier("conferenceChatSend")
            }
        }.padding(4).background(ConferenceRoomPanelColors.feed, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(MSTheme.line))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(ConferenceRoomPanelColors.card)
            .overlay(alignment: .top) { Rectangle().fill(MSTheme.line).frame(height: 1) }
    }
}

struct ConferenceRoomMessageBubble<Content: View>: View {
    let own: Bool
    let time: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: own ? 14 : 4,
                                           bottomTrailingRadius: own ? 4 : 14, topTrailingRadius: 14)
        VStack(alignment: .trailing, spacing: 5) {
            VStack(alignment: .leading, spacing: 4) { content() }
            Text(time).font(MSTheme.font(10)).foregroundStyle(ConferenceRoomPanelColors.muted)
        }.padding(.horizontal, 11).padding(.vertical, 9)
            .background(own ? ConferenceRoomPanelColors.outgoing : ConferenceRoomPanelColors.card, in: shape)
            .overlay(shape.strokeBorder(MSTheme.line))
            .padding(own ? .leading : .trailing, 10)
            .frame(maxWidth: .infinity, alignment: own ? .trailing : .leading)
    }
}

struct ConferenceRoomPersonLabel: View {
    let name: String
    let initials: String
    let subtitle: String
    let own: Bool

    var body: some View {
        let tone: ConferenceRoomAttendee.Tone = own ? .blue : .mint
        HStack(spacing: 12) {
            Text(initials).font(MSTheme.font(12, weight: .semibold))
                .foregroundStyle(tone.avatarText).frame(width: 36, height: 36)
                .background(tone.avatarBackground, in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(MSTheme.font(13, weight: .semibold))
                Text(subtitle).font(MSTheme.font(11)).foregroundStyle(ConferenceRoomPanelColors.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ConferenceRoomDate: View {
    var date: Date?

    var body: some View {
        if let date {
            Text(Calendar.current.isDateInToday(date) ? tr("Сегодня") : date.formatted(date: .abbreviated, time: .omitted))
                .font(MSTheme.font(11)).foregroundStyle(ConferenceRoomPanelColors.muted)
                .padding(.horizontal, 11).padding(.vertical, 3)
                .background(ConferenceRoomPanelColors.card, in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
        }
    }
}
