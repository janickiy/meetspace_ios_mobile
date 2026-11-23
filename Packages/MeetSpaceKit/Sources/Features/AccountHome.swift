import SwiftUI
import ImageIO
import MeetSpaceDesignSystem

struct ProfileAvatar: View {
    let name: String
    let size: CGFloat
    var cornerRadius: CGFloat?
    var photo: Data?
    var body: some View {
        let initials = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        Group {
            if let photo, let source = CGImageSourceCreateWithData(photo as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(128, Int(size * 3))
               ] as CFDictionary) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else { Text(String(initials).uppercased()) }
        }.font(MSTheme.font(size * 0.36, weight: .semibold))
            .foregroundStyle(MSTheme.accent).frame(width: size, height: size)
            .background(MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: cornerRadius ?? size / 2))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size / 2)).accessibilityHidden(true)
    }
}

enum ProfileSection: String, CaseIterable {
    case profile, accounts, audio, video, notifications, appearance, connection

    var label: (title: String, hint: String, symbol: String) {
        switch self {
        case .profile: ("Профиль", "Имя и данные аккаунта", "person")
        case .accounts: ("Аккаунты", "Добавление и переключение", "person.2")
        case .audio: ("Аудио", "Микрофон, динамик и звук", "mic")
        case .video: ("Видео", "Камера и участники", "video")
        case .notifications: ("Уведомления", "События и каналы доставки", "bell")
        case .appearance: ("Оформление", "Тема и размер текста", "paintpalette")
        case .connection: ("Подключение", "", "server.rack")
        }
    }
}

