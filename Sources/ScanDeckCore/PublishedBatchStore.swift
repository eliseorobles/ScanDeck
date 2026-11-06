import Foundation

public enum PublishedBatchStoreError: Error, Equatable, LocalizedError, Sendable {
    case unwritableStore(String)
    case unresolvableDestination(String)

    public var errorDescription: String? {
        switch self {
        case let .unwritableStore(reason):
            "The batch history could not be saved: \(reason)"
        case let .unresolvableDestination(name):
            "ScanDeck could not reopen \(name)'s folder. It may have been "
                + "moved, renamed, or be on a volume that is not mounted."
        }
    }
}

/// Which filename suffix holds the card's artwork.
///
/// This exists because of a real inversion in the operator's own corpus, and it
/// is the sharpest trap in the centering feature. ScanDeck publishes artwork in
/// `_F`; batches from before `deliveryOrder: .backFirst` have the Pokéball back
/// in `_F` instead. Front and back centering tolerances differ by **5×** — PSA
/// allows 55/45 on a front and 75/25 on a back — so grading an inverted folder on
/// the suffix scores every front against back budgets and reports ruinous cards
/// as flawless, silently and plausibly.
///
/// No property of the files can settle it, so it is declared rather than
/// detected. A batch ScanDeck published records `.frontSuffix` because it knows;
/// an imported folder records nothing until the operator says.
public enum ArtworkSide: String, Codable, Equatable, Sendable {
    /// `_F` is the artwork. What ScanDeck itself publishes.
    case frontSuffix
    /// `_B` is the artwork — the legacy inversion. Needs `--swap-sides`.
    case backSuffix

    public var requiresSwappedSides: Bool {
        self == .backSuffix
    }
}

/// One published batch, as it was at the moment it was published.
///
/// Deliberately a *record* rather than a live read of the destination. The
/// folder is on Google Drive and `carduploader` consumes it, so what is on disk
/// months later is not evidence of what ScanDeck produced — and the two facts
/// worth keeping, that a card was released with sides that disagreed and that
/// one was released over a refusal, exist nowhere else once the session record
/// is cleared.
public struct PublishedBatchRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: BatchID
    public let jobID: JobID
    public let batchName: BatchName
    public let cardCount: Int
    public let firstSheetNumber: UInt64?
    public let lastSheetNumber: UInt64?
    public let destinationDisplayName: String
    public let publishedAt: Date

    /// Resolved at read time rather than stored as a path, per invariant #3.
    /// A path saved today is a guess about a folder that may be renamed,
    /// remounted, or moved between volumes.
    public let destinationBookmark: Data?

    public let releasedWithSizeWarnings: [UInt64]
    public let releasedWithAcceptedMismatches: [UInt64]

    /// True for a folder found on disk rather than published by this app.
    ///
    /// An imported row knows only what the directory shows: a name, a file
    /// count, and a modification date. It cannot know which cards were released
    /// with sides that disagreed, and — the part that matters — it cannot know
    /// which suffix is the artwork.
    public let isImported: Bool

    /// Which suffix holds the artwork, or `nil` if nobody has said yet.
    ///
    /// `nil` is a hard gate on centering rather than a default, because both
    /// possible defaults are wrong for half the operator's folders and the
    /// failure is silent in the direction that costs money.
    public let artworkSide: ArtworkSide?

    /// The tone curve baked into this batch's files.
    ///
    /// Recorded because after this it is unrecoverable: the curve is applied at
    /// publication and the masters that could prove what it was are the
    /// operator's to delete. A folder that looks brighter than another is not
    /// evidence of anything on its own.
    ///
    /// **Unlike `artworkSide`, this one gets a default, and the difference is
    /// the point.** `artworkSide` refuses one because both candidates are wrong
    /// for half the operator's folders. Here the identity is *correct* for
    /// every batch published before this field existed and for every folder
    /// imported off disk — none of them were adjusted, because nothing could
    /// adjust them. Do not make this optional for symmetry with the field
    /// above it.
    public let brightness: BrightnessAdjustment

    public init(
        id: BatchID,
        jobID: JobID,
        batchName: BatchName,
        cardCount: Int,
        firstSheetNumber: UInt64?,
        lastSheetNumber: UInt64?,
        destinationDisplayName: String,
        publishedAt: Date,
        destinationBookmark: Data?,
        releasedWithSizeWarnings: [UInt64] = [],
        releasedWithAcceptedMismatches: [UInt64] = [],
        isImported: Bool = false,
        artworkSide: ArtworkSide? = .frontSuffix,
        brightness: BrightnessAdjustment = .identity
    ) {
        self.id = id
        self.jobID = jobID
        self.batchName = batchName
        self.cardCount = cardCount
        self.firstSheetNumber = firstSheetNumber
        self.lastSheetNumber = lastSheetNumber
        self.destinationDisplayName = destinationDisplayName
        self.publishedAt = publishedAt
        self.destinationBookmark = destinationBookmark
        self.releasedWithSizeWarnings = releasedWithSizeWarnings
        self.releasedWithAcceptedMismatches = releasedWithAcceptedMismatches
        self.isImported = isImported
        self.artworkSide = artworkSide
        self.brightness = brightness
    }

    /// Decoded with defaults so a history file written before these fields
    /// existed still opens, and so an unrecognised `artworkSide` reads as
    /// undeclared rather than as a guess.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(BatchID.self, forKey: .id)
        jobID = try container.decode(JobID.self, forKey: .jobID)
        batchName = try container.decode(BatchName.self, forKey: .batchName)
        cardCount = try container.decode(Int.self, forKey: .cardCount)
        firstSheetNumber = try container.decodeIfPresent(
            UInt64.self,
            forKey: .firstSheetNumber
        )
        lastSheetNumber = try container.decodeIfPresent(
            UInt64.self,
            forKey: .lastSheetNumber
        )
        destinationDisplayName = try container.decode(
            String.self,
            forKey: .destinationDisplayName
        )
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
        destinationBookmark = try container.decodeIfPresent(
            Data.self,
            forKey: .destinationBookmark
        )
        releasedWithSizeWarnings = try container.decodeIfPresent(
            [UInt64].self,
            forKey: .releasedWithSizeWarnings
        ) ?? []
        releasedWithAcceptedMismatches = try container.decodeIfPresent(
            [UInt64].self,
            forKey: .releasedWithAcceptedMismatches
        ) ?? []
        isImported = try container.decodeIfPresent(
            Bool.self,
            forKey: .isImported
        ) ?? false
        artworkSide = try container.decodeIfPresent(
            ArtworkSide.self,
            forKey: .artworkSide
        )
        brightness = try container.decodeIfPresent(
            BrightnessAdjustment.self,
            forKey: .brightness
        ) ?? .identity
    }

    /// Whether centering may run against this folder yet.
    public var canCheckCentering: Bool {
        artworkSide != nil
    }

    public func declaring(_ side: ArtworkSide) -> PublishedBatchRecord {
        PublishedBatchRecord(
            id: id,
            jobID: jobID,
            batchName: batchName,
            cardCount: cardCount,
            firstSheetNumber: firstSheetNumber,
            lastSheetNumber: lastSheetNumber,
            destinationDisplayName: destinationDisplayName,
            publishedAt: publishedAt,
            destinationBookmark: destinationBookmark,
            releasedWithSizeWarnings: releasedWithSizeWarnings,
            releasedWithAcceptedMismatches: releasedWithAcceptedMismatches,
            isImported: isImported,
            artworkSide: side,
            brightness: brightness
        )
    }

    /// The published folder, if it can still be found.
    ///
    /// Returns `nil` rather than throwing for the ordinary case of a folder the
    /// operator moved: a history row for a batch whose folder is gone is still
    /// worth showing, because the numbers it burned are still the truth about
    /// the counter. Only the actions that need the files are refused.
    public func resolveDestinationURL() -> URL? {
        guard let destinationBookmark else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: destinationBookmark,
            options: [.withoutUI],
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return url
    }
}

