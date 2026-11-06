import Foundation
import ScanDeckCore
import ScanDeckImagePipeline

/// Supplies pages for one scan pass, writing masters into `directory`.
///
/// The only piece of the workflow that differs between the synthetic build and
/// real hardware. Everything downstream — crop analysis, margin verdicts,
/// publication — is identical either way, so the demo exercises the production
/// pipeline rather than a parallel one.
@MainActor
protocol ScanPassProviding: AnyObject {
    func scan(
        _ request: ScanPassRequest,
        into directory: URL
    ) -> AsyncStream<ScanPassProgress>
}

/// The production workflow: real crop analysis and real atomic publication.
@MainActor
final class ScanDeckWorkflowActions: ScanDeckAppActions {
    private let scanner: any ScanPassProviding
    private let publisher: BatchPublisher
    private let sessionsDirectory: URL

    init(
        scanner: any ScanPassProviding,
        publisher: BatchPublisher = BatchPublisher(),
        sessionsDirectory: URL = ScanDeckWorkflowActions.defaultSessionsDirectory
    ) {
        self.scanner = scanner
        self.publisher = publisher
        self.sessionsDirectory = sessionsDirectory
    }

    /// The same directory `BatchSessionStore` writes recovery records into, so a
    /// batch's masters and its record cannot end up in different places.
    static var defaultSessionsDirectory: URL {
        BatchSessionStore.applicationSupportDirectory
    }

