import SwiftUI

/// Кнопка выхода из модального окна или возврата к предыдущему шагу.
public struct MSLiquidAction: View {
    public enum Kind {
        case close, cancel, back

        fileprivate var label: String {
            switch self {
            case .close: "Закрыть"
            case .cancel: "Отмена"
            case .back: "Назад"
            }
        }
    }

    private let kind: Kind
    private let title: String?
    private let inToolbar: Bool
    private let action: () -> Void

    /// Выбирает подпись, форму и способ отрисовки стекла для действия.
    /// - Parameters:
    ///   - kind: Назначение кнопки.
    ///   - title: Локализуемая подпись для действия с текстом.
    ///   - inToolbar: Использовать стеклянный фон системной панели инструментов.
    ///   - action: Действие при нажатии.
    public init(_ kind: Kind, title: String? = nil, inToolbar: Bool = false, action: @escaping () -> Void) {
        self.kind = kind
        self.title = title
        self.inToolbar = inToolbar
        self.action = action
    }

    private var showsText: Bool { kind == .cancel || title != nil }

    public var body: some View {
        Group {
            if #available(iOS 26, macOS 26, *) {
                if inToolbar {
                    Button(action: action) { label }
                } else {
                    Button(action: action) {
                        label.frame(minWidth: showsText ? nil : 24, minHeight: 24)
                    }
                        .buttonStyle(.glass)
                        .buttonBorderShape(showsText ? .capsule : .circle)
                        .controlSize(.large)
                }
            } else {
                Button(action: action) {
                    label
                        .padding(.horizontal, showsText ? 16 : 0)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(.regularMaterial, in: Capsule())
                        .overlay { Capsule().strokeBorder(.primary.opacity(0.14)) }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .fixedSize()
        .accessibilityLabel(tr(title ?? kind.label))
    }

    @ViewBuilder private var label: some View {
        if showsText {
            HStack(spacing: 6) {
                if kind != .cancel { Image(systemName: kind == .back ? "chevron.backward" : "xmark") }
                Text(verbatim: tr(title ?? kind.label)).lineLimit(1)
            }.font(MSTheme.font(14, weight: .semibold))
        } else {
            Image(systemName: kind == .back ? "chevron.backward" : "xmark")
                .font(.system(size: 17, weight: .medium))
        }
    }
}
