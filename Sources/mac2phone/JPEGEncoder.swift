import Foundation
import CoreImage
import CoreVideo
import CoreGraphics
import ImageIO

/// Only used by the emergency browser fallback client.
final class JPEGEncoder {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let optionKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)

    var quality: Double = 0.6
    var maxWidth: Int = 1600

    func encode(_ pixelBuffer: CVPixelBuffer) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        if maxWidth > 0 && width > maxWidth {
            let scale = Double(maxWidth) / Double(width)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [optionKey: quality])
    }
}
