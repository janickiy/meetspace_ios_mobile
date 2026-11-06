// Render the existing, design-sourced BrandMark. No new logo is invented.
// swiftc -parse-as-library scripts/render_app_icon.swift \
//   Packages/MeetSpaceKit/Sources/DesignSystem/BrandMark.swift -o /tmp/meetspace-icon
// /tmp/meetspace-icon App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main @MainActor struct AppIconRenderer {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "AppIconRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Supply an output PNG path"])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let renderer = ImageRenderer(content: BrandMark().frame(width: 704, height: 736)
            .frame(width: 1024, height: 1024).background(Color.white)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                  bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "AppIconRenderer", code: 2)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let opaque = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "AppIconRenderer", code: 3)
        }
        CGImageDestinationAddImage(destination, opaque, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "AppIconRenderer", code: 4) }
        print("PASS: opaque 1024×1024 sRGB App Icon")
    }
}
