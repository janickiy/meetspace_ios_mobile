import AVFoundation
import AppKit
import Vision
let base = "/tmp/meetspace-stage08-ci13-ipad18-audit-review"
let asset = AVURLAsset(url: URL(fileURLWithPath: base + "/core.mp4"))
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
var reports: [[String: Any]] = []
for seconds in [149.0,158.0,166.0,168.0,170.0,173.0,176.0,180.0,183.0] {
 let frame = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
 let output = base + "/scale-frame-\(Int(seconds)).png"
 try NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
 let request = VNRecognizeTextRequest()
 request.recognitionLevel = .accurate
 request.recognitionLanguages = ["ru-RU", "en-US"]
 request.usesLanguageCorrection = false
 try VNImageRequestHandler(cgImage: frame.image,options:[:]).perform([request])
 let matches = (request.results ?? []).compactMap { x -> [String:Any]? in
  guard let first=x.topCandidates(1).first, ["Сообщения","Поиск чатов","Тестовый собеседник"].contains(first.string) else {return nil}
  let b=x.boundingBox
  return ["label":first.string,"confidence":first.confidence,"bbox":[b.minX,b.minY,b.width,b.height]]
 }
 reports.append(["requestedSeconds":seconds,"actualSeconds":frame.actualTime.seconds,"texts":matches])
 print(seconds,matches)
}
let data=try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys])
try data.write(to:URL(fileURLWithPath:base + "/scale-ocr.json"))
