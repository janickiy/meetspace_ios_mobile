// Reproduce the pixel receipt: swift path/to/ipad26-contrast-pixels.swift > /tmp/ipad26-pixels.json
// Reads unchanged, sRGB-tagged PNG attachments. No resizing, re-encoding or color conversion.
import AppKit
import CryptoKit
import Foundation

let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("iPad26-contrast-manifest.json"))) as! [String: Any]
let images = manifest["screenshots"] as! [[String: String]]
let issues = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("iPad26-contrast-raw-issues.json"))) as! [[String: String]]
func hex(_ value: Int) -> String { String(format: "#%06x", value) }
func luminance(_ value: Int) -> Double {
    let channels = [16, 8, 0].map { Double((value >> $0) & 255) / 255 }
        .map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
}
func contrast(_ a: Int, _ b: Int) -> Double {
    (max(luminance(a), luminance(b)) + 0.05) / (min(luminance(a), luminance(b)) + 0.05)
}
var rows: [[String: Any]] = []
for (index, issue) in issues.enumerated() where issue["type"] == "1" {
    let screen = issue["screen"]!, label = issue["label"]!
    let source = images.first { $0["screen"] == screen }!
    let data = try Data(contentsOf: base.appendingPathComponent(source["file"]!))
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    precondition(digest == source["sha256"], "Source PNG changed")
    let image = NSBitmapImageRep(data: data)!
    precondition(image.pixelsWide == 2064 && image.pixelsHigh == 2752)
    precondition(image.colorSpace.localizedName?.contains("sRGB") == true, "Review color profile before measuring")
    let frame = issue["frame"]!.split { !($0.isNumber || $0 == ".") }.map { Double($0)! }
    let rect = CGRect(x: frame[0] * 2, y: frame[1] * 2, width: frame[2] * 2, height: frame[3] * 2)
    var counts: [Int: Int] = [:]
    for y in Int(floor(rect.minY))..<Int(ceil(rect.maxY)) {
        for x in Int(floor(rect.minX))..<Int(ceil(rect.maxX)) {
            // The bitmap is already tagged sRGB. Read its component values directly.
            // NSColor.usingColorSpace would reinterpret device-color objects, not raw PNG bytes.
            let color = image.colorAt(x: x, y: y)!
            let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
                .map { Int(($0 * 255).rounded()) }
            counts[(rgb[0] << 16) | (rgb[1] << 8) | rgb[2], default: 0] += 1
        }
    }
    let fg: Int, bg: Int, kind: String
    switch (screen, label) {
    case ("messages", "Выберите чат"):
        (fg, bg, kind) = (0x292b3b, 0xf7f8fc, "composite text plus decorative system icon")
    case (_, "ТЕ"), (_, "ПЕ"):
        (fg, bg, kind) = (0x5d5fcd, 0xeeeffe, "decorative initials duplicate adjacent full name")
    case ("calendar", "Пн"):
        (fg, bg, kind) = (0x292b3b, 0xffffff, "visible text")
    case ("calendar", "Пт"):
        (fg, bg, kind) = (0xffffff, 0x5d5fcd, "visible selected-day text")
    case ("folders", "Личное пространство"):
        (fg, bg, kind) = (0x5d5fcd, 0xf7f8fc, "visible text")
    case ("settings", "Сохранить профиль"):
        (fg, bg, kind) = (0xd5d5f2, 0xb2b3e7, "disabled control; opacity 0.45; not a normal-text contrast pass")
    case (_, "Готова"):
        (fg, bg, kind) = (0x5d5fcd, 0xffffff, "visible recording status")
    case (_, "Создать пространство на своём VPS"), (_, "На этой неделе"),
         (_, "Обрабатывается"), (_, "Не удалось записать"):
        (fg, bg, kind) = (0x686c7d, 0xffffff, "visible text")
    default: fatalError("Unreviewed contrast case: \(screen), \(label)")
    }
    precondition(counts[fg, default: 0] > 0 && counts[bg, default: 0] > 0, "Expected color not found in actual pixels")
    let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .prefix(8).map { ["color": hex($0.key), "count": $0.value] as [String: Any] }
    var row: [String: Any] = ["rawIndex": index, "screen": screen, "element": issue["element"]!,
        "label": label, "framePoints": frame, "rawResolution": issue["resolution"]!,
        "sourcePNG": source["file"]!, "sourceSHA256": digest, "kind": kind,
        "foreground": hex(fg), "background": hex(bg), "foregroundPixelCount": counts[fg]!,
        "backgroundPixelCount": counts[bg]!, "coreContrastRatio": contrast(fg, bg), "topColors": top]
    if screen == "messages", label == "Выберите чат" {
        row["decorativeIcon"] = ["color": hex(0x90919b), "pixelCount": counts[0x90919b, default: 0],
                                 "contrastRatio": contrast(0x90919b, bg)]
    }
    rows.append(row)
}
let report: [String: Any] = ["ciRun": 42240106296, "sourceCommit": manifest["sourceCommit"]!,
    "method": "Original PNG sRGB components; raw point frame multiplied by 2; floor/ceil pixel bounds; exact color counts and WCAG relative luminance of observed core/background pair",
    "limits": "Not Apple's algorithm; antialiased edge pixels have lower contrast; composite/decorative/disabled cases are separate; no claim about another screenshot, runtime or future revision",
    "rawIssueCount": issues.count, "contrastFindingCount": rows.count, "measurements": rows]
let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(output)
FileHandle.standardOutput.write(Data("\n".utf8))
