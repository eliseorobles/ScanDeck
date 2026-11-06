import CoreGraphics
import Foundation
import ImageIO
import ScanDeckCore
import UniformTypeIdentifiers

public struct PixelRect: Codable, Equatable, Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    fileprivate func intersection(width sourceWidth: Int, height sourceHeight: Int)
        -> PixelRect
    {
        let minimumX = max(0, x)
        let minimumY = max(0, y)
        let maximumX = min(sourceWidth, maxX)
        let maximumY = min(sourceHeight, maxY)
        return PixelRect(
            x: minimumX,
            y: minimumY,
            width: max(0, maximumX - minimumX),
            height: max(0, maximumY - minimumY)
        )
    }
}

public struct CropAnalysis: Codable, Equatable, Sendable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let dpi: Int
    /// The axis-aligned bounding box of the detected media, on the **original**
    /// pixels.
    ///
    /// Deskew deliberately does not change this. It is what
    /// `MarginAssessment.sufficient(mediaSize:)` carries into the reducer, so
    /// it is the input the 24 px / 140 px pair thresholds were calibrated on
    /// and the value every stored `AcceptedPairSizeMismatch` was recorded
    /// against — and `covers` is exact equality on both footprints, so
    /// redefining it would return every card an operator has overruled to
    /// blocked on the next launch. The squared footprint is derivable from
    /// this and `tiltDegrees` for anything that wants it.
    public let mediaBounds: PixelRect
    /// The region of the source the published image is taken from. When
    /// `tiltDegrees` is non-nil this is the **bounding box** of a rotated
    /// rectangle rather than the rectangle itself, which makes the containment
    /// test conservative: a card refused here would in fact have fitted. That
    /// is the safe direction for invariant #2, and the margin it costs is
    /// ~60 px at 3° against a measured worst-case clearance of 296 px.
    public let requestedCropBounds: PixelRect
    public let availableCropBounds: PixelRect
    public let requestedInsets: PixelInsets
    public let insufficientEdges: Set<ScanEdge>
    public let threshold: UInt8
    public let confidence: Double
    /// How the published image will be squared, or `nil` to copy pixels
    /// through untouched.
    ///
    /// `nil` is the honest answer in five distinct cases, all decided in
    /// `MediaTiltEstimator`: the media's edges could not be fitted, fewer than
    /// four of them were, they disagree, the angle is below the floor where
    /// correcting it would be fitting noise, or it is past the ceiling where
    /// the sheet is misfed rather than tilted. In every one of them the card
    /// publishes exactly as it did before deskew existed.
    public let deskew: Deskew?

    public struct Deskew: Codable, Equatable, Sendable {
        public let angleDegrees: Double
        /// The media's centre and true side lengths, measured from where its
        /// four edges lie rather than inferred from `mediaBounds` — see
        /// `MediaTiltEstimator.Reading.squaredRectangle`.
        public let centreX: Double
        public let centreY: Double
        public let mediaWidth: Double
        public let mediaHeight: Double
    }

    public var tiltDegrees: Double? { deskew?.angleDegrees }
    /// The published image's pixel dimensions. Equal to `requestedCropBounds`
    /// when nothing is rotated; smaller than it when something is, because a
    /// squared crop fits inside the bounding box of its own rotation.
    public let outputWidth: Int
    public let outputHeight: Int

    public var isPublishable: Bool {
        insufficientEdges.isEmpty
            && requestedCropBounds == availableCropBounds
    }
}

public struct CropOutput: Equatable, Sendable {
    public let analysis: CropAnalysis
    public let outputURL: URL
}

public enum CardImageCropperError: Error, LocalizedError, Equatable, Sendable {
    case unreadableImage
    case unsupportedOrientation(Int)
    case invalidImageFormat
    case noMediaDetected
    case ambiguousMediaBounds
    case insufficientRealBackground(Set<ScanEdge>)
    case cannotCreateImageContext
    case cannotCropImage
    case cannotCreateDestination
    case cannotWriteDestination

    public var errorDescription: String? {
        switch self {
        case .unreadableImage:
            "The captured image could not be read."
        case let .unsupportedOrientation(value):
            "The captured image uses unsupported EXIF orientation \(value)."
        case .invalidImageFormat:
            "The captured image is not an 8-bit RGB image."
        case .noMediaDetected:
            "No card or holder could be separated from the black background."
        case .ambiguousMediaBounds:
            "The card or holder boundary is ambiguous. Retry the scan."
        case let .insufficientRealBackground(edges):
            "The scan does not contain the requested real background at "
                + edges.map(\.rawValue).sorted().joined(separator: ", ")
                + "."
        case .cannotCreateImageContext:
            "The image-analysis buffer could not be created."
        case .cannotCropImage:
            "The detected crop could not be applied."
        case .cannotCreateDestination:
            "The JPEG destination could not be created."
        case .cannotWriteDestination:
            "The cropped JPEG could not be written."
        }
    }
}

