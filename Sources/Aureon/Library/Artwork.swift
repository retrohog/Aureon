import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Embedded cover art (FLAC picture blocks, ID3, iTunes atoms) as a small JPEG, for the remote app and list views.
enum Artwork {
    static func embeddedData(path: String) async -> Data? { await MetadataEngine.artwork(path: path) }

    /// Scales image data so its longest side is at most `maxPixel` and re-encodes it as JPEG.
    static func thumbnail(_ data: Data, maxPixel: Int, quality: Double = 0.8) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    static func thumbnail(path: String, maxPixel: Int) async -> Data? {
        guard let d = await embeddedData(path: path) else { return nil }
        return thumbnail(d, maxPixel: maxPixel)
    }
}