/// Every batch this installation has published, newest first.
///
/// ScanDeck used to keep none of this. A batch published, the session record was
/// cleared, and the only trace left was a folder on Drive — so after a relaunch
/// the app could not name a single batch it had produced, and the completion
/// screen's Check Centering became unreachable the moment the window moved on.
/// Asked for directly by the operator: "not sure why I cant see previous
/// batches on the left."
///
/// One file holding an array rather than a file per batch. The list is read
/// whole on every launch and is a few hundred bytes per entry, so a directory
/// scan buys nothing and a partial read would be harder to reason about than a
/// single atomic replace.
public struct PublishedBatchStore {
    /// Kept so a runaway history cannot grow without bound. 500 batches at
    /// ~350 bytes is well under a megabyte, and the operator runs a few a day.
    public static let maximumRecordCount = 500

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/ScanDeck/History`.
    public static var applicationSupport: PublishedBatchStore {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(filePath: NSHomeDirectory())
            .appending(
                path: "Library/Application Support",
                directoryHint: .isDirectory
            )

        return PublishedBatchStore(
            directory: base
                .appending(path: "ScanDeck", directoryHint: .isDirectory)
                .appending(path: "History", directoryHint: .isDirectory)
        )
    }

    /// The published batches, newest first.
    ///
    /// An unreadable or corrupt file yields an empty list rather than throwing.
    /// A history is a convenience; it must never be the reason the app cannot
    /// open, and it holds nothing that cannot be re-derived by looking at the
    /// destination folder.
    public func records() -> [PublishedBatchRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode(
                  [PublishedBatchRecord].self,
                  from: data
              )
        else {
            return []
        }
        return records.sorted { $0.publishedAt > $1.publishedAt }
    }

    /// Records a batch that has just published.
    ///
    /// Replaces any entry with the same batch identifier, so a resumed release
    /// that re-reports its success cannot produce two rows for one batch — the
    /// same idempotency the counter commit has.
    public func append(_ record: PublishedBatchRecord) throws {
        var stored = records().filter { $0.id != record.id }
        stored.append(record)
        stored.sort { $0.publishedAt > $1.publishedAt }
        try write(Array(stored.prefix(Self.maximumRecordCount)))
    }

    /// Removes one row. The published folder is never touched — this forgets a
    /// batch, it does not delete one.
    public func forget(_ batchID: BatchID) throws {
        try write(records().filter { $0.id != batchID })
    }

    // MARK: - Storage

    private var fileURL: URL {
        directory.appending(path: "batches.json", directoryHint: .notDirectory)
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func write(_ records: [PublishedBatchRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try DurableFile.write(try encoder.encode(records), to: fileURL)
        } catch let error as DurableFileError {
            throw PublishedBatchStoreError.unwritableStore(
                error.errorDescription ?? "\(error)"
            )
        } catch {
            throw PublishedBatchStoreError.unwritableStore(
                error.localizedDescription
            )
        }
    }
}
