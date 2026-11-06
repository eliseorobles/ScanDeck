import CoreGraphics
import Foundation
import ImageIO
import ScanDeckCore
import Testing
import UniformTypeIdentifiers
@testable import ScanDeckImagePipeline

@Suite("Brightness applied to published pixels")
struct ToneCurveTests {
    @Test("The identity returns the same image rather than a copy of it")
    func identityIsUntouched() throws {
        let image = try makeImage(width: 16, height: 16)
        let result = try ToneCurve.apply(.identity, to: image)
        #expect(result === image)
    }

    @Test("Brightening lifts a midtone and leaves black and white alone")
    func liftsMidtonesOnly() throws {
        // Three flat bands: black background, a midtone card, a white border.
        let image = try makeBandedImage()
        let adjusted = try ToneCurve.apply(
            BrightnessAdjustment(amount: 0.6),
            to: image
        )

        let before = try samples(of: image)
        let after = try samples(of: adjusted)

        #expect(after.black == before.black)
        #expect(after.white == before.white)
        #expect(after.midtone > before.midtone)
    }

    /// The load-bearing ordering test. TICKET-019's occupancy constants and the
    /// 24/140 px pair thresholds were fitted against raw captures, so if the
    /// curve ever ran before `analyze` these numbers would move — silently, and
    /// only visibly once a real batch published wrong.
    @Test(
        "Detection is identical at every setting",
        arguments: [-1.0, -0.4, 0.0, 0.4, 1.0]
    )
    func detectionIgnoresBrightness(amount: Double) throws {
        let fixture = try makeCardFixture()
        defer { removeFixture(fixture) }

        let reference = try CardImageCropper().crop(
            sourceURL: fixture,
            destinationURL: output(beside: fixture, named: "reference.jpg"),
            margins: try ScanMargins(all: 1),
            dpi: 600
        )
        let adjusted = try CardImageCropper().crop(
            sourceURL: fixture,
            destinationURL: output(beside: fixture, named: "adjusted.jpg"),
            margins: try ScanMargins(all: 1),
            dpi: 600,
            brightness: BrightnessAdjustment(amount: amount)
        )

        #expect(adjusted.analysis.mediaBounds == reference.analysis.mediaBounds)
        #expect(
            adjusted.analysis.requestedCropBounds
                == reference.analysis.requestedCropBounds
        )
        #expect(
            adjusted.analysis.availableCropBounds
                == reference.analysis.availableCropBounds
        )
        #expect(
            adjusted.analysis.insufficientEdges
                == reference.analysis.insufficientEdges
        )
    }

    /// Anything less would mean every batch published before this feature
    /// existed was reproducible only by luck.
    @Test("At rest, the published file is byte-identical to no adjustment")
    func identityPublishesUnchangedBytes() throws {
        let fixture = try makeCardFixture()
        defer { removeFixture(fixture) }

        let withoutArgument = output(beside: fixture, named: "without.jpg")
        let withIdentity = output(beside: fixture, named: "identity.jpg")

        _ = try CardImageCropper().crop(
            sourceURL: fixture,
            destinationURL: withoutArgument,
            margins: try ScanMargins(all: 1),
            dpi: 600
        )
        _ = try CardImageCropper().crop(
            sourceURL: fixture,
            destinationURL: withIdentity,
            margins: try ScanMargins(all: 1),
            dpi: 600,
            brightness: .identity
        )

        #expect(
            try Data(contentsOf: withoutArgument)
                == Data(contentsOf: withIdentity)
        )
    }

    @Test("A brightened batch actually writes brighter files")
    func brightenedFilesAreBrighter() throws {
        let fixture = try makeCardFixture()
        defer { removeFixture(fixture) }

        let plain = output(beside: fixture, named: "plain.jpg")
        let lifted = output(beside: fixture, named: "lifted.jpg")

        _ = try CardImageCropper().crop(
            sourceURL: fixture,
            destinationURL: plain,
            margins: try ScanMargins(all: 1),
            dpi: 600
        )
        _ = try CardImageCropper().crop(
            sourceURL: fixture,
            destinationURL: lifted,
            margins: try ScanMargins(all: 1),
            dpi: 600,
            brightness: BrightnessAdjustment(amount: 0.5)
        )

        #expect(try meanLuminance(of: lifted) > meanLuminance(of: plain))
    }

    @Test("A preview carries the same curve the published file will")
    func previewMatchesPublication() throws {
        let fixture = try makeCardFixture()
        defer { removeFixture(fixture) }

        let plain = try ThumbnailDecoder.decode(
            contentsOf: fixture,
            maximumPixelSize: 128
        )
        let lifted = try ThumbnailDecoder.decode(
            contentsOf: fixture,
            maximumPixelSize: 128,
            brightness: BrightnessAdjustment(amount: 0.5)
        )

        #expect(try mean(of: lifted) > mean(of: plain))
    }

    // MARK: - Fixtures

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        try makeImage(width: width, height: height) { _, _ in (120, 120, 120) }
    }

    private func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let (red, green, blue) = pixel(x, y)
                pixels[offset] = red
                pixels[offset + 1] = green
                pixels[offset + 2] = blue
                pixels[offset + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(
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
    }

    /// Rows 0–9 black, 10–19 midtone, 20–29 white.
    private func makeBandedImage() throws -> CGImage {
        try makeImage(width: 8, height: 30) { _, y in
            switch y {
            case ..<10: (0, 0, 0)
            case ..<20: (128, 128, 128)
            default: (255, 255, 255)
            }
        }
    }

    private struct Bands {
        let black: UInt8
        let midtone: UInt8
        let white: UInt8
    }

    private func samples(of image: CGImage) throws -> Bands {
        let pixels = try readPixels(image)
        let bytesPerRow = image.width * 4
        return Bands(
            black: pixels[bytesPerRow * 5],
            midtone: pixels[bytesPerRow * 15],
            white: pixels[bytesPerRow * 25]
        )
    }

    private func readPixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )
            )
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
        }
        return pixels
    }

    private func mean(of image: CGImage) throws -> Double {
        let pixels = try readPixels(image)
        var total = 0.0
        var count = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            total += Double(pixels[offset])
                + Double(pixels[offset + 1])
                + Double(pixels[offset + 2])
            count += 3
        }
        return total / count
    }

    private func meanLuminance(of url: URL) throws -> Double {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(
            CGImageSourceCreateImageAtIndex(source, 0, nil)
        )
        return try mean(of: image)
    }

    /// A midtone card on a black background, big enough for the detector to
    /// find and for a 1 mm margin at 600 dpi to fit inside the frame.
    private func makeCardFixture() throws -> URL {
        let width = 520
        let height = 700
        let media = PixelRect(x: 120, y: 140, width: 280, height: 400)
        let image = try makeImage(width: width, height: height) { x, y in
            let inMedia = x >= media.x && x < media.x + media.width
                && y >= media.y && y < media.y + media.height
            return inMedia ? (150, 140, 130) : (0, 0, 0)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("master.png")
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

    private func output(beside fixture: URL, named name: String) -> URL {
        fixture.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func removeFixture(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