    func scan(_ request: ScanPassRequest) -> AsyncStream<ScanPassProgress> {
        let directory = passDirectory(for: request)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return AsyncStream { continuation in
                continuation.yield(
                    .finished(
                        .failed(
                            message: "Captured pages have nowhere to go: "
                                + error.localizedDescription
                        )
                    )
                )
                continuation.finish()
            }
        }
        return scanner.scan(request, into: directory)
    }

    /// Runs the real crop analysis and reports which edges lack real background.
    func assessMargin(
        _ request: MarginAssessmentRequest
    ) async -> MarginAssessmentOutcome {
        guard let imageURL = request.imageURL else {
            return .unpublishable
        }

        let margins = request.margins
        let dpi = request.dpi
        let analysis = await Task.detached(priority: .userInitiated) {
            try? CardImageCropper().analyze(
                sourceURL: imageURL,
                margins: margins,
                dpi: dpi
            )
        }.value

        guard let analysis else {
            // A master that cannot be analysed must never read as publishable.
            return .unpublishable
        }

        // `availableCropBounds` rather than `requestedCropBounds`: when an edge
        // is short of background the published file is what could actually be
        // captured, and review must show that rather than a frame the pixels
        // cannot fill.
        //
        // A sufficient verdict carries the measured media footprint in master
        // coordinates so the reducer can hold a card's front against its back
        // — the pair-agreement gate. The footprint is a measurement, not a
        // display concern, which is why it enters the session while the crop
        // bounds below stay presentation-only.
        let assessment: MarginAssessment = analysis.insufficientEdges.isEmpty
            ? .sufficient(
                mediaSize: MediaPixelSize(
                    width: analysis.mediaBounds.width,
                    height: analysis.mediaBounds.height
                )
            )
            : .insufficient(
                edges: Self.rotate(
                    analysis.insufficientEdges,
                    by: request.rotation
                )
            )
        return MarginAssessmentOutcome(
            assessment: assessment,
            publishedCrop: PublishedCrop(
                bounds: analysis.availableCropBounds,
                sourceWidth: analysis.sourceWidth,
                sourceHeight: analysis.sourceHeight
            )
        )
    }

    func publish(
        _ request: BatchPublishRequest,
        progress: @escaping @Sendable (BatchPublishProgress) -> Void
    ) async throws -> BatchPublishReceipt {
        let candidate = request.candidate
        let cards = try candidate.cards.map { card in
            PublicationCard(
                sheetNumber: card.provisionalSheetNumber,
                front: try side(card.front, in: request),
                back: try side(card.back, in: request)
            )
        }

        let publicationRequest = PublicationRequest(
            batchName: candidate.batchName,
            destinationRoot: request.destinationURL,
            cards: cards,
            margins: candidate.requestedMargins,
            dpi: request.dpi,
            brightness: request.brightness
        )

        let publisher = publisher
        let receipt = try await Task.detached(priority: .userInitiated) {
            try await publisher.publish(publicationRequest) { step in
                progress(Self.publishProgress(for: step))
            }
        }.value

        return BatchPublishReceipt(
            publishedFolderURL: receipt.publishedFolderURL,
            destinationDescription: DestinationBookmarkStore.displayName(
                for: receipt.publishedFolderURL
            )
        )
    }

    func checkCentering(
        _ request: CenteringCheckRequest,
        progress: @escaping @Sendable (CenteringCheckProgress) -> Void
    ) async throws -> CenteringCheckReceipt {
        let toolURL = try Self.centeringToolURL()
        return try await Task.detached(priority: .userInitiated) {
            try Self.runCenteringTool(
                at: toolURL,
                request: request,
                progress: progress
            )
        }.value
    }

    func showInFinder(_ url: URL?) {
        FinderPresenter.show(url)
    }

    // MARK: - Helpers

    /// Nonisolated because it is called from the detached publishing task, on
    /// whichever thread is doing the cropping. It is a pure case-for-case
    /// translation with no state to reach for.
    private nonisolated static func publishProgress(
        for step: PublicationProgress
    ) -> BatchPublishProgress {
        switch step {
        case let .writing(filesWritten, fileCount):
            .writing(filesWritten: filesWritten, fileCount: fileCount)
        case .placingFolder:
            .placingFolder
        }
    }

    private static func centeringToolURL() throws -> URL {
        if let bundled = Bundle.main.url(
            forResource: "centering_check",
            withExtension: "py",
            subdirectory: "Centering"
        ) {
            return bundled
        }

        // `swift test` and a bare SwiftPM run have no assembled app resources.
        // `#filePath` is the checked-out source path in those builds, so the
        // same private tool stays reachable without inventing a configurable
        // command that could point anywhere.
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let developmentTool = repositoryRoot
            .appending(path: "centering", directoryHint: .isDirectory)
            .appending(path: "centering_check.py", directoryHint: .notDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: developmentTool.path,
            isDirectory: &isDirectory
        ),
              !isDirectory.boolValue
        else {
            throw CenteringCheckFailure(
                message: "The private centering tool is missing. Restore "
                    + "centering/centering_check.py and rebuild ScanDeck."
            )
        }
        return developmentTool
    }

    /// Runs entirely off the main actor. `Process`, its stdout pipe, and its
    /// file-backed stderr capture are born and die inside this task, so no
    /// non-Sendable Foundation object crosses an actor boundary. Stderr uses a
    /// file so a verbose interpreter failure cannot fill a pipe and deadlock
    /// the live stdout progress reader.
    private nonisolated static func runCenteringTool(
        at toolURL: URL,
        request: CenteringCheckRequest,
        progress: @escaping @Sendable (CenteringCheckProgress) -> Void
    ) throws -> CenteringCheckReceipt {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        // The published folder is the tool's only argument. Confirmation is an
        // environment capability set only after the completion screen asks;
        // it cannot become a remembered preference or a quiet default.
        process.arguments = [
            toolURL.path,
            request.publishedFolderURL.path,
        ]
        if request.swapSides {
            process.arguments?.append("--swap-sides")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SCANDECK_CENTERING_CONFIRMED"] = "1"
        environment["SCANDECK_CENTERING_EXPECTED_IMAGE_COUNT"] =
            "\(request.imageCount)"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let outputPipe = Pipe()
        let errorURL = FileManager.default.temporaryDirectory.appending(
            path: "scandeck-centering-\(UUID().uuidString).stderr",
            directoryHint: .notDirectory
        )
        guard FileManager.default.createFile(
            atPath: errorURL.path,
            contents: nil
        ) else {
            throw CenteringCheckFailure(
                message: "ScanDeck could not prepare the centering error log."
            )
        }
        let errorHandle: FileHandle
        do {
            errorHandle = try FileHandle(forWritingTo: errorURL)
        } catch {
            try? FileManager.default.removeItem(at: errorURL)
            throw CenteringCheckFailure(
                message: "ScanDeck could not open the centering error log: "
                    + error.localizedDescription
            )
        }
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.standardOutput = outputPipe
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            throw CenteringCheckFailure(
                message: "The centering tool could not start: "
                    + error.localizedDescription
            )
        }

        var parser = CenteringToolOutputParser()
        var receipt: CenteringCheckReceipt?
        var failureMessage: String?
        var lastCompletedImages = -1

        func accept(_ event: CenteringToolEvent) throws {
            switch event {
            case let .progress(step):
                guard step.imageCount == request.imageCount,
                      step.completedImages <= step.imageCount,
                      step.completedImages >= lastCompletedImages,
                      step.uploadedImages <= step.completedImages,
                      step.cachedImages
                        <= step.completedImages - step.uploadedImages,
                      step.failedImages
                        == step.completedImages
                            - step.uploadedImages
                            - step.cachedImages
                else {
                    throw CenteringCheckFailure(
                        message: "The centering tool returned inconsistent counts."
                    )
                }
                lastCompletedImages = step.completedImages
                progress(step)
            case let .completed(completed):
                receipt = completed
            case let .failed(message):
                failureMessage = message
            }
        }

        do {
            while true {
                let data = outputPipe.fileHandleForReading.availableData
                if data.isEmpty {
                    break
                }
                for event in try parser.append(data) {
                    try accept(event)
                }
            }
            for event in try parser.finish() {
                try accept(event)
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            throw error
        }

        process.waitUntilExit()
        try? errorHandle.synchronize()
        try? errorHandle.close()
        let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
        let errorText = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw CenteringCheckFailure(
                message: failureMessage
                    ?? (!errorText.isEmpty
                        ? errorText
                        : "The centering tool exited with status "
                            + "\(process.terminationStatus).")
            )
        }
        guard let receipt,
              receipt.imageCount == request.imageCount,
              receipt.uploadedImages <= receipt.imageCount,
              receipt.cachedImages
                == receipt.imageCount - receipt.uploadedImages
        else {
            throw CenteringCheckFailure(
                message: "The centering tool finished without a complete result."
            )
        }
        let expectedOutput = request.publishedFolderURL
            .appending(path: "centering", directoryHint: .isDirectory)
            .standardizedFileURL
        guard receipt.outputFolderURL.standardizedFileURL == expectedOutput else {
            throw CenteringCheckFailure(
                message: "The centering tool reported an unexpected output folder."
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: receipt.outputFolderURL.path,
            isDirectory: &isDirectory
        ),
              isDirectory.boolValue
        else {
            throw CenteringCheckFailure(
                message: "The centering tool did not leave an output folder."
            )
        }
        return receipt
    }

    private func mastersDirectory(for batchID: BatchID) -> URL {
        sessionsDirectory.appending(
            path: batchID.rawValue.uuidString,
            directoryHint: .isDirectory
        )
    }

    /// Every pass writes into a directory of its own inside the batch.
    ///
    /// Masters stay on disk for the life of the batch, so a shared per-batch
    /// folder would hand the second pass a directory that is no longer empty —
    /// and the Image Capture probe refuses that, because starting empty is how
    /// it knows every file it finds belongs to the pass it just ran. Nesting
    /// per pass keeps that guarantee while letting a batch accumulate across
    /// Continue Scanning, Retry, and Replace.
    private func passDirectory(for request: ScanPassRequest) -> URL {
        mastersDirectory(for: request.batchID)
            .appending(
                path: request.passID.rawValue.uuidString,
                directoryHint: .isDirectory
            )
    }

    private func side(
        _ completionSide: CompletionSide,
        in request: BatchPublishRequest
    ) throws -> PublicationSide {
        guard let url = request.masterURLs[completionSide.masterID] else {
            throw BatchPublisherError.stagingFailed(
                "A captured image is missing from this session."
            )
        }
        return PublicationSide(
            masterURL: url,
            rotation: completionSide.rotation
        )
    }

    /// Relabels edges through a quarter-turn.
    ///
    /// The crop analysis describes the master's own orientation. Once the
    /// operator rotates a side, the edge that was short of background is no
    /// longer the one they see at the top of the review grid.
    static func rotate(
        _ edges: Set<ScanEdge>,
        by turns: QuarterTurns
    ) -> Set<ScanEdge> {
        guard turns != .zero else {
            return edges
        }
        let clockwise: [ScanEdge] = [.top, .right, .bottom, .left]
        return Set(
            edges.compactMap { edge -> ScanEdge? in
                guard let index = clockwise.firstIndex(of: edge) else {
                    return nil
                }
                return clockwise[(index + turns.rawValue) % clockwise.count]
            }
        )
    }
}
