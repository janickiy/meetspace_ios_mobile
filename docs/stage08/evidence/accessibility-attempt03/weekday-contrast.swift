import Foundation
import AppKit
import CryptoKit
import ImageIO

// Read-only measurement of the two reviewed labels in the unchanged CI3 PNG.
// Run from any directory: xcrun swift /path/to/weekday-contrast.swift
let imageURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("iPad18-calendar-normal.png")
let imageData = try Data(contentsOf: imageURL)
let sha256 = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
precondition(sha256 == "d436a64875627feee78d9b7e36bd1cd8d953bf3cd7fac5dc23c9c3f235427328", "Reviewed PNG changed")
let bitmap = NSBitmapImageRep(data: imageData)!
precondition(bitmap.pixelsWide == 1488 && bitmap.pixelsHigh == 2266)
precondition(bitmap.samplesPerPixel == 3 && bitmap.bitsPerSample == 8)
let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil)!
let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)! as NSDictionary

func luminance(_ rgb: [Int]) -> Double {
    let channels = rgb.map { Double($0) / 255 }.map {
        $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
    }
    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
}

func contrast(_ first: [Int], _ second: [Int]) -> Double {
    let a = luminance(first), b = luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

struct Sample {
    let id: String
    let label: String
    let frame: [Double] // XCTest x, y, width, height in points.
    let foreground: [Int]
    let background: [Int]
}

let samples = [
    Sample(id: "calendar.weekday.0", label: "Пн", frame: [49.25, 379.25, 13.5, 12.5],
           foreground: [41, 43, 59], background: [255, 255, 255]),
    Sample(id: "calendar.weekday.4", label: "Пт", frame: [285.75, 379.25, 12.5, 12.5],
           foreground: [255, 255, 255], background: [93, 95, 205])
]

var records: [[String: Any]] = []
for sample in samples {
    let f = sample.frame
    // Floor the start and ceil the end. Max coordinates are exclusive.
    let bounds = [Int(floor(f[0] * 2)), Int(floor(f[1] * 2)),
                  Int(ceil((f[0] + f[2]) * 2)), Int(ceil((f[1] + f[3]) * 2))]
    var counts: [[Int]: Int] = [:]
    for y in bounds[1]..<bounds[3] {
        for x in bounds[0]..<bounds[2] {
            var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            bitmap.getPixel(&pixel, atX: x, y: y)
            counts[pixel, default: 0] += 1
        }
    }
    let strongest = counts.keys.max { contrast($0, sample.background) < contrast($1, sample.background) }!
    let countsAboveThreshold = counts.filter { contrast($0.key, sample.background) >= 4.5 }.values.reduce(0, +)
    let histogram: [[String: Any]] = counts.sorted {
        $0.value == $1.value ? $0.key.lexicographicallyPrecedes($1.key) : $0.value > $1.value
    }.map { ["rgb": $0.key, "count": $0.value] }
    records.append([
        "identifier": sample.id, "label": sample.label, "auditType": "contrast",
        "framePointsXYWH": sample.frame, "samplePixelBoundsXYXYExclusive": bounds,
        "foregroundRGB": sample.foreground, "backgroundRGB": sample.background,
        "exactForegroundPixelCount": counts[sample.foreground, default: 0],
        "exactBackgroundPixelCount": counts[sample.background, default: 0],
        "pixelsAtContrastAtLeast4_5": countsAboveThreshold,
        "sourcePairContrast": contrast(sample.foreground, sample.background),
        "strongestObservedRGB": strongest, "strongestObservedContrast": contrast(strongest, sample.background),
        "histogram": histogram
    ])
}

let report: [String: Any] = [
    "run": 42240106296, "sourceCommit": "586bfe875355f930a5d463214bd7860a78ac189e",
    "platform": "iPad mini (A17 Pro), iPadOS 18", "imageFile": imageURL.lastPathComponent,
    "imageSHA256": sha256, "imagePixels": [bitmap.pixelsWide, bitmap.pixelsHigh], "pixelsPerPoint": 2,
    "sourceAttachment": "762282FB-8872-4286-822B-19A5FF4A5E32.png",
    "colorSpace": bitmap.colorSpaceName.rawValue,
    "imageColorProfile": properties[kCGImagePropertyProfileName] as? String ?? "not declared",
    "method": "Unmodified PNG; native RGB pixel histogram in floor/ceil XCTest bounds; WCAG relative luminance in sRGB; antialiased edge pixels retained in histogram.",
    "scope": "Exactly two fully visible weekday labels. Does not certify other labels, other states, whole-screen contrast, or clipped samples.",
    "samples": records
]
let result = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(result)
FileHandle.standardOutput.write(Data("\n".utf8))
