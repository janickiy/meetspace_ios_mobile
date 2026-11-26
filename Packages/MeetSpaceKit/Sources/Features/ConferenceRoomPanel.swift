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

struct ConferenceInvitationSheet: View {
    let title: String
    let url: URL
    var demo = false
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(tr("Поделиться встречей")).font(MSTheme.font(20, weight: .semibold, relativeTo: .title2))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 4)
                    Button { dismiss() } label: { WorkspaceIcon("xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel(tr("Закрыть"))
                }
                Text(title).font(MSTheme.font(14)).foregroundStyle(MSTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 22) {
                        invitationLink.frame(idealWidth: 260)
                        qrCode.frame(width: 150)
                    }
                    VStack(spacing: 14) { invitationLink; qrCode }
                }.padding(14).frame(maxWidth: .infinity)
                    .background(ConferenceRoomPanelColors.feed, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MSTheme.line))
                ShareLink(item: url) { Label(tr("Пригласить участников"), systemImage: "envelope") }
                    .buttonStyle(MSButtonStyle())
            }.padding(18).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(MSTheme.surface).presentationDetents([.large])
    }

    private var invitationLink: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Ссылка на встречу")).font(MSTheme.font(15, weight: .semibold))
            Text(tr("Поделитесь ссылкой или отсканируйте QR-код, чтобы присоединиться с другого устройства."))
                .foregroundStyle(MSTheme.muted).fixedSize(horizontal: false, vertical: true)
            Text(url.absoluteString).font(MSTheme.font(12)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(ConferenceRoomPanelColors.card, in: RoundedRectangle(cornerRadius: 10))
            Button(action: copy) {
                Label(tr(copied ? "Скопировано" : "Копировать"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(MSTheme.font(12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(MSButtonStyle(primary: false)).accessibilityIdentifier("conferenceCopyInvitation")
            if demo {
                Text(tr("Адрес демонстрационный.")).foregroundStyle(MSTheme.muted)
            }
        }.font(MSTheme.font(12)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var qrCode: some View {
        MeetingInviteQR(url: url, size: 132)
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
