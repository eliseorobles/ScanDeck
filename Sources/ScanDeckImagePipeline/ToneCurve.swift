import CoreGraphics
import Foundation
import ScanDeckCore

/// Applies a ``BrightnessAdjustment`` to already-cropped pixels.
///
/// **Nothing here may run before detection.** `CardImageCropper.analyze`,
/// `detectBounds` and `supportedBounds` read the decoded original, and
/// TICKET-019's occupancy constants — along with the 24 px and 140 px pair
/// thresholds — were fitted against raw, streaked captures at that exact tone.
/// Moving the background-to-foreground separation under those constants would
/// not be a smaller version of this feature; it would be a silent
/// recalibration of the detector, invisible until a batch published wrong.
/// This is the same ordering argument that makes TICKET-039's deskew safe:
/// detect on the original, then transform.
///
/// So the curve is the last thing that touches a published pixel, after the
/// crop and after the rotation, immediately before the encode.
enum ToneCurve {
    /// Returns `image` with `adjustment` applied to every colour channel.
    ///
    /// At the identity this returns the input untouched — not a copy that
    /// happens to be equal, the same image — so a batch published with the
    /// control at rest is byte-identical to one published before the control
    /// existed.
    static func apply(
        _ adjustment: BrightnessAdjustment,
        to image: CGImage
    ) throws -> CGImage {
        guard !adjustment.isIdentity else {
            return image
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return image
        }

        // Drawn into a context ScanDeck owns rather than mutating whatever
        // buffer the decoder handed back: a `CGImage` may be immutable, backed
        // by a shared data provider, or in a pixel format that is not eight
        // bits per channel. The format below matches what `rotate` and `square`
        // already build, so the encode sees one shape whichever path produced
        // the crop.
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw CardImageCropperError.cannotCreateImageContext
        }

        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        guard let data = context.data else {
            throw CardImageCropperError.cannotCreateImageContext
        }

        let table = adjustment.lookupTable()
        let pixels = data.bindMemory(
            to: UInt8.self,
            capacity: bytesPerRow * height
        )

        // Rewritten in place, one table read per channel. The fourth byte of
        // each pixel is the skipped alpha and is deliberately left alone —
        // mapping it would be meaningless here and misleading anywhere this
        // format later gains real alpha.
        table.withUnsafeBufferPointer { lookup in
            for offset in stride(from: 0, to: bytesPerRow * height, by: 4) {
                pixels[offset] = lookup[Int(pixels[offset])]
                pixels[offset + 1] = lookup[Int(pixels[offset + 1])]
                pixels[offset + 2] = lookup[Int(pixels[offset + 2])]
            }
        }

        guard let adjusted = context.makeImage() else {
            throw CardImageCropperError.cannotCropImage
        }
        return adjusted
    }
}
