import CoreGraphics
import Foundation
import ImageIO
import ScanDeckCore
import Testing
import UniformTypeIdentifiers
@testable import ScanDeckImagePipeline

/// Proves the deskew path squares the card, and — the part that matters more —
/// that it does so without inventing a pixel.
///
/// Every fixture here uses a **non-black** background. That is deliberate and
/// load-bearing. `square` builds its context with `data: nil`, so any region
/// the source draw fails to cover comes out black; on a real capture, whose
/// background *is* black, that failure would be invisible. A background of
/// (18, 22, 30) makes the difference between "real captured background" and
/// "the corner PaperStream would have painted" a thing a test can see.
@Suite("Deskew")
struct CardImageCropperDeskewTests {
    static let background: (red: UInt8, green: UInt8, blue: UInt8) =
        (red: 18, green: 22, blue: 30)
    static let media: UInt8 = 200

    // Capture geometry, so the numbers mean what they mean on the fi-8170.
    static let frame = (width: 3232, height: 4248)
    static let card = (width: 1819.0, height: 2415.0)

    @Test("Squares a tilted card, in both directions")
    func squaresATiltedCard() throws {
        for drawn in [1.0, -1.0, 0.54, -0.54] {
            let source = try Self.writeFixture(angleDegrees: drawn)
            let cropper = CardImageCropper()
            let output = source.deletingLastPathComponent()
                .appendingPathComponent("out.jpg")
            let result = try cropper.crop(
                sourceURL: source,
                destinationURL: output,
                margins: try ScanMargins(all: 3),
                dpi: 600,
                quality: 1.0
            )

            let applied = try #require(result.analysis.tiltDegrees)
            #expect(
                abs(applied - drawn) < 0.05,
                "measured \(applied)° on a card drawn at \(drawn)°"
            )

            // The output's own tilt is the only check that catches a sign
            // error. A card rotated the wrong way is still a plausible image;
            // it is simply twice as crooked as it started.
            let residual = try Self.measureTilt(of: output, using: cropper)
            #expect(
                abs(residual) < 0.05,
                "card drawn at \(drawn)° published at \(residual)°"
            )
            #expect(
                abs(residual) < abs(drawn) / 4,
                "deskew did not improve \(drawn)°: published \(residual)°"
            )
        }
    }

    @Test("The corners are captured background, not painted background")
    func doesNotPaintTheCorners() throws {
        let source = try Self.writeFixture(angleDegrees: 2.0)
        let cropper = CardImageCropper()
        let output = source.deletingLastPathComponent()
            .appendingPathComponent("out.jpg")
        _ = try cropper.crop(
            sourceURL: source,
            destinationURL: output,
            margins: try ScanMargins(all: 3),
            dpi: 600,
            quality: 1.0
        )

        let decoded = try cropper.decode(output)
        // Two pixels in from each corner, clear of the JPEG's edge ringing.
        let probes = [
            (2, 2),
            (decoded.width - 3, 2),
            (2, decoded.height - 3),
            (decoded.width - 3, decoded.height - 3),
        ]
        for (x, y) in probes {
            let offset = (y * decoded.width + x) * 4
            let red = decoded.pixels[offset]
            let green = decoded.pixels[offset + 1]
            let blue = decoded.pixels[offset + 2]
            #expect(
                abs(Int(red) - Int(Self.background.red)) <= 8
                    && abs(Int(green) - Int(Self.background.green)) <= 8
                    && abs(Int(blue) - Int(Self.background.blue)) <= 8,
                "corner (\(x), \(y)) reads (\(red), \(green), \(blue)) against a captured background of \(Self.background)"
            )
            // The specific failure this exists for: an uncovered context reads
            // as pure black, and on a real scan that would look correct.
            #expect(
                !(red == 0 && green == 0 && blue == 0),
                "corner (\(x), \(y)) is painted black, not captured"
            )
        }
    }

    @Test("A card below the tilt floor is not resampled at all")
    func leavesANearlySquareCardAlone() throws {
        // 0.1° is inside what the estimator can read and below the floor, so
        // this asserts the floor is what declines it rather than the fit
        // failing to see it.
        let source = try Self.writeFixture(angleDegrees: 0.1)
        let cropper = CardImageCropper()
        let output = source.deletingLastPathComponent()
            .appendingPathComponent("out.jpg")
        let result = try cropper.crop(
            sourceURL: source,
            destinationURL: output,
            margins: try ScanMargins(all: 3),
            dpi: 600,
            quality: 1.0
        )

        #expect(result.analysis.tiltDegrees == nil)
        #expect(
            result.analysis.outputWidth
                == result.analysis.requestedCropBounds.width
        )
        #expect(
            result.analysis.outputHeight
                == result.analysis.requestedCropBounds.height
        )

        // And the pixels came through by copy, not by interpolation.
        //
        // The comparison has a tolerance, and the reason is the file format
        // rather than the pipeline: the fixture is a lossless PNG but `crop`
        // publishes JPEG, and JPEG at quality 1.0 is still a DCT round-trip
        // through YCbCr. It lands a flat region within a level or two, not on
        // it. Asserting exact equality passed on one machine and failed in CI
        // reading 17 where 18 went in — a difference produced by the encoder,
        // not by anything ScanDeck did.
        //
        // The tolerance is small on purpose. Interpolating a 0.1° rotation
        // moves an edge pixel by whole levels of contrast, so ±2 still catches
        // a resample while admitting the codec. The load-bearing proof that
        // nothing was resampled is above this loop and is exact: `tiltDegrees`
        // is nil, so `square` is never called, and the output dimensions equal
        // the requested crop bounds rather than a rotated bounding box.
        let jpegRoundTripTolerance = 2
        let sourceImage = try cropper.decode(source)
        let outputImage = try cropper.decode(output)
        let bounds = result.analysis.requestedCropBounds
        var sampled = 0
        for y in stride(from: 4, to: outputImage.height - 4, by: 97) {
            for x in stride(from: 4, to: outputImage.width - 4, by: 89) {
                let out = (y * outputImage.width + x) * 4
                let into = ((y + bounds.y) * sourceImage.width
                    + (x + bounds.x)) * 4
                let difference = abs(
                    Int(outputImage.pixels[out])
                        - Int(sourceImage.pixels[into])
                )
                #expect(
                    difference <= jpegRoundTripTolerance,
                    "pixel (\(x), \(y)) differs by \(difference), more than the codec accounts for, so it was resampled"
                )
                sampled += 1
            }
        }
        #expect(sampled > 100)
    }

    @Test("The published size is the squared footprint plus its margins")
    func publishesTheSquaredFootprint() throws {
        let source = try Self.writeFixture(angleDegrees: 1.5)
        let cropper = CardImageCropper()
        let output = source.deletingLastPathComponent()
            .appendingPathComponent("out.jpg")
        let result = try cropper.crop(
            sourceURL: source,
            destinationURL: output,
            margins: try ScanMargins(all: 3),
            dpi: 600,
            quality: 1.0
        )
        let analysis = result.analysis
        let margin = try ScanMargins(all: 3).pixels(atDPI: 600)

        // The squared output is smaller than the tilted bounding box it came
        // out of — that difference is the border non-uniformity being removed.
        #expect(analysis.outputWidth < analysis.requestedCropBounds.width)
        #expect(analysis.outputHeight < analysis.requestedCropBounds.height)
        #expect(
            abs(
                analysis.outputWidth
                    - Int(Self.card.width) - margin.left - margin.right
            ) <= 4,
            "output width \(analysis.outputWidth) is not the true card plus margins"
        )
        #expect(
            abs(
                analysis.outputHeight
                    - Int(Self.card.height) - margin.top - margin.bottom
            ) <= 4
        )

        let decoded = try cropper.decode(output)
        #expect(decoded.width == analysis.outputWidth)
        #expect(decoded.height == analysis.outputHeight)
    }

    @Test("A uniform border is what actually changes")
    func makesTheBorderUniform() throws {
        // The whole point, measured the way the operator would see it: how far
        // the media edge sits from the published edge at the top of the card
        // versus the bottom. Tilted, those differ by the excursion; squared,
        // they agree.
        let source = try Self.writeFixture(angleDegrees: 1.0)
        let cropper = CardImageCropper()
        let output = source.deletingLastPathComponent()
            .appendingPathComponent("out.jpg")
        _ = try cropper.crop(
            sourceURL: source,
            destinationURL: output,
            margins: try ScanMargins(all: 3),
            dpi: 600,
            quality: 1.0
        )

        let decoded = try cropper.decode(output)
        func leftBorder(atRow y: Int) -> Int? {
            for x in 0..<decoded.width {
                let offset = (y * decoded.width + x) * 4
                if Int(decoded.pixels[offset]) - Int(Self.background.red) > 40 {
                    return x
                }
            }
            return nil
        }
        let near = try #require(leftBorder(atRow: decoded.height / 6))
        let far = try #require(leftBorder(atRow: decoded.height * 5 / 6))
        // Before deskew a 1° tilt puts these 42 px apart across a 2415 px card.
        #expect(
            abs(near - far) <= 4,
            "border runs \(near) px at the top and \(far) px at the bottom"
        )

        // Uniform is not enough — it has to be uniformly the margin that was
        // *asked for*. The first implementation squared the card by de-rotating
        // its bounding box, which solves for a sharp-cornered rectangle and so
        // under-measures a rounded one; the border came out uniform at 67 px
        // against 71 requested, and every uniformity check above still passed.
        let requested = try ScanMargins(all: 3).pixels(atDPI: 600).left
        #expect(
            abs(near - requested) <= 3 && abs(far - requested) <= 3,
            "border is \(near)/\(far) px against \(requested) px requested"
        )
    }

    @Test("Asymmetric margins stay asymmetric")
    func honoursUnequalMargins() throws {
        let source = try Self.writeFixture(angleDegrees: 1.0)
        let cropper = CardImageCropper()
        let output = source.deletingLastPathComponent()
            .appendingPathComponent("out.jpg")
        let margins = try ScanMargins(
            topMillimeters: 2,
            rightMillimeters: 6,
            bottomMillimeters: 2,
            leftMillimeters: 3
        )
        _ = try cropper.crop(
            sourceURL: source,
            destinationURL: output,
            margins: margins,
            dpi: 600,
            quality: 1.0
        )
        let insets = try margins.pixels(atDPI: 600)

        let decoded = try cropper.decode(output)
        let row = decoded.height / 2
        var left: Int?
        var right: Int?
        for x in 0..<decoded.width {
            let offset = (row * decoded.width + x) * 4
            if Int(decoded.pixels[offset]) - Int(Self.background.red) > 40 {
                if left == nil { left = x }
                right = x
            }
        }
        #expect(abs(try #require(left) - insets.left) <= 4)
        #expect(
            abs(decoded.width - 1 - (try #require(right)) - insets.right) <= 4
        )
    }

    @Test("A tilted card too close to the frame edge is refused, not padded")
    func refusesWhenTheSquaredCropLeavesTheFrame() throws {
        // Invariant #2's whole point: if the squared crop would need pixels the
        // scanner never captured, the answer is the existing insufficient
        // margin path, not a fabricated edge.
        let source = try Self.writeFixture(
            angleDegrees: 2.0,
            frameWidth: Int(Self.card.width) + 40,
            frameHeight: Int(Self.card.height) + 40
        )
        let cropper = CardImageCropper()
        let output = source.deletingLastPathComponent()
            .appendingPathComponent("out.jpg")
        #expect(throws: CardImageCropperError.self) {
            _ = try cropper.crop(
                sourceURL: source,
                destinationURL: output,
                margins: try ScanMargins(all: 3),
                dpi: 600
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Fixtures

    static func measureTilt(
        of url: URL,
        using cropper: CardImageCropper
    ) throws -> Double {
        let decoded = try cropper.decode(url)
        let estimate = cropper.estimateBackground(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height
        )
        let threshold = UInt8(
            min(255, max(12, Int(estimate.residualThreshold) + 4))
        )
        let bounds = try cropper.detectBounds(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height,
            background: estimate.color,
            threshold: threshold,
            dpi: 600
        )
        let reading = MediaTiltEstimator.measure(
            pixels: decoded.pixels,
            width: decoded.width,
            height: decoded.height,
            bounds: bounds,
            background: estimate.color,
            threshold: threshold
        )
        return try #require(reading.consensusDegrees)
    }

    static func writeFixture(
        angleDegrees: Double,
        frameWidth: Int? = nil,
        frameHeight: Int? = nil
    ) throws -> URL {
        let width = frameWidth ?? frame.width
        let height = frameHeight ?? frame.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = background.red
            pixels[index + 1] = background.green
            pixels[index + 2] = background.blue
            pixels[index + 3] = 255
        }

        let radians = angleDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let centreX = Double(width) / 2
        let centreY = Double(height) / 2
        for y in 0..<height {
            let offsetY = Double(y) + 0.5 - centreY
            for x in 0..<width {
                let offsetX = Double(x) + 0.5 - centreX
                let localX = offsetX * cosine + offsetY * sine
                let localY = -offsetX * sine + offsetY * cosine
                guard abs(localX) <= card.width / 2,
                      abs(localY) <= card.height / 2
                else { continue }
                let offset = (y * width + x) * 4
                pixels[offset] = media
                pixels[offset + 1] = media
                pixels[offset + 2] = media
            }
        }

        let provider = try #require(
            CGDataProvider(data: Data(pixels) as CFData)
        )
        let image = try #require(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("fixture.png")
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
