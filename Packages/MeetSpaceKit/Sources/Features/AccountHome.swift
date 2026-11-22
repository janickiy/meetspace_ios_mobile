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

struct AccountHome<Detail: View, Extras: View>: View {
    let name: String
    let email: String
    let server: String
    let demo: Bool
    var photo: Data?
    var sections = ProfileSection.allCases.filter { $0 != .connection }
    let logout: () -> Void
    @ViewBuilder var detail: (ProfileSection, Bool) -> Detail
    @ViewBuilder var extras: () -> Extras
    @State private var selection: ProfileSection?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 780 && !typeSize.isAccessibilitySize
            VStack(spacing: 0) {
                PageHeader(title: "Настройки аккаунта") { EmptyView() }
                HStack(spacing: 0) {
                    if wide || selection == nil { menu(wide: wide).frame(width: wide ? (geometry.size.width >= 1100 ? 270 : 240) : nil) }
                    if wide { Divider() }
                    if wide || selection != nil {
                        VStack(alignment: .leading, spacing: 0) {
                            if !wide {
                                Button { selection = nil } label: {
                                    Label(tr("Все настройки"), systemImage: "arrow.left")
                                        .font(MSTheme.font(13)).frame(minHeight: 44)
                                }.buttonStyle(.plain).foregroundStyle(MSTheme.accent).padding(.horizontal, 20)
                            }
                            detail(selection ?? .profile, wide)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }.background(MSTheme.background)
                    }
                }
                .background(MSTheme.surface)
                .clipShape(Rectangle())
                .overlay { if wide { Rectangle().strokeBorder(MSTheme.line) } }
                .padding(.horizontal, wide ? 24 : 0)
                .padding(.bottom, 0)
            }
        }.background(MSTheme.background).accessibilityIdentifier("screen.profile")
    }

    private func menu(wide: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button { selection = .accounts } label: {
                    HStack(spacing: wide ? 10 : 14) {
                        ProfileAvatar(name: name, size: wide ? 42 : 54, cornerRadius: wide ? 14 : 18, photo: photo)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(MSTheme.font(wide ? 13 : 16, weight: .semibold))
                            Text(email).font(MSTheme.font(wide ? 11 : 13)).foregroundStyle(MSTheme.muted)
                        }
                        Spacer(minLength: 1)
                        Image(systemName: "chevron.down").font(.system(size: 14)).foregroundStyle(MSTheme.muted)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(tr("Сменить аккаунт")).accessibilityValue("\(name), \(email)")
                    .padding(.bottom, wide ? 30 : 26)
                Text(tr("Настройки аккаунта").uppercased()).font(MSTheme.font(10, weight: .semibold))
                    .tracking(1.3).foregroundStyle(MSTheme.muted).padding(.bottom, 10)
                VStack(spacing: 5) {
                    ForEach(sections, id: \.self) { section in
                        let label = section.label
                        let selected = wide && (selection ?? .profile) == section
                        Button { selection = section } label: {
                            HStack(spacing: 13) {
                                Image(systemName: label.symbol).font(.system(size: wide ? 18 : 20))
                                    .foregroundStyle(wide && !selected ? MSTheme.muted : MSTheme.accent)
                                    .frame(width: wide ? 25 : 40, height: wide ? 28 : 40)
                                    .background(wide ? Color.clear : MSTheme.accentSoft, in: RoundedRectangle(cornerRadius: 13))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tr(label.title)).font(MSTheme.font(wide ? 13 : 15, weight: .semibold))
                                    if !wide { Text(tr(label.hint)).font(MSTheme.font(12)).foregroundStyle(MSTheme.muted) }
                                }
                                Spacer(minLength: 1)
                                if !wide { Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(MSTheme.muted) }
                            }.foregroundStyle(selected ? MSTheme.accent : MSTheme.ink)
                                .padding(.vertical, wide ? 10 : 14).padding(.horizontal, wide ? 10 : 0)
                                .frame(minHeight: wide ? 52 : 66).contentShape(Rectangle())
                                .background(selected ? MSTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .leading) { if selected { Capsule().fill(MSTheme.accent).frame(width: 3) } }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityLabel(tr(label.title)).accessibilityHint(tr(label.hint)).accessibilityIdentifier("profileMenu.\(section.rawValue)")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        if !wide { Divider() }
                    }
                }
                Button { selection = .connection } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "server.rack")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr("Подключение")).font(MSTheme.font(13, weight: .semibold))
                            Text(server).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 12))
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(MSTheme.background, in: RoundedRectangle(cornerRadius: 15))
                        .overlay { if !wide { RoundedRectangle(cornerRadius: 15).strokeBorder(MSTheme.line) } }
                }.buttonStyle(.plain).padding(.top, 26)
                Button(action: logout) { Label(tr(demo ? "Выйти из демо" : "Выйти из аккаунта"), systemImage: "rectangle.portrait.and.arrow.right")
                    .font(MSTheme.font(13)).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.plain).foregroundStyle(MSTheme.muted).padding(.top, 8)
                    .accessibilityIdentifier(demo ? "exitDemo" : "account.logout")
                if demo { Text(tr("MeetSpace · Демо")).font(MSTheme.font(11)).foregroundStyle(MSTheme.muted).frame(maxWidth: .infinity) }
                extras().padding(.top, 24)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, wide ? 18 : 20).padding(.top, wide ? 26 : 24).padding(.bottom, 20)
        }.background(wide ? MSTheme.background : MSTheme.surface)
    }
}