/// Finds the outermost physical item against the PFU driver's black scan
/// background, then retains the requested amount of *captured* background.
/// It never pads or invents pixels.
public struct CardImageCropper: Sendable {
    public init() {}

    public func analyze(
        sourceURL: URL,
        margins: ScanMargins = .cardDefault,
        dpi: Int = 600
    ) throws -> CropAnalysis {
        try analyze(
            decoded: try decode(sourceURL),
            margins: margins,
            dpi: dpi
        )
    }

    /// The analysis, given pixels somebody has already paid for.
    ///
    /// `crop` used to call the public entry point and then decode the same
    /// master a second time to get the image back — two full decodes of a
    /// 3232 × 4248 master, 55 MB of pixels each, for every published file.
    /// Serially that was invisible; four-way it is four times the transient
    /// footprint, and publication is the one place that does it 800 times in
    /// a row (TICKET-035).
    func analyze(
        decoded: DecodedImage,
        margins: ScanMargins,
        dpi: Int
    ) throws -> CropAnalysis {
        let requestedInsets = try margins.pixels(atDPI: dpi)
        let background = estimateBackground(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height
        )
        let threshold = UInt8(
            min(
                255,
                max(12, Int(background.residualThreshold) + 4)
            )
        )

        let primary = try detectBounds(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height,
            background: background.color,
            threshold: threshold,
            dpi: dpi
        )
        let strongerThreshold = UInt8(min(255, max(24, Int(threshold) * 2)))
        let stronger = try? detectBounds(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height,
            background: background.color,
            threshold: strongerThreshold,
            dpi: dpi
        )

        // Which detection to believe when the two disagree.
        //
        // Occupancy-profile bounds make both thresholds robust against thin
        // bright artefacts (see `supportedBounds`), so on real captures the
        // two reads almost always land on the same rect: 364 of the
        // operator's 372 sides agree to within 15 px, at a median of 1 px.
        // Within `maximumEdgeFadePixels` the disagreement is a genuine edge
        // fading out between the thresholds and the permissive read is the
        // accurate one — it sees the whole edge, and everything past it is
        // still genuine captured background, so invariant #2 holds either way.
        //
        // Past that line the two reads are not disagreeing about where an
        // edge stopped being visible, they are disagreeing about what the
        // media *is*. A smear broad enough to carry whole rows over the
        // support floor at threshold 12 vanishes at 24 — measured:
        // 1822 × 3972 px permissively against 1821 × 2417 px conservatively,
        // the latter matching the card's other side to a pixel. Three of the
        // 372 sides land there, and all eight that moved even 16 px moved the
        // same way round — the permissive read inflated, never the
        // conservative one amputating — so the conservative read wins. The old
        // behaviour, throwing, made a perfectly good scan unpublishable and
        // told the operator all four margins were short.
        let consensusWindow = Self.maximumEdgeFadePixels(dpi: dpi)
        let mediaBounds: PixelRect
        let confidence: Double
        // Tracked so the tilt is fitted at the same threshold that produced
        // the bounds it is fitted inside. Measuring a conservative rect with
        // permissive pixels would read the artefact the consensus rule just
        // rejected.
        let mediaThreshold: UInt8
        if let stronger {
            let maximumMovement = [
                abs(primary.x - stronger.x),
                abs(primary.y - stronger.y),
                abs(primary.maxX - stronger.maxX),
                abs(primary.maxY - stronger.maxY),
            ].max() ?? 0

            if maximumMovement <= consensusWindow {
                mediaBounds = primary
                mediaThreshold = threshold
                confidence = max(
                    0.4,
                    1 - Double(maximumMovement) / Double(consensusWindow + 1)
                )
            } else {
                mediaBounds = stronger
                mediaThreshold = strongerThreshold
                // Reported low so review can single these out once there is a
                // surface for it, rather than passing silently as a clean read.
                confidence = 0.4
            }
        } else {
            mediaBounds = primary
            mediaThreshold = threshold
            confidence = 0.72
        }

        // Tilt is measured here: after detection, on the original pixels, and
        // never before either. TICKET-019's occupancy constants were measured
        // against streaked, unresampled captures, and TICKET-039 rejected the
        // driver's own streak filter for precisely that reason — resampling
        // upstream of `detectBounds` would have been the same mistake by
        // another route.
        let tiltReading = MediaTiltEstimator.measure(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height,
            bounds: mediaBounds,
            background: background.color,
            threshold: mediaThreshold
        )
        let deskew = MediaTiltEstimator
            .correctableAngle(from: tiltReading)
            .flatMap { angle in
                tiltReading.squaredRectangle(within: mediaBounds)
                    .map {
                        CropAnalysis.Deskew(
                            angleDegrees: angle,
                            centreX: $0.centreX,
                            centreY: $0.centreY,
                            mediaWidth: $0.width,
                            mediaHeight: $0.height
                        )
                    }
            }

        let requested: PixelRect
        let outputWidth: Int
        let outputHeight: Int
        if let deskew {
            let geometry = Self.squaredCropGeometry(
                deskew: deskew,
                insets: requestedInsets
            )
            requested = geometry.boundingBox
            outputWidth = geometry.outputWidth
            outputHeight = geometry.outputHeight
        } else {
            requested = PixelRect(
                x: mediaBounds.x - requestedInsets.left,
                y: mediaBounds.y - requestedInsets.top,
                width: mediaBounds.width
                    + requestedInsets.left
                    + requestedInsets.right,
                height: mediaBounds.height
                    + requestedInsets.top
                    + requestedInsets.bottom
            )
            outputWidth = requested.width
            outputHeight = requested.height
        }
        let available = requested.intersection(
            width: decoded.width,
            height: decoded.height
        )

        var insufficientEdges: Set<ScanEdge> = []
        if requested.x < 0 {
            insufficientEdges.insert(.left)
        }
        if requested.y < 0 {
            insufficientEdges.insert(.top)
        }
        if requested.maxX > decoded.width {
            insufficientEdges.insert(.right)
        }
        if requested.maxY > decoded.height {
            insufficientEdges.insert(.bottom)
        }

        return CropAnalysis(
            sourceWidth: decoded.width,
            sourceHeight: decoded.height,
            dpi: dpi,
            mediaBounds: mediaBounds,
            requestedCropBounds: requested,
            availableCropBounds: available,
            requestedInsets: requestedInsets,
            insufficientEdges: insufficientEdges,
            threshold: threshold,
            confidence: confidence,
            deskew: deskew,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )
    }

