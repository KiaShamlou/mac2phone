import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders the bundled brand icon, with a drawn fallback for an invalid image.
enum IconMaker {
    static func makePNG(size: Int = 180) -> Data {
        guard (1...1024).contains(size) else { return Data() }
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil,
                                  width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }

        // Installed apps keep resources inside Contents/Resources; SwiftPM uses
        // its generated resource bundle when running from a build or test.
        let iconURL = Bundle.main.url(forResource: "WebIcon", withExtension: "png")
            ?? Bundle.module.url(forResource: "WebIcon", withExtension: "png")
        if let url = iconURL,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: s, height: s))
            return pngData(from: ctx)
        }

        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        // Laptop screen
        let screen = CGRect(x: s * 0.16, y: s * 0.40, width: s * 0.68, height: s * 0.42)
        ctx.setFillColor(CGColor(red: 0.29, green: 0.56, blue: 0.98, alpha: 1))
        ctx.addPath(CGPath(roundedRect: screen, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil))
        ctx.fillPath()

        // Laptop base
        ctx.setFillColor(CGColor(red: 0.55, green: 0.60, blue: 0.70, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: s * 0.10, y: s * 0.32, width: s * 0.80, height: s * 0.06),
                           cornerWidth: s * 0.02, cornerHeight: s * 0.02, transform: nil))
        ctx.fillPath()

        // Phone in front
        let phone = CGRect(x: s * 0.58, y: s * 0.12, width: s * 0.24, height: s * 0.44)
        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1))
        ctx.addPath(CGPath(roundedRect: phone.insetBy(dx: -s * 0.022, dy: -s * 0.022),
                           cornerWidth: s * 0.07, cornerHeight: s * 0.07, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.45, green: 0.85, blue: 0.72, alpha: 1))
        ctx.addPath(CGPath(roundedRect: phone, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil))
        ctx.fillPath()

        return pngData(from: ctx)
    }

    private static func pngData(from ctx: CGContext) -> Data {
        guard let image = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
