import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct Screenshot {
    let image: CGImage
    /// Pixels per point of the captured display (2 on Retina).
    let scale: CGFloat
}

enum Screenshotter {
    /// One-shot capture. No stream is kept alive, so there's nothing running between shots.
    static func capture(_ selection: CaptureSelection, showsCursor: Bool) async throws -> Screenshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target = try CaptureTarget.make(for: selection, content: content)

        let config = SCStreamConfiguration()
        target.apply(to: config)
        config.showsCursor = showsCursor
        // Tag with Display P3 like macOS's own screenshots, so wide-gamut colors aren't clipped to sRGB.
        config.colorSpaceName = CGColorSpace.displayP3
        // Window captures: clean cut-out with transparent rounded corners, no shadow padding.
        config.ignoreShadowsSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: target.filter, configuration: config)
        return Screenshot(image: image, scale: CGFloat(target.filter.pointPixelScale))
    }
}

enum ImageEncoder {
    /// PNG encoding is the only CPU-heavy step, so it runs off the main thread.
    ///
    /// The DPI tag (72 × scale, so 144 on Retina) is what keeps it crisp: without it apps assume
    /// 72 DPI and show a Retina capture at double size, i.e. upscaled 2× and soft. macOS's own
    /// screenshots are tagged the same way.
    static func png(_ shot: Screenshot) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw CaptureError.encodingFailed
            }
            let dpi = 72 * max(1, shot.scale)
            let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
            CGImageDestinationAddImage(dest, shot.image, properties)
            guard CGImageDestinationFinalize(dest) else { throw CaptureError.encodingFailed }
            return data as Data
        }.value
    }

    static func write(_ data: Data, to folder: URL, prefix: String) async throws -> URL {
        let url = try FileNaming.nextURL(in: folder, prefix: prefix, ext: "png")
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: url, options: .atomic)
        }.value
        return url
    }

    static func copyToClipboard(_ png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    /// Small copy for the HUD so it doesn't hold or redraw a full 5K frame.
    static func thumbnail(_ image: CGImage, maxPixel: Int = 360) -> NSImage? {
        let scale = min(1, CGFloat(maxPixel) / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale))
        let h = max(1, Int(CGFloat(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: w, height: h))
    }
}

@MainActor
enum CaptureSound {
    private static let shutter: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Pop")
    }()

    static func play() {
        shutter?.stop()
        shutter?.play()
    }
}