    /// Where a squared crop lands in the source, and how big it comes out.
    ///
    /// The output rectangle is the media's measured footprint grown by the
    /// requested insets, then rotated back into source coordinates about the
    /// media's measured centre.
    ///
    /// The returned bounding box is what the containment test uses, which is
    /// deliberately conservative — see `CropAnalysis.requestedCropBounds`.
    static func squaredCropGeometry(
        deskew: CropAnalysis.Deskew,
        insets: PixelInsets
    ) -> (boundingBox: PixelRect, outputWidth: Int, outputHeight: Int) {
        let centreX = deskew.centreX
        let centreY = deskew.centreY
        let leftEdge = -deskew.mediaWidth / 2 - Double(insets.left)
        let rightEdge = deskew.mediaWidth / 2 + Double(insets.right)
        let topEdge = -deskew.mediaHeight / 2 - Double(insets.top)
        let bottomEdge = deskew.mediaHeight / 2 + Double(insets.bottom)

        let radians = deskew.angleDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        var minimumX = Double.greatestFiniteMagnitude
        var minimumY = Double.greatestFiniteMagnitude
        var maximumX = -Double.greatestFiniteMagnitude
        var maximumY = -Double.greatestFiniteMagnitude
        for corner in [
            (leftEdge, topEdge), (rightEdge, topEdge),
            (rightEdge, bottomEdge), (leftEdge, bottomEdge),
        ] {
            let x = centreX + corner.0 * cosine - corner.1 * sine
            let y = centreY + corner.0 * sine + corner.1 * cosine
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }

        let boxX = Int(minimumX.rounded(.down))
        let boxY = Int(minimumY.rounded(.down))
        return (
            boundingBox: PixelRect(
                x: boxX,
                y: boxY,
                width: Int(maximumX.rounded(.up)) - boxX,
                height: Int(maximumY.rounded(.up)) - boxY
            ),
            outputWidth: Int((rightEdge - leftEdge).rounded()),
            outputHeight: Int((bottomEdge - topEdge).rounded())
        )
    }

