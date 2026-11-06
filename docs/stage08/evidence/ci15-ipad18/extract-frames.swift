import Foundation
import AVFoundation
import AppKit
let video = "/tmp/meetspace-stage08-ci-42281088607/results-iPad18/iPad18-screenshots/23ECDB89-A845-4D0C-90F7-D0F6CC065ECA.mp4"
let asset = AVURLAsset(url: URL(fileURLWithPath: video))
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
var rows: [[String: Any]] = []
for second in [73.0, 74.0, 76.0, 83.0, 89.0] {
    var actual = CMTime.zero
    let cg = try generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: &actual)
    let output = "/tmp/meetspace-ci15-ipad18-tutorial-\(Int(second)).png"
    let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: output))
    rows.append(["requestedSeconds": second, "actualVideoPTSSeconds": actual.seconds, "file": output, "widthPixels": cg.width, "heightPixels": cg.height])
}
let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: "/tmp/meetspace-ci15-ipad18-tutorial-frames.json"))
print(String(data: data, encoding: .utf8)!)
