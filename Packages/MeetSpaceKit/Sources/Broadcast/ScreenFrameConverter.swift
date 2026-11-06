import Foundation
import Accelerate
import CoreVideo
import ImageIO

public enum ScreenFrameConversionError: Error { case invalidBuffer, unsupportedFormat, allocation, conversion }

/// Used only by ReplayKit's serialized callbacks. The system-owned input stays locked only for
/// this invocation; never retain a sample or allocate a full-resolution BGRA intermediate.
public final class ScreenFrameConverter {
    private let maxLongEdge: Int
    private let maxShortEdge: Int
    private var rgb = OwnedImageBuffer()
    private var y = OwnedImageBuffer()
    private var uv = OwnedImageBuffer()

    public init(maxWidth: Int = 1280, maxHeight: Int = 720) {
        maxLongEdge = min(1280, max(maxWidth, maxHeight))
        maxShortEdge = min(720, min(maxWidth, maxHeight))
    }

    public func releaseBuffers() { rgb = OwnedImageBuffer(); y = OwnedImageBuffer(); uv = OwnedImageBuffer() }

    public func convert(_ input: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                 sessionID: UUID, timestampNs: Int64) throws -> ScreenBroadcastFrame {
        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        guard (2...8192).contains(width), (2...8192).contains(height), width * height <= 16_777_216,
              maxShortEdge >= 2, timestampNs >= 0 else { throw ScreenFrameConversionError.invalidBuffer }
        let scale = min(1, min(Double(maxLongEdge) / Double(max(width, height)),
                               Double(maxShortEdge) / Double(min(width, height))))
        let targetWidth = max(2, Int(Double(width) * scale) / 2 * 2)
        let targetHeight = max(2, Int(Double(height) * scale) / 2 * 2)
        try rgb.resize(width: targetWidth, height: targetHeight, bytesPerPixel: 4)
        guard CVPixelBufferLockBaseAddress(input, .readOnly) == kCVReturnSuccess else {
            throw ScreenFrameConversionError.invalidBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(input)
        if format == kCVPixelFormatType_32BGRA {
            guard !CVPixelBufferIsPlanar(input), let address = CVPixelBufferGetBaseAddress(input),
                  CVPixelBufferGetBytesPerRow(input) >= width * 4 else { throw ScreenFrameConversionError.invalidBuffer }
            var source = vImage_Buffer(data: address, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: CVPixelBufferGetBytesPerRow(input))
            try checked(vImageScale_ARGB8888(&source, &rgb.buffer, nil, vImage_Flags(kvImageNoFlags)))
        } else if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                    format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            guard width % 2 == 0, height % 2 == 0, CVPixelBufferGetPlaneCount(input) == 2,
                  CVPixelBufferGetWidthOfPlane(input, 0) == width, CVPixelBufferGetHeightOfPlane(input, 0) == height,
                  CVPixelBufferGetWidthOfPlane(input, 1) == width / 2,
                  CVPixelBufferGetHeightOfPlane(input, 1) == height / 2,
                  CVPixelBufferGetBytesPerRowOfPlane(input, 0) >= width,
                  CVPixelBufferGetBytesPerRowOfPlane(input, 1) >= width,
                  let yAddress = CVPixelBufferGetBaseAddressOfPlane(input, 0),
                  let uvAddress = CVPixelBufferGetBaseAddressOfPlane(input, 1) else {
                throw ScreenFrameConversionError.invalidBuffer
            }
            try y.resize(width: targetWidth, height: targetHeight, bytesPerPixel: 1)
            try uv.resize(width: targetWidth / 2, height: targetHeight / 2, bytesPerPixel: 2)
            var sourceY = vImage_Buffer(data: yAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                        rowBytes: CVPixelBufferGetBytesPerRowOfPlane(input, 0))
            var sourceUV = vImage_Buffer(data: uvAddress, height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2),
                                         rowBytes: CVPixelBufferGetBytesPerRowOfPlane(input, 1))
            try checked(vImageScale_Planar8(&sourceY, &y.buffer, nil, vImage_Flags(kvImageNoFlags)))
            try checked(vImageScale_CbCr8(&sourceUV, &uv.buffer, nil, vImage_Flags(kvImageNoFlags)))
            let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            var range = vImage_YpCbCrPixelRange(Yp_bias: fullRange ? 0 : 16, CbCr_bias: 128,
                YpRangeMax: fullRange ? 255 : 235, CbCrRangeMax: fullRange ? 255 : 240,
                YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            let matrixAttachment = CVBufferCopyAttachment(input, kCVImageBufferYCbCrMatrixKey, nil)
            let kr: Float, kb: Float
            if let matrixAttachment, CFEqual(matrixAttachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
                kr = 0.299; kb = 0.114
            } else if let matrixAttachment, CFEqual(matrixAttachment, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
                kr = 0.2627; kb = 0.0593
            } else { kr = 0.2126; kb = 0.0722 }
            // Local coefficient values avoid Swift 6 sharing mutable C global pointer variables.
            let kg = 1 - kr - kb
            var matrix = vImage_YpCbCrToARGBMatrix(Yp: 1, Cr_R: 2 * (1 - kr),
                Cr_G: -2 * kr * (1 - kr) / kg, Cb_G: -2 * kb * (1 - kb) / kg, Cb_B: 2 * (1 - kb))
            var conversion = vImage_YpCbCrToARGB()
            try checked(vImageConvert_YpCbCrToARGB_GenerateConversion(&matrix, &range, &conversion,
                kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)))
            try checked(vImageConvert_420Yp8_CbCr8ToARGB8888(&y.buffer, &uv.buffer, &rgb.buffer, &conversion,
                                                           [3, 2, 1, 0], 255, vImage_Flags(kvImageNoFlags)))
        } else { throw ScreenFrameConversionError.unsupportedFormat }