    /// Writes a JPEG crop. Insufficient-margin scans are rejected unless this
    /// is explicitly a review preview, in which case the source intersection is
    /// written and the analysis remains marked non-publishable.
    @discardableResult
    public func crop(
        sourceURL: URL,
        destinationURL: URL,
        margins: ScanMargins = .cardDefault,
        dpi: Int = 600,
        quality: Double = 0.95,
        rotation: QuarterTurns = .zero,
        brightness: BrightnessAdjustment = .identity,
        allowInsufficientPreview: Bool = false
    ) throws -> CropOutput {
        let decoded = try decode(sourceURL)
        let analysis = try analyze(
            decoded: decoded,
            margins: margins,
            dpi: dpi
        )
        if !analysis.insufficientEdges.isEmpty, !allowInsufficientPreview {
            throw CardImageCropperError.insufficientRealBackground(
                analysis.insufficientEdges
            )
        }

        let cropBounds = analysis.isPublishable
            ? analysis.requestedCropBounds
            : analysis.availableCropBounds
        guard cropBounds.width > 0, cropBounds.height > 0 else {
            throw CardImageCropperError.cannotCropImage
        }

        let cropped: CGImage
        if analysis.isPublishable, let deskew = analysis.deskew {
            cropped = try square(
                decoded.image,
                deskew: deskew,
                outputWidth: analysis.outputWidth,
                outputHeight: analysis.outputHeight,
                insets: analysis.requestedInsets
            )
        } else {
            // Untilted, or a review preview of a crop that cannot publish. A
            // preview of a broken crop gains nothing from being squared, and
            // this path copies pixels through without resampling them — which
            // is what keeps a card below the tilt floor byte-identical to what
            // it was before deskew existed.
            guard let extracted = decoded.image.cropping(
                to: CGRect(
                    x: cropBounds.x,
                    y: cropBounds.y,
                    width: cropBounds.width,
                    height: cropBounds.height
                )
            ) else {
                throw CardImageCropperError.cannotCropImage
            }
            cropped = extracted
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CardImageCropperError.cannotCreateDestination
        }

        let clampedQuality = min(1, max(0, quality))
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: clampedQuality,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyJFIFDictionary: [
                kCGImagePropertyJFIFXDensity: dpi,
                kCGImagePropertyJFIFYDensity: dpi,
                kCGImagePropertyJFIFDensityUnit: 1,
            ],
        ]
        // Crop → rotate → encode, the order `SPEC.md` section 6.2 specifies.
        // Rotation is baked in here rather than written as EXIF orientation so
        // the published JPEG is correct in every consumer, including
        // carduploader.
        let oriented = try rotate(cropped, by: rotation)
        // Brightness goes last, after everything geometric has settled. Its
        // position relative to `rotate` does not change a pixel — a quarter
        // turn permutes pixels and the curve maps each one independently — but
        // its position relative to `analyze` is the entire safety argument, and
        // putting it here makes that impossible to get wrong by editing the
        // lines above. See `ToneCurve`.
        let toned = try ToneCurve.apply(brightness, to: oriented)
        CGImageDestinationAddImage(
            destination,
            toned,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CardImageCropperError.cannotWriteDestination
        }

        return CropOutput(analysis: analysis, outputURL: destinationURL)
    }
}

// Internal rather than private so the opt-in corpus diagnostics can observe
// the two threshold reads and the occupancy profiles that produced them. Every
// tuning decision recorded in this file was argued from those intermediates;
// a suite that can only see the final rect cannot re-derive them.
extension CardImageCropper {
    /// Rotates the media square and crops to the requested margin in a single
    /// resample.
    ///
    /// One pass, not two. TICKET-035 removed a double decode of every master
    /// because publication does it 800 times a batch, and a rotate bolted on
    /// after the crop would have put an equivalent cost straight back.
    ///
    /// **Nothing is padded.** The output rectangle is filled entirely by the
    /// source draw, because `analyze` has already proved every corner of it
    /// lies inside the captured frame — that is the whole reason ScanDeck can
    /// do this where PaperStream's own deskew must paint a chosen background
    /// colour into the corners rotation empties. The proof is load-bearing
    /// rather than decorative: this context is built with `data: nil`, so any
    /// region the draw failed to cover would come out black, and against a
    /// black scan background it would be invisible to the eye meant to catch
    /// it. `CardImageCropperDeskewTests` asserts the corners carry real
    /// captured background rather than trusting that.
    func square(
        _ image: CGImage,
        deskew: CropAnalysis.Deskew,
        outputWidth: Int,
        outputHeight: Int,
        insets: PixelInsets
    ) throws -> CGImage {
        guard outputWidth > 0, outputHeight > 0 else {
            throw CardImageCropperError.cannotCropImage
        }
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw CardImageCropperError.cannotCreateImageContext
        }
        // The border is the measurement, so the resample that produces it is
        // not left at whatever the default happens to be.
        context.interpolationQuality = .high

