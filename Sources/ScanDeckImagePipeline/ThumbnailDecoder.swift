import CoreGraphics
import Foundation
import ImageIO
import ScanDeckCore

public enum ThumbnailDecoderError: Error, Equatable, LocalizedError, Sendable {
    case unreadableImage
    case cannotDecodeThumbnail

    public var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "This scan could not be opened for preview."
        case .cannotDecodeThumbnail:
            "A preview could not be generated for this scan."
        }
    }
}

/// Decodes a bounded preview straight from disk.
///
/// `SPEC.md` section 6.3 forbids binding full-resolution masters to the review
/// grid. A 600 dpi duplex card is roughly 2,000 × 2,800 pixels per side, so a
/// hundred-card batch would hold gigabytes of decoded pixels while the operator
/// is still reviewing it. `CGImageSourceCreateThumbnailAtIndex` decodes *at* the
/// requested size rather than decoding the master and shrinking it afterwards,
/// so the full image never exists in memory.
public enum ThumbnailDecoder {
    /// The review-grid preview size from `SPEC.md` section 6.3.
    public static let defaultMaximumPixelSize = 512

    /// - Parameter brightness: The same curve publication will bake in. The
    ///   preview is the operator's only chance to see the adjustment before
    ///   committing to it, so it must be the identical mapping and not a
    ///   display-layer approximation of it — a slider that lies about its own
    ///   result is worse than no slider.
    public static func decode(
        contentsOf url: URL,
        maximumPixelSize: Int = defaultMaximumPixelSize,
        brightness: BrightnessAdjustment = .identity
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ThumbnailDecoderError.unreadableImage
        }

        let options: [CFString: Any] = [
            // Without this, ImageIO returns only an embedded thumbnail when the
            // file happens to carry one, and nothing otherwise.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Normalises EXIF orientation. Operator rotation is applied
            // separately in review and must not be baked in here.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw ThumbnailDecoderError.cannotDecodeThumbnail
        }
        return try ToneCurve.apply(brightness, to: thumbnail)
    }
}
