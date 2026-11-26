import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public func tr(_ key: String) -> String { NSLocalizedString(key, bundle: .module, comment: "") }

public enum MSTheme {
    public static let background = adaptive(0xf7f8fc, 0x171821)
    public static let surface = adaptive(0xffffff, 0x21232f)
    public static let surfaceSecondary = adaptive(0xf0f1f7, 0x2b2e3e)
    public static let ink = adaptive(0x292b3b, 0xf3f3fa)
    public static let muted = adaptive(0x686c7d, 0xb0b3c7)
    public static let line = adaptive(0xe7e8f0, 0x36394c)
    public static let brandAccent = adaptive(0x6264d9, 0xaaaaff)
    public static let accent = adaptive(0x5d5fcd, 0xaaaaff)
    public static let accentSoft = adaptive(0xeeeffe, 0x343452)
    public static let success = adaptive(0x237962, 0x83d9bb)
    public static let danger = adaptive(0xc03d4c, 0xff8c97)

    private static let registerFonts: Void = {
        for name in ["inter_regular", "inter_semibold"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    /// Возвращает шрифт Inter с масштабированием для системного размера текста.
    /// - Parameters:
    ///   - size: Базовый кегль в пунктах.
    ///   - weight: Начертание шрифта. Для обычного веса выбирается Inter Regular, для остальных — SemiBold.
    ///   - style: Стиль Dynamic Type, задающий масштаб.
    public static func font(_ size: CGFloat = 14, weight: Font.Weight = .regular,
                            relativeTo style: Font.TextStyle = .body) -> Font {
        _ = registerFonts
        return .custom(weight == .regular ? "Inter-Regular" : "Inter-SemiBold", size: size, relativeTo: style)
    }

    /// Создаёт цвет, который меняется вместе с системной цветовой схемой.
    /// - Parameters:
    ///   - light: RGB-код для светлого оформления.
    ///   - dark: RGB-код для тёмного оформления.
    private static func adaptive(_ light: UInt, _ dark: UInt) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
        #endif
    }
}

public extension View {
    /// Оформляет содержимое как карточку с фоном, скруглением и тонкой рамкой.
    /// - Parameter padding: Внутренний отступ карточки в пунктах.
    func msCard(padding: CGFloat = 16) -> some View {
        self.padding(padding).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(MSTheme.line, lineWidth: 1))
    }

    /// На iOS размещает заголовок в строке панели навигации.
    @ViewBuilder func msInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Настраивает поле для ввода URL и отключает автокоррекцию.
    @ViewBuilder func msURLInput() -> some View {
        #if os(iOS)
        self.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Настраивает поле для ввода электронной почты и отключает автокоррекцию.
    @ViewBuilder func msEmailInput() -> some View {
        #if os(iOS)
        self.keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

public struct MSButtonStyle: ButtonStyle {
    private let primary: Bool
    @Environment(\.isEnabled) private var isEnabled
    /// Задаёт визуальную роль кнопки MeetSpace.
    /// - Parameter primary: Выбирает акцентную заливку для основного действия или нейтральную для второстепенного.
    public init(primary: Bool = true) { self.primary = primary }
    /// Оформляет кнопку на ширину контейнера и меняет прозрачность при нажатии и блокировке.
    /// - Parameter configuration: Метка кнопки и переданное SwiftUI состояние нажатия.
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(MSTheme.font(14, weight: .semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            .foregroundStyle(primary ? MSTheme.surface : MSTheme.ink)
            .background(primary ? MSTheme.accent : MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

public struct MSTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// Создаёт стиль текстовой кнопки с акцентным цветом.
    public init() {}
    /// Оформляет текстовую кнопку и задаёт минимальную область нажатия 44 × 44 пункта.
    /// - Parameter configuration: Метка кнопки и текущее состояние нажатия.
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .foregroundStyle(MSTheme.accent)
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
    }
}

public struct IconButton: View {
    private let symbol: String
    private let label: String
    private let action: () -> Void
    /// Создаёт кнопку с системной иконкой и доступным текстовым названием.
    /// - Parameters:
    ///   - symbol: Имя изображения SF Symbols.
    ///   - label: Ключ локализованной подписи для VoiceOver.
    ///   - action: Действие при нажатии.
    public init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.action = action
    }
    public var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 19)).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(MSTheme.muted).accessibilityLabel(tr(label))
    }
}

public struct Avatar: View {
    private let initials: String
    private let size: CGFloat
    /// Создаёт круглый аватар с инициалами участника.
    /// - Parameters:
    ///   - initials: Инициалы для отображения.
    ///   - size: Диаметр аватара в пунктах.
    public init(_ initials: String, size: CGFloat = 44) { self.initials = initials; self.size = size }
    public var body: some View {
        Text(initials).font(MSTheme.font(size * 0.3, weight: .semibold)).foregroundStyle(MSTheme.accent)
            .frame(width: size, height: size).background(MSTheme.accentSoft, in: Circle()).accessibilityHidden(true)
    }
}