        // Core Graphics is y-up and `PixelRect` is y-down, so the media centre
        // flips and the correcting rotation comes out `+angle` rather than
        // `−angle`. `CardImageCropperDeskewTests` proves that sign by measuring
        // the tilt of the *output*: getting it backwards would double a card's
        // skew instead of removing it, and every published card would still
        // look entirely plausible.
        let centreX = deskew.centreX
        let centreY = Double(image.height) - deskew.centreY
        // Margins need not be symmetric, and when they are not the output's
        // centre is not the media's.
        let offsetX = Double(insets.right - insets.left) / 2
        let offsetY = Double(insets.top - insets.bottom) / 2

        context.translateBy(
            x: Double(outputWidth) / 2,
            y: Double(outputHeight) / 2
        )
        context.rotate(by: deskew.angleDegrees * .pi / 180)
        context.translateBy(x: -offsetX, y: -offsetY)
        context.draw(
            image,
            in: CGRect(
                x: -centreX,
                y: -centreY,
                width: Double(image.width),
                height: Double(image.height)
            )
        )

        guard let squared = context.makeImage() else {
            throw CardImageCropperError.cannotCropImage
        }
        return squared
    }

    /// Redraws the image at a quarter-turn rotation.
    func rotate(_ image: CGImage, by turns: QuarterTurns) throws -> CGImage {
        guard turns != .zero else {
            return image
        }

        let swapsAxes = turns == .clockwise90 || turns == .clockwise270
        let width = swapsAxes ? image.height : image.width
        let height = swapsAxes ? image.width : image.height

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw CardImageCropperError.cannotCreateImageContext
        }

        // Rotate about the destination centre, then draw the source centred on
        // the origin so no part of the image falls outside the context.
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns.rawValue) * .pi / 2)
        context.draw(
            image,
            in: CGRect(
                x: -CGFloat(image.width) / 2,
                y: -CGFloat(image.height) / 2,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )

        guard let rotated = context.makeImage() else {
            throw CardImageCropperError.cannotCropImage
        }
        return rotated
    }

    struct DecodedImage {
        let image: CGImage
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    struct BackgroundEstimate {
        let color: (red: UInt8, green: UInt8, blue: UInt8)
        let residualThreshold: UInt8
    }

    struct Component {
        var area = 0
        var minimumX = Int.max
        var minimumY = Int.max
        var maximumX = Int.min
        var maximumY = Int.min

        var rect: PixelRect {
            PixelRect(
                x: minimumX,
                y: minimumY,
                width: maximumX - minimumX + 1,
                height: maximumY - minimumY + 1
            )
        }
    }

    func decode(_ url: URL) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CardImageCropperError.unreadableImage
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?
            .intValue ?? 1
        guard orientation == 1 else {
            throw CardImageCropperError.unsupportedOrientation(orientation)
        }
        guard image.bitsPerComponent == 8,
              image.colorSpace?.model == .rgb
        else {
            throw CardImageCropperError.invalidImageFormat
        }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw CardImageCropperError.cannotCreateImageContext
        }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return DecodedImage(
            image: image,
            width: width,
            height: height,
            pixels: pixels
        )
    }

    func estimateBackground(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> BackgroundEstimate {
        let border = min(64, max(8, min(width, height) / 20))
        let stride = max(1, border / 8)
        var reds: [UInt8] = []
        var greens: [UInt8] = []
        var blues: [UInt8] = []

        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride)
            where x < border || x >= width - border
                || y < border || y >= height - border
            {
                let offset = (y * width + x) * 4
                reds.append(pixels[offset])
                greens.append(pixels[offset + 1])
                blues.append(pixels[offset + 2])
            }
        }

        func median(_ values: [UInt8]) -> UInt8 {
            guard !values.isEmpty else { return 0 }
            return values.sorted()[values.count / 2]
        }
        let background = (
            red: median(reds),
            green: median(greens),
            blue: median(blues)
        )

        var residuals: [UInt8] = []
        residuals.reserveCapacity(reds.count)
        for index in reds.indices {
            residuals.append(
                max(
                    absoluteDifference(reds[index], background.red),
                    absoluteDifference(greens[index], background.green),
                    absoluteDifference(blues[index], background.blue)
                )
            )
        }
        residuals.sort()
        let percentileIndex = min(
            residuals.count - 1,
            // An item may touch one scan edge. Use the darkest majority of
            // border samples so foreground along that edge cannot raise the
            // black-background noise floor.
            Int(Double(residuals.count) * 0.80)
        )
        return BackgroundEstimate(
            color: background,
            residualThreshold: residuals.isEmpty
                ? 0
                : residuals[percentileIndex]
        )
    }

    func detectBounds(
        pixels: [UInt8],
        width: Int,
        height: Int,
        background: (red: UInt8, green: UInt8, blue: UInt8),
        threshold: UInt8,
        dpi: Int
    ) throws -> PixelRect {
        let scale = 2
        let maskWidth = (width + scale - 1) / scale
        let maskHeight = (height + scale - 1) / scale
        var mask = [UInt8](
            repeating: 0,
            count: maskWidth * maskHeight
        )

        for blockY in 0..<maskHeight {
            let startY = blockY * scale
            let endY = min(height, startY + scale)
            for blockX in 0..<maskWidth {
                let startX = blockX * scale
                let endX = min(width, startX + scale)
                var foreground = false
                for y in startY..<endY {
                    for x in startX..<endX {
                        let offset = (y * width + x) * 4
                        let signal = max(
                            absoluteDifference(pixels[offset], background.red),
                            absoluteDifference(
                                pixels[offset + 1],
                                background.green
                            ),
                            absoluteDifference(
                                pixels[offset + 2],
                                background.blue
                            )
                        )
                        if signal > threshold {
                            foreground = true
                            break
                        }
                    }
                    if foreground { break }
                }
                mask[blockY * maskWidth + blockX] = foreground ? 1 : 0
            }
        }

        mask = close3x3(mask, width: maskWidth, height: maskHeight)
        let labeled = connectedComponents(
            mask,
            width: maskWidth,
            height: maskHeight
        )
        let minimumArea = max(32, maskWidth * maskHeight / 200)
        let viable = labeled.components.enumerated()
            .filter { $0.element.area >= minimumArea }
            .sorted { $0.element.area > $1.element.area }
        guard let dominant = viable.first else {
            throw CardImageCropperError.noMediaDetected
        }
        if viable.count > 1,
           viable[1].element.area * 2 >= dominant.element.area
        {
            throw CardImageCropperError.ambiguousMediaBounds
        }

        let coarse = supportedBounds(
            labels: labeled.labels,
            target: Int32(dominant.offset),
            width: maskWidth,
            height: maskHeight,
            dpi: dpi
        ) ?? dominant.element.rect
        var rect = PixelRect(
            x: coarse.x * scale,
            y: coarse.y * scale,
            width: min(width, coarse.maxX * scale) - coarse.x * scale,
            height: min(height, coarse.maxY * scale) - coarse.y * scale
        )
        rect = refine(
            coarse: rect,
            pixels: pixels,
            width: width,
            height: height,
            background: background,
            threshold: threshold
        )

        let areaRatio = Double(rect.width * rect.height)
            / Double(width * height)
        let centerX = Double(rect.x + rect.maxX) / 2
        let centerY = Double(rect.y + rect.maxY) / 2
        guard areaRatio >= 0.08,
              areaRatio <= 0.95,
              abs(centerX - Double(width) / 2) <= Double(width) * 0.4,
              abs(centerY - Double(height) / 2) <= Double(height) * 0.45
        else {
            throw CardImageCropperError.ambiguousMediaBounds
        }
        return rect
    }

    /// How far apart the two threshold reads may land before the permissive
    /// one stops being believed, in pixels. 96 px is 4 mm at 600 dpi.
    ///
    /// Measured across the operator's 372 real sides: **364 read within 15 px
    /// at both thresholds**, at a median of 1 px. The eight that moved
    /// further moved 17, 27, 38, 55, 86, 200, 378 and 382 px, and in every
    /// one of the eight it was the *permissive* read that an artefact had
    /// inflated — across all 372 the conservative threshold never came back
    /// more than 6 px wider or 1 px taller than the permissive one, so it
    /// amputates nothing. On that evidence alone the window wants to be
    /// tight, and tightening it to 24 px does take the corpus from three
    /// disagreeing pairs to two.
    ///
    /// It was tried, and the TICKET-024 tombstone refused it. That card's
    /// front reads 2423 px permissively and 2363 px conservatively — a
    /// genuine 60 px of faint open-end lip that only the permissive
    /// threshold sees — against a back that reads 2433 px at both. A 24 px
    /// window picks the conservative read and reinstates the exact 70 px
    /// amputation TICKET-024 was opened for. So a genuine edge really can
    /// fade 60 px between the thresholds, and the one corpus card a tighter
    /// window would rescue disagrees by 86 px: separating them means placing
    /// a line between 60 and 86 on two data points. That is a fit, not a
    /// finding, and the pair gate already catches what is left. The window
    /// stays where it was.
    static func maximumEdgeFadePixels(dpi: Int) -> Int {
        max(8, (96 * dpi + 300) / 600)
    }

    /// Bounds of the rows and columns that carry enough of the component to be
    /// media rather than artefact.
    ///
    /// A connected component's bounding box has no shape robustness: one
    /// bright streak touching the media stretches the box by the streak's full
    /// length, which is exactly how a real fi-8170 pass published a back
    /// 679 px taller than its own front — two ~10 px rear-side streaks ran
    /// from the frame's top edge into the toploader and survived even the
    /// conservative threshold. Occupancy profiles separate streak from media
    /// cleanly. Measured on that pass, rows crossing genuine media never fell
    /// below 13 mask blocks — a holder's interior is held up by its side
    /// glints — while rows crossing only the streaks never rose above 5, at
    /// either threshold, leaving the 6–12 band empty on both sides of the
    /// card. Columns run thinner, because only the holder's top and bottom
    /// edges cross them, so their floor sits lower; their measured gap is at
    /// 3–5 blocks.
    ///
    /// Extension walks outward from the strongest row and column, bridging
    /// gaps of at most `maximumBridgeGap` so a matte patch in a glint line
    /// cannot amputate a holder edge, and stopping at any wider void — the
    /// streaks' void measured ~340 blocks. A dense artefact wider than the
    /// row floor and closer than the bridge gap would still fool this; the
    /// two-threshold consensus in `analyze` stays on as the tripwire for that
    /// residue.
    func supportedBounds(
        labels: [Int32],
        target: Int32,
        width: Int,
        height: Int,
        dpi: Int
    ) -> PixelRect? {
        var rowOccupancy = [Int](repeating: 0, count: height)
        var columnOccupancy = [Int](repeating: 0, count: width)
        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<width where labels[rowStart + x] == target {
                rowOccupancy[y] += 1
                columnOccupancy[x] += 1
            }
        }

        // Calibrated at 600 dpi against the pass described above and scaled
        // for other densities; glint thickness shrinks with resolution.
        let rowSupportFloor = max(2, (8 * dpi + 300) / 600)
        let columnSupportFloor = max(2, (4 * dpi + 300) / 600)
        let maximumBridgeGap = max(4, (8 * dpi + 300) / 600)

        guard let anchorRow = rowOccupancy.indices.max(by: {
                  rowOccupancy[$0] < rowOccupancy[$1]
              }),
              let anchorColumn = columnOccupancy.indices.max(by: {
                  columnOccupancy[$0] < columnOccupancy[$1]
              }),
              rowOccupancy[anchorRow] >= rowSupportFloor,
              columnOccupancy[anchorColumn] >= columnSupportFloor
        else {
            return nil
        }

        let rows = extendSupport(
            rowOccupancy,
            from: anchorRow,
            floor: rowSupportFloor,
            maximumBridgeGap: maximumBridgeGap
        )
        let columns = extendSupport(
            columnOccupancy,
            from: anchorColumn,
            floor: columnSupportFloor,
            maximumBridgeGap: maximumBridgeGap
        )
        return PixelRect(
            x: columns.lowerBound,
            y: rows.lowerBound,
            width: columns.count,
            height: rows.count
        )
    }

    /// Floor-supported extension from the anchor: the outermost row (or
    /// column) that still carries `floor` blocks of the component, bridging
    /// voids no wider than `maximumBridgeGap` so a matte patch in a glint line
    /// cannot amputate a holder edge.
    ///
    /// Sub-floor occupancy past that bound is deliberately ignored, and this
    /// is the one rule in the detector that was decided by measurement rather
    /// than argued from a pair of scans. A faint-fringe pass used to extend
    /// the bound over any sub-floor occupancy that died out within a budget,
    /// on the theory that a toploader's open-end lip glints below the floor
    /// while a streak runs on to the frame edge. Run across the operator's
    /// 186 real pairs, that pass **caused 23 of the 26 pairs whose two sides
    /// disagreed** and rescued none: the losing side's fringe was typically
    /// a single occupied block per row sustained for 14–32 rows and then
    /// gone — 28–64 px of nothing, claimed as media by one camera and by
    /// neither the other camera nor the eye. Restricted to floor-supported
    /// rows the same corpus agrees on 183 of 186 pairs, against 160 before.
    ///
    /// There is no occupancy level that separates the two: the widest false
    /// fringe measured 2–6 blocks per row for 21 rows, which is the same
    /// shape the lip was described by. A single image does not carry the
    /// evidence, so the detector stops at what it can support and the
    /// reducer's pair cross-check arbitrates what is left.
    func extendSupport(
        _ occupancy: [Int],
        from anchor: Int,
        floor: Int,
        maximumBridgeGap: Int
    ) -> ClosedRange<Int> {
        func walk(step: Int) -> Int {
            var bound = anchor
            var gap = 0
            var index = anchor + step
            while index >= 0, index < occupancy.count, gap <= maximumBridgeGap {
                if occupancy[index] >= floor {
                    bound = index
                    gap = 0
                } else {
                    gap += 1
                }
                index += step
            }
            return bound
        }

        return walk(step: -1)...walk(step: 1)
    }

    func refine(
        coarse: PixelRect,
        pixels: [UInt8],
        width: Int,
        height: Int,
        background: (red: UInt8, green: UInt8, blue: UInt8),
        threshold: UInt8
    ) -> PixelRect {
        let search = 6
        // Must exceed the widest streak a real pass has produced (10 px) while
        // staying far below a genuine media edge, which supports hundreds.
        let minimumSupport = 16
        let contentXRange = max(0, coarse.x - search)..<min(
            width,
            coarse.maxX + search
        )
        let contentYRange = max(0, coarse.y - search)..<min(
            height,
            coarse.maxY + search
        )

        func isForeground(x: Int, y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return max(
                absoluteDifference(pixels[offset], background.red),
                absoluteDifference(pixels[offset + 1], background.green),
                absoluteDifference(pixels[offset + 2], background.blue)
            ) > threshold
        }

        func columnIsSupported(_ x: Int) -> Bool {
            contentYRange.reduce(into: 0) { count, y in
                if isForeground(x: x, y: y) {
                    count += 1
                }
            } >= minimumSupport
        }

        func rowIsSupported(_ y: Int) -> Bool {
            contentXRange.reduce(into: 0) { count, x in
                if isForeground(x: x, y: y) {
                    count += 1
                }
            } >= minimumSupport
        }

        let leftSearch = max(0, coarse.x - search)...min(
            width - 1,
            coarse.x + search
        )
        let rightSearch = stride(
            from: min(width - 1, coarse.maxX + search - 1),
            through: max(0, coarse.maxX - search - 1),
            by: -1
        )
        let topSearch = max(0, coarse.y - search)...min(
            height - 1,
            coarse.y + search
        )
        let bottomSearch = stride(
            from: min(height - 1, coarse.maxY + search - 1),
            through: max(0, coarse.maxY - search - 1),
            by: -1
        )

        guard let minimumX = leftSearch.first(where: columnIsSupported),
              let maximumX = rightSearch.first(where: columnIsSupported),
              let minimumY = topSearch.first(where: rowIsSupported),
              let maximumY = bottomSearch.first(where: rowIsSupported)
        else {
            return coarse
        }
        return PixelRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }

    func close3x3(_ input: [UInt8], width: Int, height: Int) -> [UInt8] {
        var dilated = [UInt8](repeating: 0, count: input.count)
        for y in 0..<height {
            for x in 0..<width where input[y * width + x] != 0 {
                for nextY in max(0, y - 1)...min(height - 1, y + 1) {
                    for nextX in max(0, x - 1)...min(width - 1, x + 1) {
                        dilated[nextY * width + nextX] = 1
                    }
                }
            }
        }

        var closed = [UInt8](repeating: 0, count: input.count)
        guard width >= 3, height >= 3 else { return dilated }
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var allForeground = true
                for nextY in (y - 1)...(y + 1) {
                    for nextX in (x - 1)...(x + 1)
                    where dilated[nextY * width + nextX] == 0
                    {
                        allForeground = false
                    }
                }
                closed[y * width + x] = allForeground ? 1 : 0
            }
        }
        return closed
    }

    struct LabeledComponents {
        let components: [Component]
        let labels: [Int32]
    }

    func connectedComponents(
        _ mask: [UInt8],
        width: Int,
        height: Int
    ) -> LabeledComponents {
        var labels = [Int32](repeating: -1, count: mask.count)
        var queue: [Int] = []
        var components: [Component] = []

        for start in mask.indices
        where mask[start] != 0 && labels[start] < 0
        {
            let label = Int32(components.count)
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            labels[start] = label
            var readIndex = 0
            var component = Component()

            while readIndex < queue.count {
                let index = queue[readIndex]
                readIndex += 1
                let x = index % width
                let y = index / width
                component.area += 1
                component.minimumX = min(component.minimumX, x)
                component.minimumY = min(component.minimumY, y)
                component.maximumX = max(component.maximumX, x)
                component.maximumY = max(component.maximumY, y)

                for nextY in max(0, y - 1)...min(height - 1, y + 1) {
                    for nextX in max(0, x - 1)...min(width - 1, x + 1) {
                        let nextIndex = nextY * width + nextX
                        if mask[nextIndex] != 0, labels[nextIndex] < 0 {
                            labels[nextIndex] = label
                            queue.append(nextIndex)
                        }
                    }
                }
            }
            components.append(component)
        }
        return LabeledComponents(components: components, labels: labels)
    }

    func absoluteDifference(_ first: UInt8, _ second: UInt8) -> UInt8 {
        first >= second ? first - second : second - first
    }
}
