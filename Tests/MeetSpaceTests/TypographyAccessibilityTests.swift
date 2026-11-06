import XCTest
import SwiftUI
import UIKit
import MeetSpaceDesignSystem

@MainActor final class TypographyAccessibilityTests: XCTestCase {
    func testBundledFontsScaleInActualUIKitHostingAtAllDynamicTypeSizes() throws {
        let bodySizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
            22, 23, 24, 25, 26, 27, 28, 32, 34, 37, 46]
        let samples: [(CGFloat, Font.TextStyle)] = bodySizes.map { ($0, .body) } +
            [(9, .caption), (10, .caption), (11, .caption), (19, .title2), (20, .title2), (23, .title2),
             (24, .title), (25, .title), (27, .title), (28, .title), (32, .largeTitle),
             (34, .largeTitle), (46, .largeTitle)]
        let categories: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge,
            .xxxLarge, .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        var records: [[String: Any]] = []
        for (size, style) in samples {
            for weight in [Font.Weight.regular, .semibold] {
                var heights: [CGFloat] = []
                for category in categories {
                    let content = Text("Пример 09:00").font(MSTheme.font(size, weight: weight, relativeTo: style))
                        .fixedSize().environment(\.dynamicTypeSize, category)
                    let host = UIHostingController(rootView: content)
                    let measured = host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
                    XCTAssertGreaterThan(measured.height, 0)
                    heights.append(measured.height)
                }
                XCTAssertGreaterThan(heights.last!, heights[3] * 1.5, "Font \(size) must actually grow at AX5")
                XCTAssertTrue(zip(heights, heights.dropFirst()).allSatisfy { $1 >= $0 }, "Scaling must be monotonic")
                let accessibleHeights = Array(heights.suffix(5))
                XCTAssertTrue(zip(accessibleHeights, accessibleHeights.dropFirst()).allSatisfy { $1 > $0 },
                              "Every accessibility category must increase the actual line height")
                records.append(["baseSize": size, "style": String(describing: style),
                                "weight": String(describing: weight),
                                "categories": categories.map { String(describing: $0) }, "heights": heights])
            }
        }
        XCTAssertNotNil(UIFont(name: "Inter-Regular", size: 14))
        XCTAssertNotNil(UIFont(name: "Inter-SemiBold", size: 14))
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "stage08-actual-font-scaling"; evidence.lifetime = .keepAlways; add(evidence)
    }
}
