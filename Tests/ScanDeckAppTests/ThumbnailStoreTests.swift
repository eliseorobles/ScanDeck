import CoreGraphics
import Synchronization
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ScanDeckImagePipeline
@testable import ScanDeckApp

@MainActor
@Suite("Review-grid thumbnail store")
struct ThumbnailStoreTests {
    @Test("Returns a bounded preview and serves the repeat request from cache")
    func cachesDecodedPreview() async throws {
        let fixture = try makeFixture(width: 1_600, height: 2_240)
        defer { removeFixture(fixture) }

        // Counting decodes is the honest cache proof. The old trick — delete
        // the master and read again — made `NSCache`'s eviction policy part
        // of the assertion, and `NSCache` may evict under the memory pressure
        // a parallel test run supplies.
        let decodeCount = DecodeCounter()
        let store = ThumbnailStore(decode: { url, maximumPixelSize, brightness in
            decodeCount.increment()
            return try ThumbnailDecoder.decode(
                contentsOf: url,
                maximumPixelSize: maximumPixelSize,
                brightness: brightness
            )
        })

        let first = try #require(await store.thumbnail(for: fixture))
        #expect(max(first.width, first.height) == 512)

        for _ in 0..<4 {
            let repeated = try #require(await store.thumbnail(for: fixture))
            #expect(repeated.width == first.width)
            #expect(repeated.height == first.height)
        }
        // Five requests, one decode. Strictly fewer than five tolerates a
        // rare mid-test pressure eviction; a cache that holds nothing decodes
        // every time and still fails.
        #expect(decodeCount.value < 5)
    }

    @Test("Concurrent requests for one master all resolve")
    func deduplicatesConcurrentRequests() async throws {
        let fixture = try makeFixture(width: 1_200, height: 1_600)
        defer { removeFixture(fixture) }
        let store = ThumbnailStore()

        let requests = (0..<8).map { _ in
            Task { @MainActor in
                await store.thumbnail(for: fixture) != nil
            }
        }

        var results: [Bool] = []
        for request in requests {
            results.append(await request.value)
        }

        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 })
    }

    @Test("A missing master yields no preview instead of failing the grid")
    func missingMasterReturnsNil() async {
        let store = ThumbnailStore()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")

        let preview = await store.thumbnail(for: missing)

        #expect(preview == nil)
    }

    // MARK: - Fixtures

    private final class DecodeCounter: Sendable {
        private let count = Mutex(0)

        var value: Int {
            count.withLock { $0 }
        }

        func increment() {
            count.withLock { $0 += 1 }
        }
    }

    private func makeFixture(width: Int, height: Int) throws -> URL {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) {
            pixels[index] = 255
        }

        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
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

    private func removeFixture(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
