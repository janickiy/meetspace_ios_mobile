import Foundation
import CoreVideo
import ImageIO
import Testing
@testable import MeetSpaceBroadcast

private func screenPixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, format, nil, &value)
    #expect(status == kCVReturnSuccess)
    return try #require(value)
}

@Test func screenConverterAppliesAllEightEXIFOrientations() throws {
    let buffer = try screenPixelBuffer(width: 4, height: 2, format: kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = try #require(CVPixelBufferGetBaseAddress(buffer))
    for y in 0..<2 { for x in 0..<4 {
        let pixel = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4).assumingMemoryBound(to: UInt8.self)
        pixel[0] = UInt8(y * 4 + x + 1); pixel[1] = 0; pixel[2] = 0; pixel[3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let expected: [[UInt8]] = [
        [1,2,3,4,5,6,7,8], [4,3,2,1,8,7,6,5], [8,7,6,5,4,3,2,1], [5,6,7,8,1,2,3,4],
        [1,5,2,6,3,7,4,8], [5,1,6,2,7,3,8,4], [8,4,7,3,6,2,5,1], [4,8,3,7,2,6,1,5]
    ]
    let converter = ScreenFrameConverter()
    for raw in 1...8 {
        let frame = try converter.convert(buffer, orientation: try #require(CGImagePropertyOrientation(rawValue: UInt32(raw))),
            sessionID: UUID(), timestampNs: Int64(raw))
        let blue = stride(from: 0, to: frame.pixels.count, by: 4).map { frame.pixels[$0] }
        #expect(blue == expected[raw - 1], "EXIF orientation \(raw)")
        #expect(frame.width == (raw <= 4 ? 4 : 2))
        #expect(frame.height == (raw <= 4 ? 2 : 4))
        try frame.validated()
    }
}

@Test(arguments: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
func screenConverterScalesNV12BeforeBGRAAndKeepsOpaqueWhite(_ format: OSType) throws {
    let buffer = try screenPixelBuffer(width: 64, height: 128, format: format)
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<2 {
        let address = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        memset(address, plane == 1 ? 128 : (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 235 : 255), height * stride)
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let frame = try ScreenFrameConverter(maxWidth: 32, maxHeight: 16).convert(buffer, orientation: .up,
        sessionID: UUID(), timestampNs: 1)
    #expect(frame.width == 16 && frame.height == 32 && frame.pixels.count == 2048)
    for offset in stride(from: 0, to: frame.pixels.count, by: 4) {
        #expect(frame.pixels[offset] >= 254 && frame.pixels[offset + 1] >= 254 && frame.pixels[offset + 2] >= 254)
        #expect(frame.pixels[offset + 3] == 255)
    }
}