struct AccountHome<Detail: View>: View {
    let name: String
    let email: String
    let server: String
    let demo: Bool
    var photo: Data?
    var sections = ProfileSection.allCases.filter { $0 != .connection }
    let logout: () -> Void
    @ViewBuilder var detail: (ProfileSection, Bool) -> Detail
    @State private var selection: ProfileSection?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let wide = width >= 780 && !typeSize.isAccessibilitySize
            let menuInset: CGFloat = wide ? (width >= 1100 ? 18 : 14) : (width <= 360 ? 16 : 20)
            let panel = UnevenRoundedRectangle(topLeadingRadius: wide ? 25 : 0, topTrailingRadius: wide ? 25 : 0)
            VStack(spacing: 0) {
                PageHeader(title: "Настройки аккаунта") { EmptyView() }
                HStack(spacing: 0) {
                    if wide || selection == nil {
                        menu(wide: wide, inset: menuInset)
                            .frame(width: wide ? (width >= 1100 ? 270 : 240) : nil)
                    }
                    if wide { Rectangle().fill(MSTheme.line).frame(width: 1).accessibilityHidden(true) }
                    if wide || selection != nil {
                        detailPanel(wide: wide, inset: menuInset)
                    }
                }
                .clipShape(panel)
                .overlay { if wide { panel.strokeBorder(MSTheme.line).allowsHitTesting(false) } }
                .padding(.horizontal, wide ? 24 : 0)
            }
        }.background(MSTheme.background)
            .accessibilityElement(children: .contain).accessibilityIdentifier("screen.profile")
    }

    private func detailPanel(wide: Bool, inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !wide {
                Button { selection = nil } label: {
                    HStack(spacing: 8) {
                        WorkspaceIcon("arrow.left", size: 19)
                        Text(tr("Все настройки")).fixedSize(horizontal: false, vertical: true)
                    }.font(MSTheme.font(13)).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(MSTheme.accent)
                    .accessibilityLabel(tr("Все настройки"))
                    .accessibilityIdentifier("profileMenu.back")
                    .padding(.horizontal, inset).padding(.top, 18).padding(.bottom, 4)
            }
            detail(selection ?? .profile, wide)
                .id(selection ?? .profile)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.background(MSTheme.background)
    }

    private func menu(wide: Bool, inset: CGFloat) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    identity(wide: wide)
                    Text(tr("Настройки аккаунта").uppercased()).font(MSTheme.font(wide ? 9 : 10, weight: .semibold))
                        .tracking(1.3).foregroundStyle(MSTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, wide ? 12 : 0).padding(.bottom, 10)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 5) {
                        ForEach(sections, id: \.self) { section in
                            sectionRow(section, wide: wide)
                        }
                    }
                    if wide {
                        Spacer(minLength: 40)
                        footer(wide: true)
                    } else {
                        footer(wide: false).padding(.top, 26)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, inset).padding(.top, wide ? 26 : 24).padding(.bottom, 20)
                    .frame(minHeight: wide ? geometry.size.height : nil, alignment: .topLeading)
            }
        }.background(wide ? MSTheme.background.opacity(0.65) : MSTheme.surface)
            .background(MSTheme.surface)
    }

    private func identity(wide: Bool) -> some View {
        Button { selection = .accounts } label: {
            HStack(spacing: wide ? 10 : 14) {
                ProfileAvatar(name: name, size: wide ? 42 : 54, cornerRadius: wide ? 14 : 18, photo: photo)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(MSTheme.font(wide ? 13 : 16, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(email).font(MSTheme.font(wide ? 11 : 13)).foregroundStyle(MSTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                WorkspaceIcon("chevron.down", size: 18).foregroundStyle(MSTheme.muted)
            }.padding(.horizontal, wide ? 7 : 0)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(tr("Сменить аккаунт")).accessibilityValue("\(name), \(email)")
            .accessibilityIdentifier("profileMenu.identity")
            .padding(.bottom, wide ? 30 : 26)
    }

    private func sectionRow(_ section: ProfileSection, wide: Bool) -> some View {
        let label = section.label
        let selected = wide && (selection ?? .profile) == section
        return Button { selection = section } label: {
            HStack(spacing: wide ? 12 : 13) {
                WorkspaceIcon(label.symbol, size: 21)
                    .foregroundStyle(wide ? (selected ? MSTheme.accent : MSTheme.muted) : MSTheme.accent)
                    .frame(width: wide ? 22 : 40, height: wide ? 25 : 40)
                    .background(wide ? Color.clear : MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr(label.title)).font(MSTheme.font(wide ? 13 : 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !wide {
                        Text(tr(label.hint)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.layoutPriority(1)
                Spacer(minLength: 0)
                if !wide { WorkspaceIcon("chevron.right", size: 17).foregroundStyle(MSTheme.muted) }
            }
            .foregroundStyle(selected ? MSTheme.accent : MSTheme.ink)
            .padding(.vertical, wide ? 13 : 14).padding(.horizontal, wide ? 12 : 0)
            .frame(minHeight: wide ? 52 : 69).contentShape([.interaction, .accessibility], Rectangle())
            .background(selected ? MSTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(MSTheme.accent).frame(width: 3) }
            }
            .clipShape(RoundedRectangle(cornerRadius: wide ? 10 : 0))
            .overlay(alignment: .bottom) {
                if !wide { Rectangle().fill(MSTheme.line).frame(height: 1).allowsHitTesting(false) }
            }
        }.buttonStyle(.plain)
            .accessibilityLabel(tr(label.title)).accessibilityHint(tr(label.hint))
            .accessibilityIdentifier("profileMenu.\(section.rawValue)")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func footer(wide: Bool) -> some View {
        VStack(spacing: 0) {
            connection(wide: wide)
            Button(action: logout) {
                HStack(spacing: 10) {
                    WorkspaceIcon("rectangle.portrait.and.arrow.right", size: 18)
                    Text(tr(demo ? "Выйти из демо" : "Выйти из аккаунта"))
                        .fixedSize(horizontal: false, vertical: true)
                }.font(MSTheme.font(13)).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(MSTheme.muted).padding(.top, 12)
                .accessibilityIdentifier(demo ? "exitDemo" : "account.logout")
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                Text(verbatim: String(format: tr("Версия %@ · сборка %@"), version, build))
                    .font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                    .multilineTextAlignment(.center).padding(.top, 12)
                    .accessibilityIdentifier("account.version")
            }
        }
    }

    private func connection(wide: Bool) -> some View {
        let selected = wide && selection == .connection
        return Button { selection = .connection } label: {
            HStack(spacing: 11) {
                WorkspaceIcon("server.rack", size: 20).foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Подключение")).font(MSTheme.font(wide ? 11 : 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(server).font(MSTheme.font(wide ? 10 : 11)).foregroundStyle(MSTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                WorkspaceIcon("chevron.right", size: 16).foregroundStyle(selected ? MSTheme.accent : MSTheme.muted)
            }.padding(.vertical, wide ? 12 : 14).padding(.horizontal, wide ? 6 : 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .foregroundStyle(selected ? MSTheme.accent : MSTheme.ink)
                .background(selected ? MSTheme.accentSoft : wide ? .clear : MSTheme.background, in: RoundedRectangle(cornerRadius: 15))
                .overlay { if !wide { RoundedRectangle(cornerRadius: 15).strokeBorder(MSTheme.line).allowsHitTesting(false) } }
                .contentShape([.interaction, .accessibility], Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(tr("Подключение")).accessibilityValue(server)
            .accessibilityIdentifier("profileMenu.connection")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AccountShortcutRow: View {
    let title: String
    let symbol: String
    let identifier: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: 11) {
                WorkspaceIcon(symbol, size: 18)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(destructive ? MSTheme.danger : MSTheme.accent)
                    .background(destructive ? MSTheme.surfaceSecondary : MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                Text(tr(title)).font(MSTheme.font(13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                WorkspaceIcon("chevron.right", size: 15).foregroundStyle(MSTheme.muted)
            }.padding(.horizontal, 12).padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .contentShape([.interaction, .accessibility], Rectangle())
        }.buttonStyle(.plain).foregroundStyle(destructive ? MSTheme.danger : MSTheme.ink)
            .accessibilityLabel(tr(title)).accessibilityIdentifier(identifier)
    }
}
