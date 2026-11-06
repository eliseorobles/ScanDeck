import CoreGraphics
import Foundation
import ScanDeckCore

public struct PublicationSide: Equatable, Sendable {
    public let masterURL: URL
    public let rotation: QuarterTurns

    public init(masterURL: URL, rotation: QuarterTurns) {
        self.masterURL = masterURL
        self.rotation = rotation
    }
}

public struct PublicationCard: Equatable, Sendable {
    public let sheetNumber: UInt64
    public let front: PublicationSide
    public let back: PublicationSide

    public init(
        sheetNumber: UInt64,
        front: PublicationSide,
        back: PublicationSide
    ) {
        self.sheetNumber = sheetNumber
        self.front = front
        self.back = back
    }
}

public struct PublicationRequest: Equatable, Sendable {
    public let batchName: BatchName
    public let destinationRoot: URL
    public let cards: [PublicationCard]
    public let margins: ScanMargins
    public let template: FilenameTemplate
    public let dpi: Int
    public let quality: Double

    /// The tone curve baked into every file this request writes.
    ///
    /// Defaulted to the identity so every existing caller and test publishes
    /// exactly what it published before, and so the one batch property that can
    /// change a published pixel has to be asked for explicitly.
    public let brightness: BrightnessAdjustment

    public init(
        batchName: BatchName,
        destinationRoot: URL,
        cards: [PublicationCard],
        margins: ScanMargins = .cardDefault,
        template: FilenameTemplate = .cardDefault,
        dpi: Int = 600,
        quality: Double = 0.95,
        brightness: BrightnessAdjustment = .identity
    ) {
        self.batchName = batchName
        self.destinationRoot = destinationRoot
        self.cards = cards
        self.margins = margins
        self.template = template
        self.dpi = dpi
        self.quality = quality
        self.brightness = brightness
    }
}

public struct PublicationReceipt: Equatable, Sendable {
    public let publishedFolderURL: URL
    public let fileNames: [String]
}

/// How far publication has got, in the units the operator can count.
///
/// Files rather than cards: the work is one crop, encode and flush per side, so
/// a card-shaped number would jump in twos and sit still for half of each one.
/// At 186 cards this is 372 steps of roughly a quarter-second each, which is
/// several minutes — long enough that a bare spinner is indistinguishable from
/// a hang, which is exactly the mistake TICKET-030 records the operator making.
public enum PublicationProgress: Equatable, Sendable {
    /// `filesWritten` of `fileCount` are staged. Reported after each file is
    /// on disk and flushed, so the number never claims work that could still
    /// fail.
    case writing(filesWritten: Int, fileCount: Int)

    /// Every file is staged; the directory flush and the atomic rename remain.
    /// A separate case because on a network volume this is not instant and
    /// there is nothing left to count.
    case placingFolder
}

public enum BatchPublisherError: Error, Equatable, LocalizedError, Sendable {
    case noCards
    case destinationRootUnavailable(URL)
    case batchFolderAlreadyExists(URL)
    case filenameCollision(String)
    case stagingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noCards:
            "This batch has no cards to publish."
        case let .destinationRootUnavailable(url):
            "The destination folder is unavailable: \(url.path)"
        case let .batchFolderAlreadyExists(url):
            "A folder named “\(url.lastPathComponent)” already exists in the "
                + "destination. ScanDeck never merges into or overwrites an "
                + "existing batch folder."
        case let .filenameCollision(name):
            "Two images would be written as \(name)."
        case let .stagingFailed(reason):
            "The batch could not be staged: \(reason)"
        }
    }
}

/// Publishes a finished batch as an all-or-nothing folder.
///
/// `SPEC.md` section 5: every output is written into a uniquely named staging
/// directory *on the destination volume*, validated and flushed, and only then
/// renamed to `<root>/<batch>/`. A rename within a volume is atomic, so the
/// final folder never exists in a half-written state — an interrupted run leaves
/// the destination untouched and the session masters intact.
public struct BatchPublisher: Sendable {
    private let cropper: CardImageCropper

    public init(cropper: CardImageCropper = CardImageCropper()) {
        self.cropper = cropper
    }

    /// How many sides are cropped, encoded and flushed at once.
    ///
    /// Measured on the 14-core reference machine against a synthetic
    /// 3232 × 4248 master — the delivered size on the fi-8170 — through the
    /// real cropper and JPEG encode: 0.222 s per file serially, 0.115 s at
    /// two, **0.071 s at four**, 0.063 s at six. Four is the knee. Six buys
    /// 10% more for 50% more memory, and peak memory here is what matters —
    /// each in-flight side holds a decoded master of about 55 MB, so four is
    /// roughly 220 MB and six is 330 MB.
    ///
    /// At the real batch size (D-10: 300–400 cards, so 600–800 files) this is
    /// the difference between about three minutes and about fifty seconds.
    static let stagingConcurrency = 4

    /// - Parameter progress: Called from the coordinating task as each file
    ///   lands, never concurrently — the count is incremented by whoever is
    ///   collecting results, so it cannot tick backwards even though the files
    ///   themselves finish out of order. Reporting only: publication is
    ///   all-or-nothing by design and this deliberately offers no way to
    ///   interrupt it, because a half-published staging directory the operator
    ///   can stop is a new way to get a partial batch.
    public func publish(
        _ request: PublicationRequest,
        progress: @Sendable (PublicationProgress) -> Void = { _ in }
    ) async throws -> PublicationReceipt {
        guard !request.cards.isEmpty else {
            throw BatchPublisherError.noCards
        }

        let root = request.destinationRoot
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw BatchPublisherError.destinationRootUnavailable(root)
        }

        let finalFolder = root.appending(
            path: request.batchName.value,
            directoryHint: .isDirectory
        )
        try assertBatchFolderIsAbsent(finalFolder)

