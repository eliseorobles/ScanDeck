import CoreGraphics
import Foundation
import ScanDeckCore
import ScanDeckImagePipeline

/// Where a master's published crop falls, and how big the master is.
///
/// Both halves are needed: the rect is in master pixels while previews are
/// downsampled, so without the source size the crop cannot be placed on the
/// preview at all.
struct PublishedCrop: Equatable, Hashable, Sendable {
    let bounds: PixelRect
    let sourceWidth: Int
    let sourceHeight: Int
}

/// Bounded, request-deduplicated preview cache for the review grid.
///
/// Masters stay on disk; only downsampled previews live in memory, and `NSCache`
/// evicts them under pressure. Concurrent requests for the same master share one
/// decode, which matters because a card's front and back become visible
/// together and SwiftUI may ask for the same preview several times while the
/// grid settles.
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private final class Entry {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    /// A preview is identified by its master, the crop it shows, *and* the tone
    /// curve applied to it, so the uncropped preview served before analysis
    /// finishes is replaced once the crop is known — and so moving the
    /// brightness slider does not serve back the previous setting's pixels from
    /// the cache. Leaving brightness out of this key is the whole feature
    /// failing silently: the file would change and the grid would not.
    private struct PreviewKey: Hashable {
        let url: URL
        let crop: PublishedCrop?
        let brightness: BrightnessAdjustment

        var cacheKey: NSString {
            let tone = brightness.isIdentity
                ? ""
                : "#tone=\(brightness.amount)"
            guard let crop else {
                return (url.absoluteString + tone) as NSString
            }
            return "\(url.absoluteString)#crop=\(crop.bounds.x),\(crop.bounds.y)"
                .appending(",\(crop.bounds.width),\(crop.bounds.height)")
                .appending(tone)
                as NSString
        }
    }

    private let cache = NSCache<NSString, Entry>()
    private var inFlight: [PreviewKey: Task<CGImage?, Never>] = [:]
    private let maximumPixelSize: Int
    private let decode: @Sendable (URL, Int, BrightnessAdjustment) throws -> CGImage

    /// `decode` exists so a test can count disk reads. Proving "the repeat
    /// request came from the cache" by deleting the master and reading again
    /// made `NSCache`'s eviction policy load-bearing — and `NSCache` may evict
    /// whenever memory pressure says so, which parallel test runs provide.
    init(
        maximumPixelSize: Int = ThumbnailDecoder.defaultMaximumPixelSize,
        memoryLimitBytes: Int = 128 * 1_024 * 1_024,
        decode: @escaping @Sendable (URL, Int, BrightnessAdjustment) throws
            -> CGImage = {
            try ThumbnailDecoder.decode(
                contentsOf: $0,
                maximumPixelSize: $1,
                brightness: $2
            )
        }
    ) {
        self.maximumPixelSize = maximumPixelSize
        self.decode = decode
        cache.totalCostLimit = memoryLimitBytes
    }

    /// A preview of `url`, trimmed to `croppedTo` once the crop is known.
    ///
    /// Passing the crop is what makes review honest. On a card-sized item the
    /// master is mostly scanner background, so an uncropped preview shows the
    /// operator something that is not the file being published — a good scan
    /// reads as a bad one, and a genuinely bad crop is invisible.
    func thumbnail(
        for url: URL,
        croppedTo crop: PublishedCrop? = nil,
        brightness: BrightnessAdjustment = .identity
    ) async -> CGImage? {
        let key = PreviewKey(url: url, crop: crop, brightness: brightness)
        if let cached = cache.object(forKey: key.cacheKey) {
            return cached.image
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let maximumPixelSize = maximumPixelSize
        let decode = decode
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let decoded = try? decode(
                url,
                maximumPixelSize,
                brightness
            ) else {
                return nil
            }
            guard let crop else {
                return decoded
            }
            return Self.trim(decoded, to: crop) ?? decoded
        }
        inFlight[key] = task

        let image = await task.value
        inFlight.removeValue(forKey: key)

        if let image {
            cache.setObject(
                Entry(image),
                forKey: key.cacheKey,
                cost: image.bytesPerRow * image.height
            )
        }
        return image
    }

    /// Places the master's crop onto an already-downsampled preview.
    ///
    /// Scaled by the size the decoder actually produced rather than the size
    /// that was requested: `CGImageSourceCreateThumbnailAtIndex` picks its own
    /// dimensions, and assuming otherwise shifts the crop by a few percent —
    /// enough to shave the real background border off one edge, which is
    /// precisely the thing the operator is looking at.
    private nonisolated static func trim(
        _ image: CGImage,
        to crop: PublishedCrop
    ) -> CGImage? {
        guard crop.sourceWidth > 0, crop.sourceHeight > 0,
              crop.bounds.width > 0, crop.bounds.height > 0
        else {
            return nil
        }

        let scaleX = Double(image.width) / Double(crop.sourceWidth)
        let scaleY = Double(image.height) / Double(crop.sourceHeight)

        let rect = CGRect(
            x: (Double(crop.bounds.x) * scaleX).rounded(.down),
            y: (Double(crop.bounds.y) * scaleY).rounded(.down),
            width: (Double(crop.bounds.width) * scaleX).rounded(.toNearestOrAwayFromZero),
            height: (Double(crop.bounds.height) * scaleY).rounded(.toNearestOrAwayFromZero)
        )
        .intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )

        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
            return nil
        }
        return image.cropping(to: rect)
    }
}
