// Reproduce macOS Vision observations; this is not a result from iPad Vision execution.
// swift path/to/ipad26-password-ocr.swift > /tmp/ipad26-password-ocr.json
import AppKit
import CryptoKit
import Vision

let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let file = "screenshots/iPad26-password-prompt-ax5-video-frame.png"
let data = try Data(contentsOf: base.appendingPathComponent(file))
let image = NSBitmapImageRep(data: data)!.cgImage!
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["en-US"]
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
let rows: [[String: Any]] = (request.results ?? []).compactMap { observation in
    guard let candidate = observation.topCandidates(1).first else { return nil }
    let b = observation.boundingBox
    return ["text": candidate.string, "normalized": candidate.string.filter { $0.isLetter }.lowercased(),
        "confidence": candidate.confidence,
        "boundingBoxBottomLeftNormalized": [b.minX, b.minY, b.width, b.height],
        "tapTopLeftNormalized": [b.midX, 1 - b.midY]]
}
let report: [String: Any] = ["ciRun": 42240106296, "sourcePNG": file,
    "sourceSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
    "executionHost": ProcessInfo.processInfo.operatingSystemVersionString,
    "recognitionLevel": "accurate", "recognitionLanguages": ["en-US"], "usesLanguageCorrection": false,
    "singleObservationSavePasswordFound": rows.contains { $0["normalized"] as? String == "savepassword" },
    "observations": rows,
    "limits": "Actual observations from this extracted frame on the recorded macOS host; not a new iOS harness PASS or proof about other system dialogs"]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
FileHandle.standardOutput.write(Data("\n".utf8))
