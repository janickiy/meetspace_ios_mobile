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
    public static let muted = adaptive(0x727687, 0xb0b3c7)
    public static let line = adaptive(0xe7e8f0, 0x36394c)
    public static let accent = adaptive(0x6264d9, 0xaaaaff)
    public static let accentSoft = adaptive(0xeeeffe, 0x343452)
    public static let success = adaptive(0x25836c, 0x83d9bb)
    public static let danger = adaptive(0xd14857, 0xff8c97)

    private static let registerFonts: Void = {
        for name in ["inter_regular", "inter_semibold"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    public static func font(_ size: CGFloat = 14, weight: Font.Weight = .regular,
                            relativeTo style: Font.TextStyle = .body) -> Font {
        _ = registerFonts
        return .custom(weight == .regular ? "Inter-Regular" : "Inter-SemiBold", size: size, relativeTo: style)
    }

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
    func msCard(padding: CGFloat = 16) -> some View {
        self.padding(padding).background(MSTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(MSTheme.line, lineWidth: 1))
    }

    @ViewBuilder func msInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder func msURLInput() -> some View {
        #if os(iOS)
        self.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

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
    public init(primary: Bool = true) { self.primary = primary }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(MSTheme.font(14, weight: .semibold))
            .frame(minHeight: 44).frame(maxWidth: .infinity).padding(.horizontal, 14)
            .foregroundStyle(primary ? MSTheme.surface : MSTheme.ink)
            .background(primary ? MSTheme.accent : MSTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

public struct IconButton: View {
    private let symbol: String
    private let label: String
    private let action: () -> Void
    public init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.action = action
    }
    public var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 19)).frame(width: 44, height: 44) }
            .buttonStyle(.plain).foregroundStyle(MSTheme.muted).accessibilityLabel(tr(label))
    }
}

public struct Avatar: View {
    private let initials: String
    private let size: CGFloat
    public init(_ initials: String, size: CGFloat = 44) { self.initials = initials; self.size = size }
    public var body: some View {
        Text(initials).font(MSTheme.font(size * 0.3, weight: .semibold)).foregroundStyle(MSTheme.accent)
            .frame(width: size, height: size).background(MSTheme.accentSoft, in: Circle()).accessibilityHidden(true)
    }
}