        let plan = try makePlan(request)

        // A sibling of the final folder, so the rename below stays within one
        // volume and is therefore atomic.
        let staging = root.appending(
            path: ".scandeck-staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )

        do {
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: true
            )
        } catch {
            throw BatchPublisherError.stagingFailed(error.localizedDescription)
        }

        do {
            progress(.writing(filesWritten: 0, fileCount: plan.count))
            // Awaiting the whole staging phase is what makes the cleanup below
            // safe: a task group cannot return while a child is still running,
            // so by the time control reaches `catch` every crop that started
            // has finished writing. Removing the staging directory out from
            // under a task still writing into it is the one new way
            // parallelism could produce a half-written directory, and drain-
            // then-clean is what forecloses it.
            try await stage(plan, into: staging, request: request, progress: progress)

            progress(.placingFolder)
            try DurableFile.flush(staging)

            // Re-check immediately before the rename. `SPEC.md` section 5
            // requires the name to be free both when the batch is armed and at
            // publication, so a folder created meanwhile still refuses.
            try assertBatchFolderIsAbsent(finalFolder)
            try DurableFile.rename(staging, to: finalFolder)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        return PublicationReceipt(
            publishedFolderURL: finalFolder,
            fileNames: plan.map(\.fileName)
        )
    }

    // MARK: - Staging

    /// Crops, encodes and flushes every planned file, `stagingConcurrency` at
    /// a time.
    ///
    /// Three properties are load-bearing and each has a test:
    ///
    /// - **Every started crop is finished before the caller's cleanup runs.**
    ///   Structured concurrency gives this for free — the group awaits its
    ///   children whether the body returns or throws — and it is the reason
    ///   the loop below may throw straight out rather than unwinding by hand.
    /// - **Nothing here publishes anything.** Every write lands in the staging
    ///   directory; the atomic rename is still the only thing that makes a
    ///   batch folder appear, and it happens after this returns.
    /// - **The count is collected here, not in the workers.** Files finish out
    ///   of order, so a per-worker index could tick backwards. Counting
    ///   completions in the single collecting task keeps the sequence
    ///   0, 1, 2, … whatever order the disk finishes in, and a count is still
    ///   only reported for a file that is on disk and flushed.
    private func stage(
        _ plan: [PlannedFile],
        into staging: URL,
        request: PublicationRequest,
        progress: @Sendable (PublicationProgress) -> Void
    ) async throws {
        let cropper = cropper
        let margins = request.margins
        let dpi = request.dpi
        let quality = request.quality
        let brightness = request.brightness

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func submitNext() {
                guard next < plan.count else {
                    return
                }
                let item = plan[next]
                next += 1
                let destination = staging.appending(
                    path: item.fileName,
                    directoryHint: .notDirectory
                )
                group.addTask(priority: .userInitiated) {
                    // A pool per file, because the Core Graphics temporaries a
                    // crop allocates are autoreleased and a task body has no
                    // pool of its own to drain them into. Without it four
                    // workers accumulate 800 files' worth of images before
                    // anything is released.
                    try autoreleasepool {
                        try cropper.crop(
                            sourceURL: item.side.masterURL,
                            destinationURL: destination,
                            margins: margins,
                            dpi: dpi,
                            quality: quality,
                            rotation: item.side.rotation,
                            brightness: brightness
                        )
                        try DurableFile.flush(destination)
                    }
                }
            }

            for _ in 0..<min(Self.stagingConcurrency, plan.count) {
                submitNext()
            }
            var completed = 0
            while try await group.next() != nil {
                completed += 1
                progress(
                    .writing(filesWritten: completed, fileCount: plan.count)
                )
                submitNext()
            }
        }
    }

    // MARK: - Planning

    private struct PlannedFile: Sendable {
        let fileName: String
        let side: PublicationSide
    }

    /// Resolves every filename before writing anything, so a collision fails
    /// the batch before the destination has been touched.
    private func makePlan(
        _ request: PublicationRequest
    ) throws -> [PlannedFile] {
        var plan: [PlannedFile] = []
        var seen: Set<String> = []

        for card in request.cards {
            for (side, image) in [
                (OutputSide.front, card.front),
                (OutputSide.back, card.back),
            ] {
                let name = request.template.render(
                    sheetNumber: card.sheetNumber,
                    side: side
                )
                guard seen.insert(name).inserted else {
                    throw BatchPublisherError.filenameCollision(name)
                }
                plan.append(PlannedFile(fileName: name, side: image))
            }
        }
        return plan
    }

    private func assertBatchFolderIsAbsent(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw BatchPublisherError.batchFolderAlreadyExists(url)
        }
    }

    /// Where a batch of this name would be published.
    ///
    /// Public so arming can ask the same question publication will, against the
    /// same path, rather than assembling its own and getting a different answer
    /// (`SPEC.md` §4 beat 2).
    public static func batchFolderURL(
        for batchName: BatchName,
        in destinationRoot: URL
    ) -> URL {
        destinationRoot.appending(
            path: batchName.value,
            directoryHint: .isDirectory
        )
    }

    /// Whether that path is still free.
    ///
    /// A snapshot, deliberately: the folder can appear between this being asked
    /// and the batch being published, which is why publication re-checks
    /// immediately before the rename and keeps doing so. Asking early does not
    /// replace that — it stops the operator learning at Complete Batch, after
    /// every card has been fed, that the name was taken all along.
    public static func batchFolderIsAvailable(
        for batchName: BatchName,
        in destinationRoot: URL
    ) -> Bool {
        !FileManager.default.fileExists(
            atPath: batchFolderURL(
                for: batchName,
                in: destinationRoot
            ).path
        )
    }
}