        // EXIF describes transforms of the stored image, not UIDeviceOrientation. vImage's
        // rotation constant counts counterclockwise quarter turns; mirrored variants reflect
        // horizontally after rotation. This also covers EXIF transpose/transverse (5 and 7).
        let transform: (rotation: UInt8, reflected: Bool)
        switch orientation {
        case .up: transform = (0, false)
        case .upMirrored: transform = (0, true)
        case .down: transform = (2, false)
        case .downMirrored: transform = (2, true)
        case .leftMirrored: transform = (3, true)
        case .right: transform = (3, false)
        case .rightMirrored: transform = (1, true)
        case .left: transform = (1, false)
        @unknown default: throw ScreenFrameConversionError.invalidBuffer
        }
        let swapped = transform.rotation % 2 == 1
        let outputWidth = swapped ? targetHeight : targetWidth
        let outputHeight = swapped ? targetWidth : targetHeight
        let bytes = outputWidth * outputHeight * 4
        guard let address = malloc(bytes) else { throw ScreenFrameConversionError.allocation }
        var ownsAddress = true
        defer { if ownsAddress { free(address) } }
        var output = vImage_Buffer(data: address, height: vImagePixelCount(outputHeight),
                                   width: vImagePixelCount(outputWidth), rowBytes: outputWidth * 4)
        try checked(vImageRotate90_ARGB8888(&rgb.buffer, &output, transform.rotation, [0, 0, 0, 255], vImage_Flags(kvImageNoFlags)))
        if transform.reflected {
            // vImage reflect is not in-place. Reuse the bounded RGB scratch after rotation.
            try rgb.resize(width: outputWidth, height: outputHeight, bytesPerPixel: 4)
            try checked(vImageHorizontalReflect_ARGB8888(&output, &rgb.buffer, vImage_Flags(kvImageNoFlags)))
            memcpy(address, rgb.buffer.data, bytes)
        }
        let pixels = Data(bytesNoCopy: address, count: bytes, deallocator: .free); ownsAddress = false
        return ScreenBroadcastFrame(sessionID: sessionID, width: outputWidth, height: outputHeight,
            rowBytes: outputWidth * 4, timestampNs: timestampNs, pixels: pixels)
    }

    private func checked(_ result: vImage_Error) throws {
        guard result == kvImageNoError else { throw ScreenFrameConversionError.conversion }
    }
}

private final class OwnedImageBuffer {
    var buffer = vImage_Buffer()
    private var capacity = 0
    deinit { free(buffer.data) }
    func resize(width: Int, height: Int, bytesPerPixel: Int) throws {
        if buffer.width == width, buffer.height == height, buffer.rowBytes == width * bytesPerPixel { return }
        let required = width * height * bytesPerPixel
        if capacity < required {
            free(buffer.data); buffer = vImage_Buffer(); capacity = 0
            guard let address = malloc(required) else { throw ScreenFrameConversionError.allocation }
            buffer.data = address; capacity = required
        }
        let address = buffer.data
        buffer = vImage_Buffer(data: address, height: vImagePixelCount(height), width: vImagePixelCount(width),
                               rowBytes: width * bytesPerPixel)
    }
}
