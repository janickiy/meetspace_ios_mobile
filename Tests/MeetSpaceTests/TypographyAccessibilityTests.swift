import XCTest
import SwiftUI
import UIKit
import MeetSpaceDesignSystem

@MainActor final class TypographyAccessibilityTests: XCTestCase {
    func testBundledFontsScaleInActualUIKitHostingAtAllDynamicTypeSizes() throws {
        let samples: [(CGFloat, Font.TextStyle)] = [(10, .caption), (11, .body), (12, .body),
            (14, .body), (20, .title2), (28, .title), (34, .largeTitle)]
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
                records.append(["baseSize": size, "weight": String(describing: weight), "heights": heights])
            }
        }
        XCTAssertNotNil(UIFont(name: "Inter-Regular", size: 14))
        XCTAssertNotNil(UIFont(name: "Inter-SemiBold", size: 14))
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        evidence.name = "stage08-actual-font-scaling"; evidence.lifetime = .keepAlways; add(evidence)
    }
}
