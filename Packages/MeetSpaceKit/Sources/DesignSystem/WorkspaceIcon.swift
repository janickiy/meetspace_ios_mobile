import SwiftUI

/// Workspace glyphs from mobile_maket/meetspace-refresh-20261016/assets/icons.js (Lucide, license in Resources).
/// The resource contains the original 24-point outlines in SwiftUI Path notation.
public struct WorkspaceIcon: View {
    private let name: String
    private let size: CGFloat

    /// Выбирает иконку рабочего пространства и задаёт её размер.
    /// - Parameters:
    ///   - systemName: Имя символа, для которого выбирается контур.
    ///   - size: Размер иконки в пунктах.
    public init(_ systemName: String, size: CGFloat = 20) {
        self.name = systemName
        self.size = size
    }

    private static let paths: [String: Path] = {
        guard let url = Bundle.module.url(forResource: "WorkspaceIcons", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let descriptions = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return descriptions.compactMapValues { Path($0) }
    }()

    public var body: some View {
        Group {
            if let path = Self.paths[name] {
                let scale = size / 24
                path.applying(CGAffineTransform(scaleX: scale, y: scale))
                    .stroke(style: StrokeStyle(lineWidth: 1.75 * scale, lineCap: .round, lineJoin: .round))
            } else {
                Image(systemName: name).font(.system(size: size))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
