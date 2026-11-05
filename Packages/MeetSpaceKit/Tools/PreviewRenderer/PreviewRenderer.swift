#if os(macOS)
import AppKit
import SwiftUI
import MeetSpaceFeatures
import MeetSpaceCore
import MeetSpaceDesignSystem

@main @MainActor struct PreviewRenderer {
    static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/meetspace-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (screen, width, height, dark, large) in [
            ("welcome", 390.0, 844.0, false, false),
            ("welcome", 1194.0, 834.0, false, false),
            ("meetings", 390.0, 844.0, false, false),
            ("meetings", 834.0, 1194.0, true, false),
            ("messages", 1194.0, 834.0, true, false),
            ("profile", 390.0, 844.0, false, true)
        ] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let view = FoundationPreviewScene(screen: screen)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                .environment(\.locale, Locale(identifier: "ru"))
                .frame(width: width, height: height)
            // ImageRenderer omits platform-backed ScrollView/TextField. Use a real host view.
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw NSError(domain: "PreviewRenderer", code: 1)
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "PreviewRenderer", code: 2) }
            let name = "\(screen)-\(Int(width))-\(dark ? "dark" : "light")\(large ? "-large-text" : "").png"
            try png.write(to: output.appendingPathComponent(name))
            print(name)
            window.close()
        }
    }
}
#else
@main struct PreviewRenderer {
    static func main() { fatalError("FoundationPreviewRenderer is a macOS verification tool") }
}
#endif
