// Re-extract the frame from the original CI artifact's MP4; the source video is not duplicated in Git.
// swift path/to/ipad26-password-frame.swift /path/to/1DCA4F3D-DB04-44C4-943F-1DB9F0B77A91.mp4 /tmp/frame.png
import AVFoundation
import AppKit
import CryptoKit

precondition(CommandLine.arguments.count == 3)
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: source)
print("sourceSHA256", SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
let asset = AVURLAsset(url: source)
let duration = try await asset.load(.duration)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
let requested = CMTime(seconds: max(0, duration.seconds - 1), preferredTimescale: 600)
let frame = try await generator.image(at: requested)
let output = NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:])!
try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("requestedSeconds", requested.seconds, "actualSeconds", frame.actualTime.seconds)
