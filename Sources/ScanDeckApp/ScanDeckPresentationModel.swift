import Darwin
import Foundation
import Observation
import ScanDeckCore
import ScanDeckImagePipeline
import ScanDeckScanner

// MARK: - Navigation

enum ScanDeckSidebarItem: Hashable {
    case profiles
    case activeBatch
    case completedBatch
    /// A batch published earlier, from the persisted history.
    ///
    /// Distinct from `completedBatch`, which is the one this launch published
    /// and still holds a live `BatchCompletionSummary` for. The two look alike
    /// and are not: one is in memory and knows its warnings first-hand, the
    /// other is a record read off disk.
    case publishedBatch(BatchID)
}

enum ScanDeckWorkspacePhase: Equatable {
    case ready
    case scanning
    case review
    case completing
    case completed

    init(_ phase: BatchPhase) {
        switch phase {
        case .ready:
            self = .ready
        case .scanning:
            self = .scanning
        case .review:
            self = .review
        case .releasing:
            self = .completing
        case .completed:
            self = .completed
        }
    }
}

enum SheetNumber {
    static func formatted(_ value: UInt64) -> String {
        String(format: "%06llu", value)
    }
}

// MARK: - View projections
//
// These are derived from `BatchSession` on every read. They hold no state the
// reducer does not already own, which is what keeps the shipped safety rules
// and the tested safety rules identical.

// `MarginAssessment` carries a `Set<ScanEdge>` and is Equatable rather than
// Hashable, so these projections follow it.
struct ScanSideViewData: Identifiable, Equatable, Sendable {
    let id: MasterID
    let side: OutputSide
    let imageURL: URL?
    let rotation: QuarterTurns
    let marginAssessment: MarginAssessment

    /// Where the published crop falls inside the master.
    ///
    /// Review has to show what will actually be published. The master is the
    /// whole scan frame, which on a card-sized item is mostly scanner
    /// background — reviewing that tells the operator nothing about the file
    /// their buyer will see, and makes a perfectly good scan look like a
    /// mistake. `nil` until the crop has been analysed.
    let publishedCrop: PublishedCrop?
}

struct CardPairViewData: Identifiable, Equatable, Sendable {
    let id: CardID
    let sheetNumber: UInt64
    let front: ScanSideViewData?
    let back: ScanSideViewData?

    /// How far this card's two sides disagree, when that is worth showing and
    /// not worth refusing the batch over — projected from the reducer's
    /// `pairSizeWarnings`, never decided here.
    ///
    /// It has to reach the row because nothing else in the row can show it: a
    /// pair only reaches this state with *both* sides reading `.sufficient`,
    /// so `hasMarginIssue` is false and the row would otherwise say "Ready"
    /// about a card the app knows one crop of is wrong.
    let sizeDisagreementPixels: Int?

    /// True when this card's disagreement is wide enough to refuse the batch
    /// and the operator accepted it anyway (TICKET-037).
    ///
    /// The row has to be able to say which of the two it is. "Sides disagree by
    /// 218 px" and "you accepted a 218 px disagreement" are the same number and
    /// opposite facts, and the second one is the only reason the batch is
    /// publishable.
    let acceptedSizeDisagreement: Bool

    var isIncomplete: Bool {
        front == nil || back == nil
    }

    var hasMarginIssue: Bool {
        [front, back]
            .compactMap { $0 }
            .contains { $0.marginAssessment.requiresAttention }
    }

    func side(_ side: OutputSide) -> ScanSideViewData? {
        switch side {
        case .front:
            front
        case .back:
            back
        }
    }
}

struct ScanProfileViewData: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let detail: String
    let symbolName: String
    let resolutionDPI: Int
    let defaultMarginMillimeters: Double

    /// How this scanner delivers a captured side relative to the way the
    /// operator put the card in.
    let captureRotation: QuarterTurns

    /// Which face of the card the feeder hands over first.
    let deliveryOrder: DuplexDeliveryOrder

    static let cards600FullBorder = ScanProfileViewData(
        id: UUID(uuidString: "A577C440-0374-4D99-82D5-6296519E16F2")!,
        name: "Cards 600 Full Border",
        detail: "Duplex color · real scanner background · JPEG q95",
        symbolName: "rectangle.on.rectangle.angled",
        resolutionDPI: 600,
        defaultMarginMillimeters: 3,
        // Measured on the fi-8170: a duplex pass delivers *both* faces upside
        // down, because the sheet reaches each sensor the opposite way up from
        // how it was loaded. Turning them here means the operator reviews cards
        // the right way up instead of rotating every side of every card by hand.
        captureRotation: .clockwise180,
        // Cards go into the fi-8170 face down, so the first page off the feeder
        // is the card's back. Assuming otherwise labels every pair backwards and
        // publishes the artwork as `_B` — which is worse than it sounds, because
        // carduploader trusts the suffix and would list every card by its back.
        deliveryOrder: .backFirst
    )
}

struct ActiveBatchViewData: Identifiable, Equatable, Sendable {
    let id: BatchID
    let profile: ScanProfileViewData
    let startedAt: Date
    let name: String
    let destinationURL: URL?
    let margins: ScanMargins
    let nextSheetNumber: UInt64
    let cards: [CardPairViewData]
    let phase: ScanDeckWorkspacePhase

    /// Which cards the reducer is refusing completion over, projected — never
    /// decided here.
    ///
    /// It has to be carried rather than recomputed from the rows because the
    /// worst blocker is invisible in a row. A mismatched pair (TICKET-019)
    /// requires *both* sides to have read `.sufficient` before it can arise, so
    /// `hasMarginIssue` is false for every one of them: on `carlsoboxone` the
    /// action bar read "186 cards ready" while 27 cards were blocked, and the
    /// only thing in the window that disagreed was a banner scrolled off the
    /// top of a 186-row list. That is the whole of TICKET-030's "no
    /// explanation".
    let blockedCardIDs: Set<CardID>

    /// The subset of `blockedCardIDs` blocked *only* because their two sides
    /// disagree too widely — the one blocker the operator may overrule
    /// (TICKET-037).
    ///
    /// Precomputed for the same reason `blockedCardIDs` is: asking the session
    /// per row would walk every blocker 400 times on every redraw, which is the
    /// quadratic shape this file has already been bitten by twice.
    let overridableSizeBlockedCardIDs: Set<CardID>

    var incompleteCards: [CardPairViewData] {
        cards.filter(\.isIncomplete)
    }

    var cardsWithMarginIssues: [CardPairViewData] {
        cards.filter(\.hasMarginIssue)
    }

    var cardsWithSizeDisagreement: [CardPairViewData] {
        cards.filter { $0.sizeDisagreementPixels != nil }
    }

    /// Cards the operator overruled a refusal on (TICKET-037).
    ///
    /// Counted separately in the action bar because it is a different sentence.
    /// The rest of `cardsWithSizeDisagreement` is the app saying "look at
    /// these"; these are the ones it refused and was told to publish, and the
    /// last line before Complete Batch is the right place to say so out loud.
    var cardsPublishedAnyway: [CardPairViewData] {
        cards.filter(\.acceptedSizeDisagreement)
    }

    var blockedCards: [CardPairViewData] {
        cards.filter { blockedCardIDs.contains($0.id) }
    }

    var completedCardCount: Int {
        cards.count(where: { !$0.isIncomplete })
    }

    var provisionalRange: ClosedRange<UInt64>? {
        guard let first = cards.map(\.sheetNumber).min(),
              let last = cards.map(\.sheetNumber).max()
        else {
            return nil
        }
        return first...last
    }

    var destinationDisplayName: String {
        guard let destinationURL else {
            return "No destination"
        }
        return DestinationBookmarkStore.displayName(for: destinationURL)
    }
}

struct BatchCompletionSummary: Equatable, Sendable {
    let batchName: String
    let cardCount: Int
    let counterRange: ClosedRange<UInt64>?
    let destinationDisplayName: String
    let destinationURL: URL?
    let completedAt: Date

    /// Sheet numbers released with their two sides measuring different item
    /// sizes, taken from the reducer's own completion summary.
    ///
    /// The completion screen is the last thing between the batch and
    /// `carduploader`, and these are the cards where ScanDeck knows one of the
    /// two crops is wrong. Naming them here is what keeps TICKET-033 a
    /// relaxation of the gate rather than a removal of the check.
    let releasedWithSizeWarnings: [UInt64]

    /// Sheet numbers the operator overruled a refusal on (TICKET-037).
    ///
    /// A subset of `releasedWithSizeWarnings`, shown as its own paragraph. These
    /// are the only cards in ScanDeck's history that were published after the
    /// reducer refused them, and the completion screen is the last place that
    /// can say so while the operator is still looking at the batch.
    let releasedWithAcceptedMismatches: [UInt64]

    /// Warned but not overruled — the cards TICKET-033 releases on its own.
    var releasedWithWarningsOnly: [UInt64] {
        let accepted = Set(releasedWithAcceptedMismatches)
        return releasedWithSizeWarnings.filter { !accepted.contains($0) }
    }
}

// MARK: - Batch setup

struct MarginValues: Equatable, Sendable {
    var top: Double = 3
    var right: Double = 3
    var bottom: Double = 3
    var left: Double = 3
    var linked = true

    subscript(edge: ScanEdge) -> Double {
        get {
            switch edge {
            case .top:
                top
            case .right:
                right
            case .bottom:
                bottom
            case .left:
                left
            }
        }
        set {
            if linked {
                top = newValue
                right = newValue
                bottom = newValue
                left = newValue
            } else {
                switch edge {
                case .top:
                    top = newValue
                case .right:
                    right = newValue
                case .bottom:
                    bottom = newValue
                case .left:
                    left = newValue
                }
            }
        }
    }

    /// The editing buffer validated into the immutable domain value.
    func validated() throws -> ScanMargins {
        try ScanMargins(
            topMillimeters: top,
            rightMillimeters: right,
            bottomMillimeters: bottom,
            leftMillimeters: left
        )
    }

    var summary: String {
        (try? validated().summary) ?? "Invalid margins"
    }
}

struct BatchSetupDraft: Equatable, Sendable {
    var name = ""
    var margins = MarginValues()
    var destinationURL: URL?

    /// `SPEC.md` section 5 forbids assuming a destination, so there is no
    /// default folder to fall back to here.
    var destinationDisplayName: String {
        guard let destinationURL else {
            return "Choose a destination folder…"
        }
        return DestinationBookmarkStore.displayName(for: destinationURL)
    }
}

struct ScanDeckNotice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case information
        case warning
        case error
    }

    /// The corrective step this notice offers, rendered as a button beside
    /// the message. A hardware failure that only describes itself leaves the
    /// operator hunting for the right control while a jammed card sits in
    /// the feeder; naming the next move on the notice is what turns an error
    /// into a prompt.
    enum Action: Equatable, Sendable {
        case continueScanning
        case retryCard(CardID)
        case replaceCard(CardID)

        /// When a card cannot be fixed by feeding more paper — or the operator
        /// simply does not want it — deletion *is* the corrective action, and
        /// it was the one move the banner could not offer. Asked for directly
        /// after `carlsoboxone`: "it should just let us delete the card."
        case deleteCard(CardID)

        var title: String {
            switch self {
            case .continueScanning:
                "Scan Again"
            case .retryCard:
                "Retry Card"
            case .replaceCard:
                "Replace Card"
            case .deleteCard:
                "Delete Card…"
            }
        }

        var cardID: CardID? {
            switch self {
            case .continueScanning:
                nil
            case let .retryCard(cardID),
                 let .replaceCard(cardID),
                 let .deleteCard(cardID):
                cardID
            }
        }
    }

    let id: UUID
    let kind: Kind
    let title: String
    let message: String
    let action: Action?

    /// The card this notice is about, if it is about one.
    ///
    /// The action has always known — `replaceCard(cardID)` names it — but the
    /// operator did not: at 186 rows the selected card is somewhere off screen
    /// and the row visible under the banner is an unrelated one. Pressing a
    /// button that does not say what it acts on is the same failure TICKET-023
    /// fixed for *which action*, one level along. Carried separately from the
    /// action so a notice can name and reveal a card it offers no press for.
    let cardID: CardID?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        message: String,
        action: Action? = nil,
        cardID: CardID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.message = message
        self.action = action
        // Defaulted from the action so a notice cannot offer a card-specific
        // press while claiming to be about no card in particular.
        self.cardID = cardID ?? action?.cardID
    }
}

/// One request to scroll a card into view, distinct from every other.
struct CardRevealRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let cardID: CardID
}

// MARK: - Service boundary

enum ScanPassKind: Equatable, Sendable {
    case append
    case retry(cardID: CardID)
    case replace(cardID: CardID)
}

struct ScanPassRequest: Sendable {
    let batchID: BatchID
    let passID: ScanPassID
    let kind: ScanPassKind
    let profile: ScanProfileViewData
    let margins: ScanMargins
}

/// Mirrors `ScannerPassEvent` so the production adapter is a thin translation
/// rather than a second pairing implementation.
enum ScanPassProgress: Sendable {
    case status(String)
    case notice(ScanPassNotice)
    case page(URL)
    case finished(ScanPassCompletion)
}

/// Mirrors `ScannerPassNotice`, for the reason the whole enum pair exists: the
/// production adapter stays a translation, and the app never decides what to
/// show by matching on the driver's wording.
enum ScanPassNotice: Equatable, Sendable {
    /// The single-client scanner is held by another application. The pass is
    /// stalled rather than over — it resumes on its own when the device is let
    /// go — so this is a state to explain, not a failure to report.
    case scannerInUseElsewhere(name: String)
    case scannerAvailableAgain
}

/// Mirrors `ScannerPassFailureReason`, for the same reason the enum pair above
/// exists — the app decides what to show from the case, never from the wording.
enum ScanPassFailureReason: Equatable, Sendable {
    /// The feeder was empty. The normal end of an automatic run, and the
    /// normal end of a manual one where the operator has simply finished.
    case feederEmpty
    case scannerFault
}

enum ScanPassCompletion: Equatable, Sendable {
    case succeeded
    case failed(message: String, reason: ScanPassFailureReason)

    /// A failure with nothing known about the feeder — the synthetic provider,
    /// and every refusal raised before the transport was reached.
    static func failed(message: String) -> ScanPassCompletion {
        .failed(message: message, reason: .scannerFault)
    }
}

struct MarginAssessmentRequest: Sendable {
    let masterID: MasterID
    let imageURL: URL?
    let rotation: QuarterTurns
    let margins: ScanMargins
    let dpi: Int
}

struct BatchPublishRequest: Sendable {
    let candidate: CompletionCandidate
    let destinationURL: URL
    let masterURLs: [MasterID: URL]
    let dpi: Int
    /// Carried on the request rather than read from settings inside the
    /// workflow, so the curve that publishes is the one the operator was
    /// looking at when they pressed Complete Batch.
    let brightness: BrightnessAdjustment
}

struct BatchPublishReceipt: Sendable {
    let publishedFolderURL: URL
    let destinationDescription: String
}

/// Mirrors `PublicationProgress`, so the pipeline's units reach the action bar
/// without the app inventing a second way to count the same work.
enum BatchPublishProgress: Equatable, Sendable {
    case writing(filesWritten: Int, fileCount: Int)
    case placingFolder

    /// What the operator reads while it runs.
    ///
    /// Counts, not a spinner: TICKET-030 records the operator reading a
    /// motionless window as a hang and considering a force-quit mid-batch. A
    /// number that moves is the difference between waiting and giving up.
    var operatorDescription: String {
        switch self {
        case let .writing(filesWritten, fileCount):
            "Publishing \(filesWritten) of \(fileCount)…"
        case .placingFolder:
            "Placing the batch folder…"
        }
    }
}

/// One unfinished batch offered back to the operator at launch.
struct RecoveredBatchViewData: Identifiable, Equatable, Sendable {
    let id: BatchID

    /// Which job's counter this batch is holding numbers from. It reserved
    /// them in a previous run and Resume brings them back unchanged, so
    /// anything that edits a counter has to be able to see it.
    let jobID: JobID
    let batchName: String
    let cardCount: Int
    let incompleteCardCount: Int
    let counterRange: ClosedRange<UInt64>?
    let savedAt: Date
    let wasInterruptedMidScan: Bool

    /// Concrete enough that the operator can tell which batch this is without
    /// resuming it. "An unfinished batch was recovered" alone asks them to
    /// gamble on Discard.
    var summary: String {
        var parts = ["\(cardCount) card\(cardCount == 1 ? "" : "s")"]
        if let counterRange {
            parts.append(
                counterRange.lowerBound == counterRange.upperBound
                    ? "numbered \(SheetNumber.formatted(counterRange.lowerBound))"
                    : "numbered \(SheetNumber.formatted(counterRange.lowerBound))"
                        + "–\(SheetNumber.formatted(counterRange.upperBound))"
            )
        }
        if incompleteCardCount > 0 {
            parts.append(
                "\(incompleteCardCount) still missing a side"
            )
        }
        return parts.joined(separator: ", ")
    }
}

/// A margin verdict plus what the same analysis already learned about framing.
///
/// The crop bounds are presentation-only and deliberately do not enter
/// `BatchSession`: the reducer decides whether a side is publishable, and the
/// pixels it lands on are the app's business. They ride along because the
/// analysis that produces the verdict has already computed them, so showing the
/// operator a true preview costs nothing extra.
struct MarginAssessmentOutcome: Sendable {
    let assessment: MarginAssessment
    let publishedCrop: PublishedCrop?

    static let unpublishable = MarginAssessmentOutcome(
        assessment: .insufficient(edges: Set(ScanEdge.allCases)),
        publishedCrop: nil
    )
}

@MainActor
protocol ScanDeckAppActions: AnyObject {
    func scan(_ request: ScanPassRequest) -> AsyncStream<ScanPassProgress>
    func assessMargin(
        _ request: MarginAssessmentRequest
    ) async -> MarginAssessmentOutcome
    /// - Parameter progress: Reported as the work proceeds. Called from
    ///   whichever thread is publishing, so it is `@Sendable`; the model hands
    ///   it a stream continuation rather than touching its own state, which is
    ///   what keeps the counts in order once they arrive back on the main actor.
    func publish(
        _ request: BatchPublishRequest,
        progress: @escaping @Sendable (BatchPublishProgress) -> Void
    ) async throws -> BatchPublishReceipt
    func checkCentering(
        _ request: CenteringCheckRequest,
        progress: @escaping @Sendable (CenteringCheckProgress) -> Void
    ) async throws -> CenteringCheckReceipt
    func showInFinder(_ url: URL?)
}

extension ScanDeckAppActions {
    /// Test doubles that do not exercise the post-publication tool stay small.
    ///
    /// Centering is deliberately downstream of the batch transaction. Giving
    /// old fakes an explicit unavailable result preserves that separation while
    /// tests focused on this feature can provide the real behavior they need.
    func checkCentering(
        _ request: CenteringCheckRequest,
        progress: @escaping @Sendable (CenteringCheckProgress) -> Void
    ) async throws -> CenteringCheckReceipt {
        throw CenteringCheckFailure(
            message: "The centering tool is unavailable in this run."
        )
    }
}

// MARK: - Model

private struct BatchContext: Equatable, Sendable {
    let profile: ScanProfileViewData
    let startedAt: Date
    let destinationURL: URL?
}

@MainActor
@Observable
final class ScanDeckPresentationModel {
    let profiles: [ScanProfileViewData]

    var sidebarSelection: ScanDeckSidebarItem? = .profiles
    var selectedCardID: CardID?
    var isInspectorPresented = true
    var isBatchSetupPresented = false

    /// Raised by every route to Cancel Batch, so the confirmation that guards
    /// a deletion of captured pages is written once and cannot be bypassed by
    /// adding a second control later.
    var isCancelBatchConfirmationPresented = false

    /// The card a confirmed Delete Card is waiting on, hosted at the root for
    /// the same reason Cancel Batch's is: one copy of the warning that guards
    /// a deletion of captured pages, not one per route to it.
    var cardPendingDeletionConfirmation: CardID?

    /// The card whose blocking size disagreement is waiting on a confirmation
    /// (TICKET-037).
    ///
    /// Hosted at the root for the same reason as the two above: this is the one
    /// control in ScanDeck that clears a completion blocker by decision instead
    /// of by fixing the card, and the sentence explaining what that costs is
    /// written once rather than once per route to it.
    var cardPendingSizeAcceptanceConfirmation: CardID?

    /// The most recent request to bring a card into view.
    ///
    /// A value rather than a bare `CardID` so that asking for the same card
    /// twice is two distinct requests — otherwise Show Card does nothing the
    /// second time, which is exactly when the operator has scrolled away and
    /// wants it again.
    private(set) var cardRevealRequest: CardRevealRequest?
    var batchDraft = BatchSetupDraft()
    var completionSummary: BatchCompletionSummary?
    var notice: ScanDeckNotice?
    private(set) var scanStatusMessage: String?

    /// The post-publication tool is outside the batch transaction.
    ///
    /// A failed or interrupted check can therefore report its own state here
    /// without making a successfully published batch look failed. Its progress
    /// stays on the completion screen, where the explicit egress press lives.
    private(set) var centeringCheckStatus: CenteringCheckStatus?

    /// Present only between the button press and that run's answer.
    ///
    /// Keeping consent as observable model state makes the first egress
    /// testable: no action method can be reached until this value existed and
    /// was explicitly confirmed, and it is cleared rather than remembered.
    private(set) var centeringCheckConsent: CenteringCheckConsent?

    /// Identifies which completed batch owns asynchronous centering updates.
    ///
    /// Starting the next batch does not kill a useful in-flight upload, but it
    /// does retire its UI identity so late progress cannot appear on a later
    /// batch's completion screen.
    private var centeringCheckRunID: UUID?

    /// Which folder the armed consent is for.
    ///
    /// Carried beside the consent rather than re-derived at confirm time, so the
    /// folder named in the dialog is provably the folder that gets uploaded. It
    /// used to be read back from `completionSummary`, which only ever described
    /// the batch just published — that is why a batch from an earlier session
    /// could not be checked at all.
    @ObservationIgnored
    private var pendingCenteringFolderURL: URL?

    /// Whether the armed consent's folder needs `--swap-sides`.
    @ObservationIgnored
    private var pendingCenteringSwapsSides = false

    /// The batch the current or last centering run is about, for copy that has
    /// to name it. `nil` means the batch on the completion screen.
    private(set) var centeringTargetBatchName: String?

    /// How far the current publication has got, or `nil` when none is running.
    ///
    /// Publication crops, encodes and flushes every side in turn — 372 files on
    /// a 186-card batch, each around a quarter-second — and then renames. Long
    /// enough that the operator needs to see it moving.
    private(set) var publishProgress: BatchPublishProgress?

    /// Unfinished batches found at launch, newest first. Empty once the
    /// operator has dealt with them.
    private(set) var recoveredBatches: [RecoveredBatchViewData] = []
    var isRecoveryPresented = false

    /// The single source of truth for batch state and every safety gate.
    private(set) var session: BatchSession?

    /// View-only context the domain deliberately does not carry.
    private var batchContext: BatchContext?

    /// Where each captured master lives on disk. Masters are retained for
    /// recovery and are never removed here — `SPEC.md` section 5 keeps them
    /// until publication and the counter commit are both durable.
    private var masterURLs: [MasterID: URL] = [:]

    /// Where each master's published crop falls, so review can show the file
    /// that will be produced rather than the whole scan frame. Presentation
    /// only, and rebuilt by re-analysis on recovery rather than persisted.
    private var publishedCrops: [MasterID: PublishedCrop] = [:]

    @ObservationIgnored
    private var scanTask: Task<Void, Never>?

    @ObservationIgnored
    private let actions: any ScanDeckAppActions

    @ObservationIgnored
    private let destinationPicker: any DestinationPicking

    @ObservationIgnored
    private let destinationBookmarkStore: DestinationBookmarkStore

    @ObservationIgnored
    private let jobCounterStore: JobCounterStore

    @ObservationIgnored
    private let publishedBatchStore: PublishedBatchStore

    /// Every batch this installation has published, newest first.
    ///
    /// Held rather than read per redraw: the sidebar reads it on every frame and
    /// the store is a file. Refreshed only when a batch publishes or a row is
    /// forgotten, which are the only two things that change it.
    private(set) var publishedBatches: [PublishedBatchRecord] = []

    @ObservationIgnored
    private let settingsStore: ScanDeckSettingsStore

    /// Bumped whenever the counter is seeded.
    ///
    /// `JobCounterStore` reads the filesystem and has no change notification of
    /// its own, so without something observable to touch, a seed in Settings
    /// would leave an open setup sheet showing the number it used to be — and
    /// the whole point of seeding is to see the result.
    private var counterRevision = 0

    /// The same trick for the working-files inventory, which is a directory
    /// walk rather than a stored value.
    private var sessionStorageRevision = 0

    @ObservationIgnored
    private let sessionStore: BatchSessionStore

    /// What the device browser and the running pass jointly say about the
    /// scanner. Projected, never stored here: a second copy of the status is a
    /// second thing that can be stale.
    let scannerStatus: ScannerStatusMonitor

    @ObservationIgnored
    private var autosaver: BatchSessionAutosaver!

    /// The unfinished batches behind `recoveredBatches`, kept whole so Resume
    /// restores the masters and destination the batch was captured with.
    @ObservationIgnored
    private var recoveredRecords: [BatchID: PersistedBatchSession] = [:]

    /// Autosave runs after every action, so a failing disk would otherwise
    /// replace the operator's notice with the same warning on every page.
    @ObservationIgnored
    private var hasReportedAutosaveFailure = false

    /// Which banner, if any, is the stalled-scanner one, so it can be withdrawn
    /// when the scanner is released without touching anything else on screen.
    @ObservationIgnored
    private var scannerBusyNoticeID: UUID?

    init(
        profiles: [ScanProfileViewData] = [.cards600FullBorder],
        scannerStatus: ScannerStatusMonitor,
        actions: any ScanDeckAppActions,
        destinationPicker: any DestinationPicking,
        destinationBookmarkStore: DestinationBookmarkStore =
            DestinationBookmarkStore(),
        jobCounterStore: JobCounterStore = .applicationSupport,
        sessionStore: BatchSessionStore = .applicationSupport,
        settingsStore: ScanDeckSettingsStore = ScanDeckSettingsStore(),
        publishedBatchStore: PublishedBatchStore = .applicationSupport
    ) {
        self.profiles = profiles
        self.scannerStatus = scannerStatus
        self.actions = actions
        self.destinationPicker = destinationPicker
        self.destinationBookmarkStore = destinationBookmarkStore
        self.jobCounterStore = jobCounterStore
        self.sessionStore = sessionStore
        self.settingsStore = settingsStore
        self.publishedBatchStore = publishedBatchStore
        publishedBatches = publishedBatchStore.records()
        settings = settingsStore.load()
        // The status projection has to know the pin, or it describes a
        // different device from the one a pass would take.
        scannerStatus.preferredScannerName = settings.preferredScannerName
        batchDraft.destinationURL = destinationBookmarkStore.resolveDestination()
        autosaver = BatchSessionAutosaver(store: sessionStore) {
            [weak self] error in
            self?.reportAutosaveFailure(error)
        }
        scannerStatus.start()
        loadRecoveredBatches()
    }

    var scannerConnection: ScannerConnection {
        scannerStatus.connection
    }

    // MARK: - Settings
    //
    // Everything here edits a store the rest of the app already reads. The
    // batch rules are untouched: a batch's margins, counter range, and
    // destination are fixed when it is armed, so nothing in this section can
    // reach into work that is already under way — with one exception, guarded
    // below, where it could.

    /// The preferred scanner, and whatever else this installation prefers.
    private(set) var settings: ScanDeckSettings = .default

    /// The names a scanner can be pinned to, in the order the browser saw them.
    ///
    /// Names rather than devices, deduplicated, because the pin *is* a name —
    /// it reaches the probe as `deviceNameContains`. Two identically named
    /// fi-8170s cannot be told apart by it, so offering the same label twice
    /// would be a choice that changes nothing while claiming to; that pair is
    /// what the `.severalScanners` status exists to talk about instead.
    var selectableScannerNames: [String] {
        var seen: Set<String> = []
        return scannerStatus.supportedScanners.compactMap { scanner in
            seen.insert(scanner.name).inserted ? scanner.name : nil
        }
    }

    /// Pins which scanner a pass takes, or `nil` for whichever is attached.
    func setPreferredScannerName(_ name: String?) {
        var updated = settings
        updated.preferredScannerName = name
        apply(updated)
    }

    private func apply(_ updated: ScanDeckSettings) {
        // Accept the change first. Persistence is for the next launch, and a
        // defaults write that fails must not discard a choice the operator has
        // just made and can use for this run.
        settings = updated
        scannerStatus.preferredScannerName = updated.preferredScannerName
        do {
            try settingsStore.save(updated)
        } catch {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "Settings will not be remembered",
                message: "ScanDeck is using this setting now, but could not "
                    + "save it for next launch: \(error.localizedDescription)"
            )
        }
    }

    /// Why the counter for this profile cannot be changed right now, if it
    /// cannot.
    ///
    /// An active batch reserved its numbers when it was armed, and completion
    /// commits the counter forward past them — a commit that refuses to move
    /// backwards. Seeding underneath a live batch therefore does not renumber
    /// it; it arranges for the counter commit to fail *after* the batch folder
    /// has already been published, which is the worst failure this app has.
    /// The batch question is the session's to answer, as always; what to do
    /// about the counter store is this layer's, because the reducer has never
    /// heard of it.
    func counterEditBlockReason(for profile: ScanProfileViewData) -> String? {
        if let session,
           batchContext?.profile.id == profile.id,
           ScanDeckWorkspacePhase(session.phase) != .completed
        {
            return "“\(session.batchName.value)” is using this profile's "
                + "numbers right now. Complete or cancel it before changing "
                + "the counter."
        }

        // A batch recovered at launch and not yet resumed is holding numbers
        // just as firmly as an open one — it reserved them in a previous run,
        // and Resume brings them back unchanged. Guarding only on the in-memory
        // session leaves the operator free to seed past them, and then a
        // resumed batch publishes and its commit is refused for moving
        // backwards: the counter fails *after* the folder exists, which is the
        // exact failure this lock is here to prevent.
        let jobID = JobID(rawValue: profile.id)
        guard let waiting = recoveredBatches.first(where: {
            $0.jobID == jobID
        }) else {
            return nil
        }
        return "“\(waiting.batchName)” was recovered and still holds this "
            + "profile's numbers. Resume and finish it, or discard it, before "
            + "changing the counter."
    }

    /// The explicit operator override from `SPEC.md` section 3, which may move
    /// the counter in either direction.
    func seedSheetNumber(
        _ nextSheetNumber: UInt64,
        for profile: ScanProfileViewData
    ) {
        if let reason = counterEditBlockReason(for: profile) {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "The counter is in use",
                message: reason
            )
            return
        }
        do {
            try jobCounterStore.seed(
                nextSheetNumber,
                for: JobID(rawValue: profile.id)
            )
            counterRevision += 1
            notice = ScanDeckNotice(
                kind: .information,
                title: "Counter set",
                message: "The next card in “\(profile.name)” will be "
                    + "\(SheetNumber.formatted(nextSheetNumber))."
            )
        } catch {
            notice = ScanDeckNotice(
                kind: .error,
                title: "The counter was not changed",
                message: error.localizedDescription
            )
        }
    }

    /// Forgets the remembered destination.
    ///
    /// An active batch keeps the folder it was armed with — its pages are
    /// already promised somewhere — so this only affects what the next batch
    /// starts from.
    func forgetDestination() {
        destinationBookmarkStore.clear()
        batchDraft.destinationURL = nil
        notice = ScanDeckNotice(
            kind: .information,
            title: "Destination forgotten",
            message: "The next batch will ask where to publish. Any batch "
                + "already under way keeps the folder it was created with."
        )
    }

    var sessionStorage: SessionStorageInventory {
        _ = sessionStorageRevision
        return sessionStore.inventory()
    }

    func revealSessionStorageInFinder() {
        actions.showInFinder(sessionStore.storageDirectory)
    }

    /// Removes working directories that hold captured images with no record
    /// beside them.
    ///
    /// These are the one class ScanDeck can never turn back into cards: the
    /// record that would say which side of which card they are was never
    /// written. They are still images someone fed through a scanner, so this is
    /// reached only from a confirmed press, and the confirmation says so.
    /// Nothing here runs on a timer — invariant #1 is not a thing to schedule
    /// around.
    func removeUnrecoverableWorkingFiles() {
        do {
            let removed = try sessionStore.removeDirectoriesWithoutRecord()
            sessionStorageRevision += 1
            notice = ScanDeckNotice(
                kind: .information,
                title: "Working files removed",
                message: removed == 1
                    ? "One directory of unrestorable images was deleted."
                    : "\(removed) directories of unrestorable images were "
                        + "deleted."
            )
        } catch {
            notice = ScanDeckNotice(
                kind: .error,
                title: "Working files were not removed",
                message: error.localizedDescription
            )
        }
    }

    /// A support report with nothing in it but versions, device identities, and
    /// counts. See `DiagnosticsReport` for why its input type has no field a
    /// path could go in.
    func diagnosticsText() -> String {
        DiagnosticsReport.text(
            for: DiagnosticsReport.Input(
                applicationVersion: Self.bundleValue(
                    "CFBundleShortVersionString"
                ),
                applicationBuild: Self.bundleValue("CFBundleVersion"),
                operatingSystemVersion: ProcessInfo.processInfo
                    .operatingSystemVersionString,
                hardwareModel: Self.hardwareModel(),
                scanners: scannerStatus.attachedScanners.map {
                    DiagnosticsReport.Scanner(
                        name: $0.name,
                        usbVendorID: $0.usbVendorID,
                        usbProductID: $0.usbProductID,
                        isSupported: $0.isSupported
                    )
                },
                preferredScannerName: settings.preferredScannerName,
                hasDestination: batchDraft.destinationURL != nil,
                destinationResolves: destinationBookmarkStore
                    .resolveDestination() != nil,
                counters: profiles.map {
                    DiagnosticsReport.Counter(
                        jobName: $0.name,
                        nextSheetNumber: nextSheetNumber(for: $0)
                    )
                },
                sessionStorage: DiagnosticsReport.Storage(sessionStorage),
                activeBatchCardCount: activeBatch?.cards.count
            )
        )
    }

    private static func bundleValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else {
            return "unknown"
        }
        var value = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &value, &size, nil, 0)
        return String(decoding: value.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The sheet number the next batch for this profile will start from, shown
    /// during setup so the counter is never a surprise.
    func nextSheetNumber(for profile: ScanProfileViewData) -> UInt64 {
        // Reading the revision is what makes this observable — see its
        // declaration. Removing this line does not break a test; it breaks the
        // setup sheet quietly, which is worse.
        _ = counterRevision
        return jobCounterStore.nextSheetNumber(for: JobID(rawValue: profile.id))
    }

    // MARK: Projections

    var activeBatch: ActiveBatchViewData? {
        guard let session, let batchContext else {
            return nil
        }
        // Projected once for the whole batch rather than asked per row, which
        // at 400 cards would be a quadratic walk on every redraw.
        let disagreements = Dictionary(
            session.pairSizeWarnings.map { ($0.cardID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // `completionBlockers` walks every card and every side, so it is read
        // once and both sets are derived from that one array. Reading it twice —
        // once for the blocked identifiers and once for the overridable ones —
        // measurably doubled the projection and tripped this file's own 50 ms
        // redraw budget at 400 cards.
        let blockers = session.completionBlockers
        return ActiveBatchViewData(
            id: session.id,
            profile: batchContext.profile,
            startedAt: batchContext.startedAt,
            name: session.batchName.value,
            destinationURL: batchContext.destinationURL,
            margins: session.requestedMargins,
            nextSheetNumber: session.nextSheetNumber,
            cards: session.cards.compactMap {
                cardViewData(for: $0, warning: disagreements[$0.id])
            },
            phase: ScanDeckWorkspacePhase(session.phase),
            blockedCardIDs: Set(blockers.compactMap(\.cardID)),
            overridableSizeBlockedCardIDs: Self.overridableSizeBlockedCardIDs(
                among: blockers
            )
        )
    }

    /// The selected card alone, without projecting the batch to find it.
    ///
    /// It used to read `activeBatch?.cards.first { … }`, which built every row
    /// and every side of a 186-card batch to hand back one of them — and the
    /// views that want it read `activeBatch` beside it, so a redraw projected
    /// the whole batch twice to fill one inspector pane.
    var selectedCard: CardPairViewData? {
        guard let selectedCardID, let session else {
            return nil
        }
        guard let card = session.cards.first(where: { $0.id == selectedCardID })
        else {
            return nil
        }
        return cardViewData(
            for: card,
            warning: session.pairSizeWarnings
                .first { $0.cardID == selectedCardID }
        )
    }

    var activeScanKind: ScanPassKind? {
        guard let session, case let .scanning(pass) = session.phase else {
            return nil
        }
        switch pass.operation {
        case .append:
            return .append
        case let .retry(target, _):
            return .retry(cardID: target)
        case let .replace(target, _):
            return .replace(cardID: target)
        }
    }

    private func cardViewData(
        for card: BatchCard,
        warning: PairSizeWarning?
    ) -> CardPairViewData? {
        guard let sides = card.activeSides else {
            return nil
        }
        return CardPairViewData(
            id: card.id,
            sheetNumber: card.provisionalSheetNumber,
            front: sideViewData(for: sides.front, side: .front),
            back: sideViewData(for: sides.back, side: .back),
            sizeDisagreementPixels: warning?.disagreementPixels,
            acceptedSizeDisagreement: warning?.isOperatorAccepted ?? false
        )
    }

    private func sideViewData(
        for scannedSide: ScannedSide?,
        side: OutputSide
    ) -> ScanSideViewData? {
        guard let scannedSide else {
            return nil
        }
        return ScanSideViewData(
            id: scannedSide.masterID,
            side: side,
            imageURL: masterURLs[scannedSide.masterID],
            rotation: scannedSide.rotation,
            marginAssessment: scannedSide.marginAssessment,
            publishedCrop: publishedCrops[scannedSide.masterID]
        )
    }

    // MARK: Gates — every one delegates to the reducer

    var batchNameValidationMessage: String? {
        do {
            _ = try BatchName(batchDraft.name)
            return nil
        } catch let error as BatchName.ValidationError {
            return error.errorDescription
        } catch {
            return error.localizedDescription
        }
    }

    /// Why the drafted name cannot be published to, if it cannot.
    ///
    /// Cached rather than computed in the getter below, because answering it
    /// means a `stat` and the getter is read on every keystroke of a view body
    /// — against a destination that is routinely a Google Drive mount, where a
    /// miss can be a network round trip. `refreshBatchFolderAvailability()`
    /// updates it when the name or the destination changes.
    private(set) var batchFolderConflict: String?

    var batchSetupBlockReason: String? {
        if let batchNameValidationMessage {
            return batchNameValidationMessage
        }
        if batchDraft.destinationURL == nil {
            return "Choose a destination folder."
        }
        if (try? batchDraft.margins.validated()) == nil {
            return "Enter a valid margin for every edge."
        }
        return batchFolderConflict
    }

    /// Asks whether the drafted batch name is still free at the destination.
    ///
    /// `SPEC.md` §4 beat 2 requires this at arming, not only at publication.
    /// Only publication checked, so a reused name was discovered at Complete
    /// Batch — after every card had been fed, with no UI to rename a batch and
    /// nothing to do but rename the existing folder in Finder. Nothing was ever
    /// lost, but on a 150-card run that is a nasty place to learn it.
    func refreshBatchFolderAvailability() {
        guard let destinationURL = batchDraft.destinationURL,
              let batchName = try? BatchName(batchDraft.name)
        else {
            batchFolderConflict = nil
            return
        }
        batchFolderConflict = Self.batchFolderConflictMessage(
            for: batchName,
            in: destinationURL
        )
    }

    /// Reveals the folder that is blocking this name.
    ///
    /// The other half of `SPEC.md` §4 beat 2's "offers a different name or Show
    /// in Finder": the field above renames, and this answers the question the
    /// operator actually has, which is what is in a folder they may not
    /// remember creating.
    func showConflictingBatchFolderInFinder() {
        guard batchFolderConflict != nil,
              let destinationURL = batchDraft.destinationURL,
              let batchName = try? BatchName(batchDraft.name)
        else {
            return
        }
        actions.showInFinder(
            BatchPublisher.batchFolderURL(
                for: batchName,
                in: destinationURL
            )
        )
    }

    private static func batchFolderConflictMessage(
        for batchName: BatchName,
        in destinationRoot: URL
    ) -> String? {
        guard !BatchPublisher.batchFolderIsAvailable(
            for: batchName,
            in: destinationRoot
        ) else {
            return nil
        }
        return "A folder named “\(batchName.value)” is already in "
            + "\(DestinationBookmarkStore.displayName(for: destinationRoot)). "
            + "ScanDeck never merges into or overwrites an existing batch "
            + "folder, so choose another name or move that one."
    }

    var canArmBatch: Bool {
        batchSetupBlockReason == nil
    }

    var canStartScan: Bool {
        guard let session, scannerConnection.isReady else {
            return false
        }
        return session.canContinueScanning
    }

    var canCompleteBatch: Bool {
        session?.canCompleteBatch ?? false
    }

    var scanButtonTitle: String {
        guard let session, !session.cards.isEmpty else {
            return "Scan"
        }
        return "Continue Scanning"
    }

    var completionBlockReason: String? {
        guard let session else {
            return "Start a batch first."
        }
        if case .scanning = session.phase {
            return "Wait for the current pass to finish."
        }
        if case .releasing = session.phase {
            return "Publishing this batch…"
        }
        return session.completionBlockers.first?.operatorMessage
    }

    // MARK: Batch lifecycle

    func selectProfile(_ profile: ScanProfileViewData) {
        if let session,
           batchContext?.profile.id == profile.id,
           ScanDeckWorkspacePhase(session.phase) != .completed {
            sidebarSelection = .activeBatch
            selectedCardID = activeBatch?.cards.first?.id
            return
        }

        batchDraft = BatchSetupDraft(
            name: "",
            margins: MarginValues(
                top: profile.defaultMarginMillimeters,
                right: profile.defaultMarginMillimeters,
                bottom: profile.defaultMarginMillimeters,
                left: profile.defaultMarginMillimeters,
                linked: true
            ),
            destinationURL: batchDraft.destinationURL
        )
        isBatchSetupPresented = true
    }

    func dismissBatchSetup() {
        isBatchSetupPresented = false
    }

    func chooseDestination() {
        guard let destinationURL = destinationPicker.pickDestination(
            startingAt: batchDraft.destinationURL
        ) else {
            return
        }

        // Accept the pick first. Persistence is a convenience for the next
        // launch, so failing to write the bookmark must not discard a folder
        // the operator just chose and can use for this batch.
        batchDraft.destinationURL = destinationURL
        notice = nil

        // An active batch follows the new choice. Without this, a recovered
        // batch whose destination was unmounted or renamed could never be
        // completed, and the operator's only remaining move would be to discard
        // pages the app promised to keep.
        if let batchContext {
            self.batchContext = BatchContext(
                profile: batchContext.profile,
                startedAt: batchContext.startedAt,
                destinationURL: destinationURL
            )
            saveSession()
        }

        do {
            try destinationBookmarkStore.save(destinationURL)
        } catch {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "Destination will not be remembered",
                message: "ScanDeck can publish to this folder now, but could "
                    + "not save it for next launch: \(error.localizedDescription)"
            )
        }
    }

    func armBatch(profile: ScanProfileViewData? = nil) {
        guard let destinationURL = batchDraft.destinationURL,
              let selectedProfile = profile ?? profiles.first
        else {
            return
        }

        do {
            let batchName = try BatchName(batchDraft.name)
            let margins = try batchDraft.margins.validated()

            // Asked again at the moment of pressing, not trusted from whenever
            // the field last changed: the folder can appear in between, and on
            // a shared Drive it routinely does. Publication still re-checks
            // immediately before the rename — this does not replace that, it
            // moves the discovery to before the feeder is loaded.
            if let conflict = Self.batchFolderConflictMessage(
                for: batchName,
                in: destinationURL
            ) {
                batchFolderConflict = conflict
                notice = ScanDeckNotice(
                    kind: .warning,
                    title: "That batch name is taken",
                    message: conflict
                )
                return
            }
            batchFolderConflict = nil

            let jobID = JobID(rawValue: selectedProfile.id)
            session = BatchSession(
                id: BatchID(rawValue: UUID()),
                jobID: jobID,
                batchName: batchName,
                firstSheetNumber: jobCounterStore.nextSheetNumber(for: jobID),
                deliveryOrder: selectedProfile.deliveryOrder,
                requestedMargins: margins,
                captureRotation: selectedProfile.captureRotation
            )
            batchContext = BatchContext(
                profile: selectedProfile,
                startedAt: .now,
                destinationURL: destinationURL
            )
            masterURLs = [:]
            selectedCardID = nil
            notice = nil
            completionSummary = nil
            isBatchSetupPresented = false
            sidebarSelection = .activeBatch
            hasReportedAutosaveFailure = false
            // The name, destination, and starting number are operator input,
            // so the batch is recoverable from the moment it exists rather than
            // from its first captured page.
            saveSession()
        } catch {
            notice = ScanDeckNotice(
                kind: .error,
                title: "Batch could not be created",
                message: error.localizedDescription
            )
        }
    }

    func showProfiles() {
        sidebarSelection = .profiles
    }

    // MARK: Crash recovery

    /// Reads unfinished batches left behind by a previous run.
    ///
    /// Finishes any release the app died in the middle of, before anything is
    /// offered for recovery. TICKET-006b.
    ///
    /// The window this closes: publication renames the staging directory into
    /// place, and only then is the counter committed. Between those two the
    /// batch folder exists on the destination while the numbers it used were
    /// never reserved, and they are on different volumes so no filesystem
    /// transaction can span them. Asked what should happen, the operator chose
    /// *"fix itself at next launch"* over the error message it used to print.
    ///
    /// The record that describes the batch is the journal (see
    /// `RecoverableSessions.interruptedReleases`), and its phase says how much
    /// is already known:
    ///
    /// - **`.completed`.** The reducer moved there because the rename had
    ///   already succeeded, so the numbers were used and the counter has to
    ///   follow, without asking the destination anything. That the folder
    ///   might since have been moved or deleted changes nothing: reusing a
    ///   published range is the failure worth avoiding, and it stays a failure
    ///   whether or not the folder is still where it landed.
    /// - **`.releasing`, and the batch folder is there.** The rename landed
    ///   but the app died before recording it. Same outcome.
    /// - **`.releasing`, and it is not.** The rename never happened, so the
    ///   batch returns to review with its numbers intact — `SPEC.md` section
    ///   5's "returns the batch to review without reusing a published range".
    /// - **`.releasing`, and the destination cannot be resolved.** Decide
    ///   nothing. Committing would burn numbers for a batch that may not
    ///   exist and reverting would offer a batch that may already be
    ///   published; the record stays and the question is asked again next
    ///   launch, which is the only honest answer while the volume is missing.
    ///
    /// Idempotent against a second crash *during* recovery, which is the whole
    /// reason this is a journal rather than a flag: `JobCounterStore.commit`
    /// is monotonic, so committing a number already stored is a no-op, and a
    /// record that is removed twice is removed once.
    ///
    /// - Returns: whether anything changed on disk.
    @discardableResult
    private func finishInterruptedReleases(
        _ records: [PersistedBatchSession]
    ) -> Bool {
        guard !records.isEmpty else {
            return false
        }

        var finished: [(name: String, nextNumber: UInt64)] = []
        var returnedToReview: [String] = []
        var undecided = 0
        var changed = false

        for record in records {
            let session = record.session

            var attemptToRevert: ReleaseAttempt?
            if case let .releasing(attempt) = session.phase {
                switch publishedFolderLanded(for: record) {
                case .yes:
                    break
                case .no:
                    attemptToRevert = attempt
                case .unknown:
                    undecided += 1
                    continue
                }
            }

            guard let attempt = attemptToRevert else {
                do {
                    try jobCounterStore.commit(
                        nextSheetNumber: session.nextSheetNumber,
                        for: session.jobID
                    )
                    try sessionStore.discard(session.id)
                    counterRevision += 1
                    changed = true
                    finished.append(
                        (session.batchName.value, session.nextSheetNumber)
                    )
                } catch {
                    // Leave the record. Next launch asks again, and until then
                    // nothing has claimed numbers it did not use.
                    undecided += 1
                }
                continue
            }

            var reverted = session
            do {
                _ = try BatchSessionReducer.reduce(
                    .completionFailed(
                        attemptID: attempt.id,
                        issue: BatchIssue(
                            kind: .releaseFailed,
                            message: "ScanDeck stopped before this batch "
                                + "reached the destination. Every card is "
                                + "still here and no sheet numbers were used."
                        )
                    ),
                    into: &reverted
                )
                try sessionStore.save(
                    PersistedBatchSession(
                        session: reverted,
                        masterURLs: Dictionary(
                            record.masters.map { ($0.masterID, $0.url) },
                            uniquingKeysWith: { first, _ in first }
                        ),
                        startedAt: record.startedAt,
                        savedAt: .now,
                        destinationBookmark: record.destinationBookmark
                    )
                )
                changed = true
                returnedToReview.append(session.batchName.value)
            } catch {
                undecided += 1
            }
        }

        announceFinishedReleases(
            finished: finished,
            returnedToReview: returnedToReview,
            undecided: undecided
        )
        return changed
    }

    private enum PublishedFolderVerdict {
        case yes
        case no
        /// The destination could not be reached, so neither answer is honest.
        case unknown
    }

    /// Whether the batch folder this record was publishing actually landed.
    private func publishedFolderLanded(
        for record: PersistedBatchSession
    ) -> PublishedFolderVerdict {
        guard let bookmark = record.destinationBookmark,
              let resolved = DestinationBookmarkStore.resolve(bookmark)
        else {
            return .unknown
        }
        let accessed = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                resolved.url.stopAccessingSecurityScopedResource()
            }
        }
        // The root itself has to be reachable, or "the folder is not there"
        // and "the volume is not mounted" are the same observation — and they
        // call for opposite actions.
        guard FileManager.default.fileExists(atPath: resolved.url.path) else {
            return .unknown
        }
        return FileManager.default.fileExists(
            atPath: BatchPublisher.batchFolderURL(
                for: record.session.batchName,
                in: resolved.url
            ).path
        ) ? .yes : .no
    }

    /// Says what recovery did, because a counter that moves on its own is
    /// exactly the kind of silent change that costs trust the first time the
    /// operator notices a number they did not expect.
    private func announceFinishedReleases(
        finished: [(name: String, nextNumber: UInt64)],
        returnedToReview: [String],
        undecided: Int
    ) {
        if let first = finished.first {
            let others = finished.count - 1
            notice = ScanDeckNotice(
                kind: .information,
                title: "Finished saving a counter",
                message: "\(first.name) had already reached the destination "
                    + "when ScanDeck stopped, but its sheet counter had not "
                    + "been saved. It has been saved now — the next batch "
                    + "starts at \(SheetNumber.formatted(first.nextNumber))."
                    + (
                        others > 0
                            ? " \(others) other batch"
                                + "\(others == 1 ? "" : "es") "
                                + "\(others == 1 ? "was" : "were") finished "
                                + "the same way."
                            : ""
                    )
            )
            return
        }
        if let first = returnedToReview.first {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "A batch never reached the destination",
                message: "\(first) was being published when ScanDeck stopped, "
                    + "and its folder never appeared. Every card is still "
                    + "here and no sheet numbers were used, so it is offered "
                    + "for recovery below."
            )
            return
        }
        guard undecided > 0 else {
            return
        }
        notice = ScanDeckNotice(
            kind: .warning,
            title: "A batch is waiting on its destination",
            message: "\(undecided) published batch"
                + "\(undecided == 1 ? "" : "es") cannot be checked because "
                + "the destination folder is unavailable. Nothing has been "
                + "changed; reconnect it and relaunch ScanDeck to finish."
        )
    }

    /// Records that reached `.releasing` or `.completed` are readable but not
    /// offered: they describe a batch that already asked to be published, and
    /// resuming one could republish a folder that already landed. They are
    /// handled by `finishInterruptedReleases` above rather than deleted.
    private func loadRecoveredBatches() {
        var found = sessionStore.load()
        if finishInterruptedReleases(found.interruptedReleases) {
            // Re-read, because finishing one either removes its record or
            // returns it to review, and the recovery sheet must show what is
            // true after that rather than before.
            found = sessionStore.load()
        }

        recoveredRecords = Dictionary(
            found.resumable.map { ($0.session.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        recoveredBatches = found.resumable.map(Self.recoveredViewData(for:))
        isRecoveryPresented = !recoveredBatches.isEmpty

        guard !found.unreadableDirectories.isEmpty else {
            return
        }
        // Never quietly swallow this. The images are still on disk, and saying
        // so is the difference between a recoverable mistake and a lost batch.
        notice = ScanDeckNotice(
            kind: .warning,
            title: "A saved batch could not be read",
            message: "\(found.unreadableDirectories.count) unfinished "
                + "batch\(found.unreadableDirectories.count == 1 ? "" : "es") "
                + "could not be restored, so ScanDeck has left "
                + "\(found.unreadableDirectories.count == 1 ? "it" : "them") "
                + "alone. The captured images are still in "
                + "\(found.unreadableDirectories[0].deletingLastPathComponent().path)."
        )
    }

    private static func recoveredViewData(
        for record: PersistedBatchSession
    ) -> RecoveredBatchViewData {
        let activeCards = record.session.cards.filter { $0.activeSides != nil }
        let incomplete = activeCards.filter {
            $0.activeSides?.isComplete == false
        }
        let wasScanning: Bool = if case .scanning = record.session.phase {
            true
        } else {
            false
        }

        return RecoveredBatchViewData(
            id: record.session.id,
            jobID: record.session.jobID,
            batchName: record.session.batchName.value,
            cardCount: activeCards.count,
            incompleteCardCount: incomplete.count,
            counterRange: activeCards.map(\.provisionalSheetNumber)
                .minAndMaxRange(),
            savedAt: record.savedAt,
            wasInterruptedMidScan: wasScanning
        )
    }

    /// Puts the operator back into a recovered batch.
    ///
    /// A pass that was mid-flight becomes an interrupted one: the reducer moves
    /// to review, retires the half-captured sides, and says the captured cards
    /// are safe. Every remaining side is then re-assessed against the file that
    /// is actually on disk now, so a master that vanished between runs blocks
    /// completion and names its card instead of failing at publication.
    func resumeRecoveredBatch(_ batchID: BatchID) {
        guard let record = recoveredRecords[batchID] else {
            return
        }
        guard let profile = profiles.first(where: {
            JobID(rawValue: $0.id) == record.session.jobID
        }) ?? profiles.first else {
            return
        }

        let destinationURL = record.destinationBookmark
            .flatMap { DestinationBookmarkStore.resolve($0)?.url }

        session = record.session
        masterURLs = record.masterURLs
        batchContext = BatchContext(
            profile: profile,
            startedAt: record.startedAt,
            destinationURL: destinationURL
        )
        selectedCardID = nil
        completionSummary = nil
        notice = nil
        hasReportedAutosaveFailure = false
        forget(batchID)
        // The operator is inside a batch now. Anything else that was found
        // stays on disk and is offered again next launch.
        isRecoveryPresented = false

        if case .scanning = record.session.phase {
            dispatch(.recoverInterruptedScan)
        }
        reassessRecoveredMargins()

        if destinationURL == nil {
            // Publication would fail at the very end otherwise, after the
            // operator has already reviewed everything.
            notice = ScanDeckNotice(
                kind: .warning,
                title: "Choose where this batch goes",
                message: "\(record.session.batchName.value) was recovered, but "
                    + "its destination folder is no longer available. Every card "
                    + "is safe; choose a new destination before completing it."
            )
        } else if let issue = session?.lastIssue {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "Batch recovered",
                message: issue.message
            )
        }

        sidebarSelection = .activeBatch
        saveSession()
    }

    /// Deletes a recovered batch and every page it captured.
    ///
    /// The one call in ScanDeck that discards acknowledged pages, so it is
    /// reached only from an explicit, confirmed operator decision.
    func discardRecoveredBatch(_ batchID: BatchID) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await autosaver.discard(batchID)
                forget(batchID)
            } catch {
                notice = ScanDeckNotice(
                    kind: .error,
                    title: "Batch could not be discarded",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func forget(_ batchID: BatchID) {
        recoveredRecords.removeValue(forKey: batchID)
        recoveredBatches.removeAll { $0.id == batchID }
        isRecoveryPresented = !recoveredBatches.isEmpty
    }

    /// Leaves every recovered batch exactly where it is.
    ///
    /// Closing the prompt is not a decision about the pages, so nothing is
    /// deleted and the same batches are offered again next launch.
    func dismissRecovery() {
        isRecoveryPresented = false
    }

    /// Mirrors the PaperStream §17 pattern — a concrete count, not "some work
    /// was recovered" — with cards as the unit, because a card is what the
    /// operator fed and what they would have to feed again.
    var recoveryHeadline: String {
        guard recoveredBatches.count == 1, let batch = recoveredBatches.first
        else {
            return "\(recoveredBatches.count) unfinished batches were recovered."
        }
        return "An unfinished \(batch.cardCount)-card batch was recovered."
    }

    /// Re-runs crop analysis for every side a recovered batch still holds.
    ///
    /// The persisted verdicts were true when they were written; the files they
    /// describe have been sitting on a disk the app was not watching. Trusting
    /// them would let a batch complete against an image that is gone or
    /// changed.
    /// Re-analyses every recovered side, a few at a time.
    ///
    /// This used to be a plain loop firing one detached full-resolution decode
    /// per side with nothing holding them back. At four cards that is eight
    /// tasks and invisible; on the operator's recovered 186-card batch it is
    /// **372 concurrent decodes of a 3232 × 4248 master**, roughly 55 MB of
    /// pixels each — tens of gigabytes asked for at once on a 36 GB machine,
    /// with the main actor left contending with its own analysis for as long as
    /// it takes to page all of that through. `SPEC.md` section 6.3 already
    /// required pipeline work to be bounded; this was the one place it was not,
    /// and it sits directly upstream of the unresponsive window TICKET-030
    /// records.
    ///
    /// Four at a time because that is where the measured return flattens: on
    /// this machine a 600 dpi master takes 0.22 s to process serially, 0.071 s
    /// at width 4, and 0.063 s at width 6 — the last two thirds of the memory
    /// buy almost nothing.
    private func reassessRecoveredMargins() {
        guard let session else {
            return
        }
        let margins = session.requestedMargins
        let pending = session.cards.flatMap { card -> [(MasterID, QuarterTurns)] in
            guard let sides = card.activeSides else {
                return []
            }
            return [OutputSide.front, .back].compactMap { side in
                sides[side].map { ($0.masterID, $0.rotation) }
            }
        }

        Task { [weak self] in
            // A sliding window of started analyses. `Task` here inherits the
            // main actor, so awaiting one is awaiting the detached decode it
            // owns — which is what makes counting them a real bound rather
            // than a bound on bookkeeping.
            var inFlight: [Task<Void, Never>] = []
            for (masterID, rotation) in pending {
                if inFlight.count >= Self.marginAnalysisConcurrency {
                    await inFlight.removeFirst().value
                }
                inFlight.append(
                    Task { [weak self] in
                        await self?.assessMargin(
                            masterID: masterID,
                            rotation: rotation,
                            margins: margins
                        )
                    }
                )
            }
            for task in inFlight {
                await task.value
            }
        }
    }

    /// How many full-resolution analyses may run at once. See
    /// `reassessRecoveredMargins` for the measurement behind the number.
    private static let marginAnalysisConcurrency = 4

    func resumeActiveBatch() {
        guard session != nil else {
            return
        }
        sidebarSelection = .activeBatch
    }

    // MARK: - Automatic continue
    //
    // Manual feeding one card at a time means one Continue Scanning press per
    // card. This presses it for the operator. It is a convenience over the
    // existing action and adds no capability: every pass it starts goes through
    // `performScan` and is refused by exactly the same gates as a pressed one.

    /// Whether to start the next pass without being asked.
    ///
    /// Deliberately not persisted. A batch that resumes scanning by itself at
    /// launch, before anyone has looked at the feeder, is not a convenience.
    var isAutoContinueEnabled = false {
        didSet {
            if !isAutoContinueEnabled {
                cancelAutoContinue()
            }
        }
    }

    /// Seconds left before the next pass starts, for the operator to watch and
    /// interrupt. `nil` when nothing is scheduled.
    private(set) var autoContinueCountdown: Int?

    var autoContinueSeconds: Int {
        get { settings.autoContinueSeconds }
        set {
            var updated = settings
            updated.autoContinueSeconds = min(
                max(newValue, ScanDeckSettings.autoContinueSecondsRange.lowerBound),
                ScanDeckSettings.autoContinueSecondsRange.upperBound
            )
            apply(updated)
        }
    }

    /// The tone curve the review grid shows and publication will bake in.
    ///
    /// Held here rather than on the session for a reason worth keeping: it is
    /// re-appliable from untouched masters, so nothing about it needs to
    /// survive a crash, and adding a field to the session record would have
    /// meant migrating a schema with a real unpublished batch sitting in it.
    var brightness: BrightnessAdjustment {
        get { settings.brightness }
        set {
            guard newValue != settings.brightness else {
                return
            }
            var updated = settings
            updated.brightness = newValue
            apply(updated)
        }
    }

    @ObservationIgnored
    private var autoContinueTask: Task<Void, Never>?

    /// How many pages the pass now ending actually delivered. A pass that
    /// brought nothing back is where an automatic run stops, because it means
    /// the feeder is empty or something is wrong with it.
    @ObservationIgnored
    private var pagesInCurrentPass = 0

    func cancelAutoContinue() {
        autoContinueTask?.cancel()
        autoContinueTask = nil
        autoContinueCountdown = nil
    }

    private func scheduleAutoContinue() {
        cancelAutoContinue()
        let seconds = autoContinueSeconds
        autoContinueCountdown = seconds
        autoContinueTask = Task { [weak self] in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard let self, !Task.isCancelled else {
                    return
                }
                autoContinueCountdown = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else {
                return
            }
            autoContinueCountdown = nil
            // Re-asked at the moment of firing, never assumed from when it was
            // scheduled: a card can have been deleted, the scanner unplugged,
            // or the batch completed during the countdown.
            guard isAutoContinueEnabled, canStartScan else {
                isAutoContinueEnabled = false
                return
            }
            performScan(.append)
        }
    }

    /// Decides whether the run carries on after a pass ends.
    ///
    /// Only a clean pass continues. A failure stops it because the operator has
    /// to clear something — a jam is not a thing to drive into again five
    /// seconds later — and a blocked gate stops it because the reducer has
    /// something to say that a new pass would talk over.
    private func continueAutomaticallyIfAppropriate(
        after completion: ScanPassCompletion
    ) {
        guard isAutoContinueEnabled else {
            return
        }
        guard completion == .succeeded, pagesInCurrentPass > 0, canStartScan
        else {
            isAutoContinueEnabled = false
            return
        }
        scheduleAutoContinue()
    }

    /// What Cancel Batch is about to throw away, counted rather than described.
    ///
    /// "Are you sure?" is not a question anyone can answer. The number of cards
    /// and the fact that the numbers come back are what make it one.
    var cancelBatchConfirmationMessage: String {
        guard let batch = activeBatch else {
            return "There is no active batch."
        }
        let count = batch.cards.count
        guard count > 0 else {
            return "“\(batch.name)” has no cards yet, so nothing is deleted. "
                + "No sheet numbers were used."
        }
        return "\(count) card\(count == 1 ? "" : "s") and every image "
            + "captured for “\(batch.name)” will be deleted permanently. No "
            + "sheet numbers were used, so the next batch starts again from "
            + "\(SheetNumber.formatted(batch.cards[0].sheetNumber))."
    }

    /// Whether the active batch can be abandoned right now.
    ///
    /// Not while a pass is feeding — the scanner is moving paper and the pages
    /// it is about to hand over have nowhere to go — and not while publication
    /// is under way, where the destination is mid-rename. Both come from the
    /// reducer's own phase; this adds no rule of its own.
    var canCancelBatch: Bool {
        guard let session else {
            return false
        }
        switch ScanDeckWorkspacePhase(session.phase) {
        case .scanning, .completing:
            return false
        case .ready, .review, .completed:
            return true
        }
    }

    /// Abandons the active batch and deletes every page it captured.
    ///
    /// The second call in ScanDeck that discards acknowledged pages, and it
    /// exists for the same reason as the first: the operator has decided the
    /// batch is wrong — the wrong holder, the wrong stack, the wrong day — and
    /// without this their only way out is to quit the app and discard from the
    /// recovery sheet at the next launch. Invariant #1 is about failures never
    /// losing a page, not about the operator being unable to throw one away, so
    /// this sits behind an explicit confirmation that says what goes.
    ///
    /// It burns no counter numbers. Provisional numbers are only ever committed
    /// by a successful completion (invariant #7), so an abandoned batch leaves
    /// the counter exactly where it started and the next batch reuses the same
    /// range.
    func cancelActiveBatch() {
        guard let session, canCancelBatch else {
            return
        }
        let batchID = session.id
        let batchName = session.batchName.value
        let cardCount = activeBatch?.cards.count ?? 0

        scanTask?.cancel()
        scanTask = nil
        isCancelBatchConfirmationPresented = false
        clearActiveBatchState()

        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await autosaver.discard(batchID)
                notice = ScanDeckNotice(
                    kind: .information,
                    title: "Batch cancelled",
                    message: "“\(batchName)” and its "
                        + "\(cardCount) card\(cardCount == 1 ? "" : "s") were "
                        + "deleted. No sheet numbers were used, so the next "
                        + "batch starts from "
                        + "\(SheetNumber.formatted(nextSheetNumberForActiveProfile()))."
                )
            } catch {
                // The batch is gone from the app either way; saying so matters
                // because the images are still on disk and the operator may
                // want them.
                notice = ScanDeckNotice(
                    kind: .warning,
                    title: "Batch cancelled, files left behind",
                    message: "“\(batchName)” was closed, but its captured "
                        + "images could not be deleted: "
                        + "\(error.localizedDescription) They are still on "
                        + "disk — Settings › Files shows where."
                )
            }
        }
    }

    private func nextSheetNumberForActiveProfile() -> UInt64 {
        guard let profile = profiles.first else {
            return JobCounterStore.firstSheetNumber
        }
        return nextSheetNumber(for: profile)
    }

    private func clearActiveBatchState() {
        session = nil
        batchContext = nil
        masterURLs = [:]
        publishedCrops = [:]
        selectedCardID = nil
        completionSummary = nil
        centeringCheckStatus = nil
        centeringCheckConsent = nil
        centeringCheckRunID = nil
        notice = nil
        scanStatusMessage = nil
        hasReportedAutosaveFailure = false
        sidebarSelection = .profiles
    }

    func startNewBatchFromCompletion() {
        guard let profile = batchContext?.profile ?? profiles.first else {
            return
        }
        session = nil
        batchContext = nil
        masterURLs = [:]
        completionSummary = nil
        centeringCheckStatus = nil
        centeringCheckConsent = nil
        centeringCheckRunID = nil
        selectedCardID = nil
        sidebarSelection = .profiles
        selectProfile(profile)
    }

    func toggleInspector() {
        isInspectorPresented.toggle()
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: Review actions

    func rotate(
        cardID: CardID,
        side: OutputSide,
        clockwise: Bool = true
    ) {
        dispatch(
            .rotate(
                cardID: cardID,
                side: side,
                direction: clockwise ? .clockwise : .counterclockwise
            )
        )
    }

    func rotateSelectedCardSide(_ side: OutputSide) {
        guard let selectedCardID else {
            return
        }
        rotate(cardID: selectedCardID, side: side)
    }

    func deleteSide(cardID: CardID, side: OutputSide) {
        dispatch(.deleteSide(cardID: cardID, side: side))
        selectedCardID = cardID
        // Deliberate operator action: whatever the banner said before, the
        // fresh incomplete card is now the thing to talk about.
        notice = nil
        announceIncompleteCards()
    }

    func deleteCard(_ cardID: CardID) {
        let remaining = activeBatch?.cards ?? []
        let removedIndex = remaining.firstIndex { $0.id == cardID }
        // A notice about this card cannot outlive it. Every route here — the
        // row's context menu, the inspector, the banner's own Delete Card —
        // otherwise leaves a banner offering Retry or Replace for a row that no
        // longer exists, and since the banner is pinned it now sits over the
        // batch for the rest of the session. Pressing it reaches a reducer that
        // refuses a deleted card, so the operator's reward for taking the
        // advice on screen is a second error.
        if notice?.cardID == cardID {
            notice = nil
        }
        dispatch(.deleteCard(cardID: cardID))

        let cards = activeBatch?.cards ?? []
        if let removedIndex, cards.indices.contains(removedIndex) {
            selectedCardID = cards[removedIndex].id
        } else {
            selectedCardID = cards.last?.id
        }
        if cards.allSatisfy({ !$0.isIncomplete }), notice?.title == "Incomplete card" {
            notice = nil
        }
        // Deleting the blocked card may have unblocked completion, or left a
        // different card blocking it. Either way the banner should describe
        // the batch as it is now rather than as it was one press ago.
        surfacePairMismatch()
    }

    func deleteSelectedCard() {
        guard let selectedCardID else {
            return
        }
        deleteCard(selectedCardID)
    }

    // MARK: Scanning

    func startOrContinueScan() {
        guard canStartScan else {
            // The scanner comes first even when a card is also incomplete: no
            // scanner blocks every corrective move, including the Retry the
            // other notice would send the operator to press.
            if !scannerConnection.isReady {
                announceScannerCondition()
            } else if let blocker = session?.continuationBlockers.first {
                notice = ScanDeckNotice(
                    kind: .warning,
                    title: "Incomplete card",
                    message: "Card \(SheetNumber.formatted(blocker.provisionalSheetNumber)) "
                        + "must be retried or deleted before scanning continues.",
                    action: .retryCard(blocker.cardID)
                )
            }
            return
        }
        performScan(.append)
    }

    /// States the hardware condition that is blocking a scan, in its own words.
    ///
    /// Retry and Replace reach here too: pressing either with the scanner gone
    /// would otherwise begin a pass that fails on the scanner instead of saying
    /// up front that there is nothing to scan with.
    private func announceScannerCondition() {
        notice = ScanDeckNotice(
            kind: .warning,
            title: scannerConnection.title,
            message: scannerConnection.correctiveAction ?? scannerConnection.summary
        )
    }

    func retryCard(_ cardID: CardID) {
        performScan(.retry(cardID: cardID))
    }

    func replaceCard(_ cardID: CardID) {
        performScan(.replace(cardID: cardID))
    }

    func retrySelectedCard() {
        guard let selectedCardID else {
            return
        }
        retryCard(selectedCardID)
    }

    func replaceSelectedCard() {
        guard let selectedCardID else {
            return
        }
        replaceCard(selectedCardID)
    }

    private func performScan(_ kind: ScanPassKind) {
        guard let session, let batchContext else {
            return
        }
        guard scannerConnection.isReady else {
            // Retry and Replace do not route through `canStartScan`, and every
            // one of them needs a scanner. Refusing here beats starting a pass
            // whose only possible outcome is a hardware failure banner.
            announceScannerCondition()
            return
        }

        let passID = ScanPassID(rawValue: UUID())
        let beginAction: BatchAction = switch kind {
        case .append:
            .beginAppend(passID: passID)
        case let .retry(cardID):
            .beginRetry(cardID: cardID, passID: passID)
        case let .replace(cardID):
            .beginReplace(cardID: cardID, passID: passID)
        }

        guard dispatch(beginAction) != nil else {
            return
        }
        notice = nil
        scanStatusMessage = nil
        pagesInCurrentPass = 0
        cancelAutoContinue()
        scannerStatus.passDidStart()

        let request = ScanPassRequest(
            batchID: session.id,
            passID: passID,
            kind: kind,
            profile: batchContext.profile,
            margins: session.requestedMargins
        )

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else {
                return
            }
            for await progress in actions.scan(request) {
                guard !Task.isCancelled else {
                    return
                }
                receive(progress, passID: passID)
            }
        }
    }

    private func receive(_ progress: ScanPassProgress, passID: ScanPassID) {
        switch progress {
        case let .status(message):
            scanStatusMessage = message

        case let .notice(notice):
            receive(notice)

        case let .page(url):
            receivePage(url, passID: passID)

        case let .finished(completion):
            scanStatusMessage = nil
            scannerStatus.passDidEnd()
            // The transport is expected to withdraw this itself, and does. The
            // belt is here because the cost of it being wrong is an operator
            // reading "another application is holding the scanner" over a batch
            // that just scanned perfectly — and a raised state with only one
            // way down is how that happens.
            withdrawScannerBusyNotice()
            // Captured while the session still holds the pass — `scanEnded`
            // leaves `.scanning`, and the failure notice needs to know what
            // the pass was doing to offer the right retry.
            let endedPassKind = activeScanKind
            let outcome: ScanOutcome = switch completion {
            case .succeeded:
                .completed
            case let .failed(message, reason):
                .failed(
                    BatchIssue(
                        kind: .scanFailed,
                        // The reducer keeps this string and hands it back at
                        // recovery, so the substitution has to happen here
                        // rather than only in the banner — otherwise resuming
                        // the batch tomorrow greets the operator with
                        // "Expected at least one scanned page… (Error Code:
                        // 0x03800320)" for a feeder they emptied on purpose.
                        // This is the one condition SPEC section 6 lets the app
                        // describe in its own words; everything else keeps the
                        // driver's sentence verbatim.
                        message: reason == .feederEmpty
                            ? Self.feederEmptyIssueMessage
                            : message
                    )
                )
            }
            dispatch(.scanEnded(passID: passID, outcome: outcome))
            finishScanPass(
                endedPassKind: endedPassKind,
                completion: completion
            )
            // Last, so it reads the state the reducer and the notices have
            // already settled rather than racing them.
            continueAutomaticallyIfAppropriate(after: completion)
        }
    }

    /// Explains a pass that has stalled on the single-client scanner.
    ///
    /// Nothing else would. The pass is neither failing nor delivering, so
    /// without this the operator watches a "Scanning feeder…" spinner that will
    /// sit there until the probe's deadline runs out. The status monitor is
    /// told first, so the sidebar and this banner are two views of one fact
    /// rather than two claims that can disagree.
    private func receive(_ passNotice: ScanPassNotice) {
        scannerStatus.receive(passNotice)

        switch passNotice {
        case .scannerInUseElsewhere:
            let announcement = ScanDeckNotice(
                kind: .warning,
                title: scannerConnection.title,
                message: scannerConnection.correctiveAction ?? scannerConnection.summary
            )
            scannerBusyNoticeID = announcement.id
            notice = announcement

        case .scannerAvailableAgain:
            withdrawScannerBusyNotice()
        }
    }

    /// Takes back the stalled-scanner banner, and only that one.
    ///
    /// Matched by identifier rather than by title: the title contains the
    /// device's name, and a notice should not be recognised by copy that is
    /// free to change.
    private func withdrawScannerBusyNotice() {
        if let scannerBusyNoticeID, notice?.id == scannerBusyNoticeID {
            notice = nil
        }
        scannerBusyNoticeID = nil
    }

    private func receivePage(_ url: URL, passID: ScanPassID) {
        guard let session else {
            return
        }
        let masterID = MasterID(rawValue: UUID())

        // The reducer tracks whether a card is already awaiting its second
        // side; a new identifier is supplied only when a page starts a card.
        let newCardID: CardID? = if case let .scanning(pass) = session.phase,
                                    case let .append(pendingCardID) = pass.operation,
                                    pendingCardID == nil {
            CardID(rawValue: UUID())
        } else {
            nil
        }

        // Record the master before dispatching so the projection can resolve
        // the image the moment the reducer accepts the page.
        masterURLs[masterID] = url
        guard dispatch(
            .pageReceived(
                passID: passID,
                masterID: masterID,
                captureSequence: session.nextCaptureSequence,
                newCardID: newCardID
            )
        ) != nil else {
            masterURLs.removeValue(forKey: masterID)
            return
        }
        pagesInCurrentPass += 1
    }

    private func finishScanPass(
        endedPassKind: ScanPassKind?,
        completion: ScanPassCompletion
    ) {
        guard let session else {
            return
        }
        if case .failed(_, .feederEmpty) = completion {
            notice = feederEmptyNotice(endedPassKind: endedPassKind)
        } else if let issue = session.lastIssue {
            let action = retryAction(for: endedPassKind)
            notice = ScanDeckNotice(
                kind: .error,
                title: "Scan could not finish",
                message: issue.capturedCardsRemainSafe
                    ? "\(issue.message) Every card captured so far is safe."
                        + cardSentence(for: action)
                    : issue.message + cardSentence(for: action),
                action: action
            )
        }
        // `!isDeleted` matters: `session.cards` keeps deleted rows so the
        // counter's gaps stay explainable, while the review grid does not show
        // them. Selecting one would leave the inspector blank on a card the
        // operator cannot see.
        selectedCardID = selectedCardID
            ?? session.cards.first(where: { !$0.isDeleted })?.id
        announceIncompleteCards()
        surfacePairMismatch()
    }

    /// An empty chute is a state, not a fault.
    ///
    /// The driver distinguishes it (`0x03800320`) from a jam (`0x03800131`)
    /// and the seam now carries that distinction, so this is the one failure
    /// the app is entitled to describe in its own words rather than the
    /// driver's — and it should, because the driver's sentence is
    /// "Expected at least one scanned page, but received none. Scanner
    /// reported: No documents in the ADF paper chute. (Error Code:
    /// 0x03800320)" in red, over what is simply the operator having finished
    /// feeding. It still names the corrective press, because an empty feeder
    /// that was *not* meant to be empty is a card that failed to pick.
    ///
    /// The count is cards rather than sides: this notice is read after the
    /// feed, where the review grid is the thing being counted, unlike the
    /// live status line which cannot know pairing yet.
    /// What the batch record remembers about a pass that found nothing.
    ///
    /// Countless rather than counted: the banner adds the card count from the
    /// state it is drawn in, while this is read back at recovery, where the
    /// number in it would describe a batch that has since moved on.
    static let feederEmptyIssueMessage =
        "The feeder was empty, so the last pass scanned nothing."

    private func feederEmptyNotice(
        endedPassKind: ScanPassKind?
    ) -> ScanDeckNotice {
        let count = session?.cards.filter { !$0.isDeleted }.count ?? 0
        let captured = "\(count) card\(count == 1 ? "" : "s") captured."
        // Read before `continueAutomaticallyIfAppropriate` turns it off, so
        // the copy can say what stopped rather than only that something did.
        let opening = isAutoContinueEnabled
            ? "Automatic scanning stopped — the feeder is empty."
            : "The feeder is empty, so nothing was scanned."
        return ScanDeckNotice(
            kind: .information,
            title: "Feeder is empty",
            message: "\(opening) \(captured)",
            action: retryAction(for: endedPassKind)
        )
    }

    /// Names the card a card-specific press will act on.
    ///
    /// The driver's failure wording says what went wrong and nothing about
    /// which row it happened to; at 186 cards that is the difference between a
    /// button and a guess.
    private func cardSentence(for action: ScanDeckNotice.Action?) -> String {
        guard let cardID = action?.cardID,
              let card = session?.cards.first(where: { $0.id == cardID })
        else {
            return ""
        }
        return " Card \(SheetNumber.formatted(card.provisionalSheetNumber)) "
            + "needs attention."
    }

    /// What one press should do about a failed pass: repeat the operation the
    /// pass was performing — except a failed append that left a card missing
    /// a side, where the incomplete card now blocks Continue Scanning and
    /// retrying that card is the only move the reducer will accept.
    private func retryAction(
        for endedPassKind: ScanPassKind?
    ) -> ScanDeckNotice.Action? {
        switch endedPassKind {
        case .append:
            if let blocker = session?.continuationBlockers.first {
                .retryCard(blocker.cardID)
            } else {
                .continueScanning
            }
        case let .retry(cardID):
            .retryCard(cardID)
        case let .replace(cardID):
            .replaceCard(cardID)
        case nil:
            nil
        }
    }

    func performNoticeAction() {
        guard let action = notice?.action else {
            return
        }
        // Whatever the press does, the card it does it to comes into view
        // first. A Retry that silently acts on a row a thousand points up the
        // list is the defect this ticket exists to close.
        if let cardID = action.cardID {
            reveal(cardID)
        }
        switch action {
        case .continueScanning:
            startOrContinueScan()
        case let .retryCard(cardID):
            retryCard(cardID)
        case let .replaceCard(cardID):
            replaceCard(cardID)
        case let .deleteCard(cardID):
            cardPendingDeletionConfirmation = cardID
        }
    }

    /// Brings the card the current notice is about into view and selects it.
    func revealNoticeCard() {
        guard let cardID = notice?.cardID else {
            return
        }
        reveal(cardID)
    }

    /// Offers to delete the card the current notice is about.
    ///
    /// Offered beside the retry on every card-specific blocker rather than
    /// instead of it: the operator may be able to rescan the card, and may
    /// equally have decided it is not worth another pass.
    ///
    /// Confirmed, where the three other routes to Delete Card are not — the row
    /// context menu, the inspector button, and `deleteSelectedCard` behind the
    /// ⌘-menu command. The asymmetry is deliberate rather than an oversight:
    /// those three act on a card the operator is looking at, while this one
    /// acts on a card that may be a hundred rows away and out of sight, which
    /// is the whole reason TICKET-032 exists. The confirmation names the
    /// number, so it is the only thing standing between an off-screen card and
    /// a press made in a hurry.
    func requestNoticeCardDeletion() {
        guard let cardID = notice?.cardID else {
            return
        }
        reveal(cardID)
        cardPendingDeletionConfirmation = cardID
    }

    private func reveal(_ cardID: CardID) {
        selectedCardID = cardID
        // Written even when it is already the same card, so a second press of
        // Show Card scrolls back to it after the operator has wandered off.
        cardRevealRequest = CardRevealRequest(cardID: cardID)
    }

    /// What Delete Card is about to throw away, named rather than described.
    ///
    /// The same discipline as Cancel Batch's confirmation (TICKET-028): "are
    /// you sure?" is not a question anyone can answer, and this one deletes
    /// two captured images.
    var deleteCardConfirmationMessage: String {
        guard let cardID = cardPendingDeletionConfirmation,
              let card = session?.cards.first(where: { $0.id == cardID })
        else {
            return "That card is no longer in this batch."
        }
        let sideCount = card.activeSides.map { sides in
            [sides.front, sides.back].compactMap(\.self).count
        } ?? 0
        let number = SheetNumber.formatted(card.provisionalSheetNumber)
        // A card whose sides have both been deleted individually still holds a
        // row and a number; promising to remove images it no longer has would
        // be a confirmation that misdescribes what it is confirming.
        let images = switch sideCount {
        case 0: "Card \(number) will be removed from this batch."
        case 1: "Card \(number) and its image will be removed from this batch."
        default: "Card \(number) and both its images will be removed from "
            + "this batch."
        }
        return images + " Sheet number \(number) is not reused — it stays an "
            + "intentional gap."
    }

    // MARK: - Accepting a blocking size disagreement (TICKET-037)

    /// The cards the reducer is currently refusing the batch over because their
    /// two sides disagree too widely.
    ///
    /// Projected, never decided: the presentation model asks the session which
    /// cards are blocking and on what grounds. It does not get to form its own
    /// opinion about which pairs are acceptable — that is the rule that keeps
    /// invariant #2's gate in one place.
    var blockingPairMismatchCardIDs: [CardID] {
        guard let session else {
            return []
        }
        let overridable = Self.overridableSizeBlockedCardIDs(
            among: session.completionBlockers
        )
        // Ordered by the batch rather than by the blocker list, so "Publish All"
        // walks the cards in the order the operator sees them.
        return session.cards
            .map(\.id)
            .filter(overridable.contains)
    }

    /// Cards whose *only* completion blocker is a wide size disagreement.
    ///
    /// The "only" is the load-bearing word. A card that is also missing a side,
    /// or whose front captured too little real background, stays blocked after
    /// its pair is accepted — so offering "Publish Anyway" on it would be a
    /// button that visibly does nothing, which is how an operator learns to
    /// distrust the whole control.
    private static func overridableSizeBlockedCardIDs(
        among blockers: [CompletionBlocker]
    ) -> Set<CardID> {
        var mismatched: Set<CardID> = []
        var otherwiseBlocked: Set<CardID> = []
        for blocker in blockers {
            switch blocker {
            case let .mismatchedPairMediaSize(cardID, _, _, _):
                mismatched.insert(cardID)
            case let .incomplete(cardID, _, _),
                 let .marginPending(cardID, _, _),
                 let .insufficientRealMargin(cardID, _, _, _):
                otherwiseBlocked.insert(cardID)
            case .noActiveCards:
                continue
            }
        }
        return mismatched.subtracting(otherwiseBlocked)
    }

    /// Whether the notice on screen is about a pair the operator could accept.
    var noticeAcceptablePairCardID: CardID? {
        guard let cardID = notice?.cardID,
              blockingPairMismatchCardIDs.contains(cardID)
        else {
            return nil
        }
        return cardID
    }

    /// Whether this card's disagreement has already been accepted, so the row
    /// can offer to take it back instead of offering it again.
    func hasAcceptedSizeDisagreement(_ cardID: CardID) -> Bool {
        session?.pairSizeWarnings.contains {
            $0.cardID == cardID && $0.isOperatorAccepted
        } ?? false
    }

    func requestSizeAcceptance(_ cardID: CardID) {
        guard blockingPairMismatchCardIDs.contains(cardID) else {
            return
        }
        selectedCardID = cardID
        cardPendingSizeAcceptanceConfirmation = cardID
    }

    var sizeAcceptanceConfirmationTitle: String {
        guard let cardID = cardPendingSizeAcceptanceConfirmation,
              let warning = blockingWarning(for: cardID)
        else {
            return "Publish this card anyway?"
        }
        return "Publish card "
            + "\(SheetNumber.formatted(warning.provisionalSheetNumber)) "
            + "anyway?"
    }

    /// The sentence the override is worth having. It states the two footprints,
    /// the millimetres they differ by, and the consequence in the operator's own
    /// terms — that one of the two crops is wrong and centering will measure it.
    var sizeAcceptanceConfirmationMessage: String {
        guard let cardID = cardPendingSizeAcceptanceConfirmation,
              let warning = blockingWarning(for: cardID)
        else {
            return "One of this card's two crops is wrong. It will be published "
                + "as it is."
        }
        let pixels = warning.disagreementPixels
        let millimetres = Double(pixels) / 600.0 * 25.4
        return "Its front measured \(warning.front.width) × "
            + "\(warning.front.height) px and its back "
            + "\(warning.back.width) × \(warning.back.height) px — "
            + String(format: "%.1f", millimetres)
            + " mm apart. One of those two crops is wrong, and ScanDeck cannot "
            + "tell which. Publishing it means a border that is not the real "
            + "one, which is what a centering check measures. Replace Card "
            + "re-feeds this card and usually lands both sides the same."
    }

    var sizeAcceptanceConfirmationActionTitle: String {
        "Publish Anyway"
    }

    /// Offered beside it when more than one card is blocking, because a batch
    /// with 26 blocked cards should not need 26 confirmations to say one thing.
    var otherBlockingPairMismatchCount: Int {
        guard let cardID = cardPendingSizeAcceptanceConfirmation else {
            return 0
        }
        return max(blockingPairMismatchCardIDs.count - 1, 0)
    }

    func confirmSizeAcceptance() {
        guard let cardID = cardPendingSizeAcceptanceConfirmation else {
            return
        }
        cardPendingSizeAcceptanceConfirmation = nil
        acceptSizeDisagreement(cardID)
    }

    /// Accepts every card the reducer is currently blocking for this reason.
    ///
    /// Each one is still a separate `acceptPairSizeMismatch` action recording
    /// its own two footprints, so "accept all" is a shortcut through the
    /// confirmation and never a different, weaker kind of consent.
    func confirmSizeAcceptanceForAllBlockedCards() {
        cardPendingSizeAcceptanceConfirmation = nil
        for cardID in blockingPairMismatchCardIDs {
            acceptSizeDisagreement(cardID)
        }
    }

    func cancelSizeAcceptance() {
        cardPendingSizeAcceptanceConfirmation = nil
    }

    /// Takes an acceptance back, so the gate returns.
    func withdrawSizeAcceptance(_ cardID: CardID) {
        dispatch(.withdrawPairSizeMismatchAcceptance(cardID: cardID))
        surfacePairMismatch()
    }

    private func acceptSizeDisagreement(_ cardID: CardID) {
        dispatch(.acceptPairSizeMismatch(cardID: cardID))
        // The notice was the refusal. Once the reducer stops refusing, leaving
        // it up would tell the operator the batch is still blocked by a card
        // they just cleared.
        if notice?.cardID == cardID {
            notice = nil
        }
        surfacePairMismatch()
    }

    private func blockingWarning(for cardID: CardID) -> PairSizeWarning? {
        guard let session else {
            return nil
        }
        for blocker in session.completionBlockers {
            guard case let .mismatchedPairMediaSize(
                blockedID,
                provisionalSheetNumber,
                front,
                back
            ) = blocker, blockedID == cardID else {
                continue
            }
            return PairSizeWarning(
                cardID: blockedID,
                provisionalSheetNumber: provisionalSheetNumber,
                front: front,
                back: back,
                isOperatorAccepted: false
            )
        }
        return nil
    }

    /// Deletes the card the confirmation is about.
    func confirmCardDeletion() {
        guard let cardID = cardPendingDeletionConfirmation else {
            return
        }
        cardPendingDeletionConfirmation = nil
        // The notice was about this card; leaving it up would offer a Retry
        // for a row that no longer exists.
        if notice?.cardID == cardID {
            notice = nil
        }
        deleteCard(cardID)
    }

    private func announceIncompleteCards() {
        guard let blocker = session?.continuationBlockers.first else {
            if notice?.title == "Incomplete card" {
                notice = nil
            }
            return
        }
        selectedCardID = blocker.cardID
        // A scan-failure notice already names what happened and carries the
        // same corrective action; the generic warning must not clobber the
        // jam the operator needs to read about.
        guard notice == nil || notice?.title == "Incomplete card" else {
            return
        }
        notice = ScanDeckNotice(
            kind: .warning,
            title: "Incomplete card",
            message: "Card \(SheetNumber.formatted(blocker.provisionalSheetNumber)) "
                + "is missing a side. Retry it or delete the card.",
            action: .retryCard(blocker.cardID)
        )
    }

    // MARK: Completion

    func completeBatch() {
        guard canCompleteBatch else {
            if let blocker = session?.completionBlockers.first {
                notice = ScanDeckNotice(
                    kind: .warning,
                    title: "Batch is not ready",
                    message: blocker.operatorMessage,
                    action: correctiveAction(for: blocker),
                    // Explicitly, not via the action: `marginPending` offers no
                    // press — there is nothing to do but wait — and it should
                    // still be able to show the operator which card it means.
                    cardID: blocker.cardID
                )
            } else if let completionBlockReason {
                notice = ScanDeckNotice(
                    kind: .warning,
                    title: "Batch is not ready",
                    message: completionBlockReason
                )
            }
            return
        }
        notice = nil
        dispatch(.requestCompletion(attemptID: ReleaseAttemptID(rawValue: UUID())))
    }

    /// The one press that fixes a completion blocker, offered on its notice.
    private func correctiveAction(
        for blocker: CompletionBlocker
    ) -> ScanDeckNotice.Action? {
        switch blocker {
        case .noActiveCards:
            .continueScanning
        case let .incomplete(cardID, _, _):
            .retryCard(cardID)
        case .marginPending:
            nil
        case let .insufficientRealMargin(cardID, _, _, _):
            .replaceCard(cardID)
        case let .mismatchedPairMediaSize(cardID, _, _, _):
            .replaceCard(cardID)
        }
    }

    /// A mismatched pair arises silently: both sides read sufficient on
    /// their own terms and only the reducer's cross-check knows better, so
    /// the moment the blocker appears is the only chance to say why Complete
    /// Batch stopped being available.
    private func surfacePairMismatch() {
        guard let session else {
            return
        }
        for blocker in session.completionBlockers {
            guard case let .mismatchedPairMediaSize(cardID, _, _, _) = blocker
            else {
                continue
            }
            guard notice == nil || notice?.title == "Card sizes disagree"
            else {
                return
            }
            selectedCardID = cardID
            notice = ScanDeckNotice(
                kind: .warning,
                title: "Card sizes disagree",
                message: blocker.operatorMessage,
                action: .replaceCard(cardID)
            )
            return
        }
        if notice?.title == "Card sizes disagree" {
            notice = nil
        }
    }

    func showCompletedBatchInFinder() {
        actions.showInFinder(completionSummary?.destinationURL)
    }

    var isCenteringCheckRunning: Bool {
        if case .running = centeringCheckStatus {
            return true
        }
        return false
    }

    func requestCompletedBatchCentering() {
        guard let summary = completionSummary,
              let url = summary.destinationURL,
              !isCenteringCheckRunning
        else {
            return
        }
        armCenteringConsent(folderURL: url, imageCount: summary.cardCount * 2)
    }

    /// The same egress, asked for a batch published earlier.
    ///
    /// The image count is counted off the folder rather than taken from the
    /// record's `cardCount * 2`. Months may have passed and `carduploader` runs
    /// against these folders, so the record says what ScanDeck produced and only
    /// the directory says what is there now — and the consent has to name the
    /// number of images that would actually be sent. The tool re-checks the same
    /// count and refuses if it moved between the press and the run.
    func requestCentering(for record: PublishedBatchRecord) {
        guard !isCenteringCheckRunning else {
            return
        }
        // An undeclared orientation is a hard stop, not a default. Guessing
        // `_F` on a legacy folder scores every front against back tolerances,
        // which are 5× looser, and reports ruinous cards as flawless.
        guard let artworkSide = record.artworkSide else {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "Say which side is the artwork",
                message: "\(record.batchName.value) was found on disk rather "
                    + "than published by ScanDeck, so it is not known whether "
                    + "_F holds the artwork or the card back. Front and back "
                    + "centering tolerances differ by five times, so choosing "
                    + "wrong would report bad cards as perfect. Open the batch "
                    + "and say which it is.",
                action: nil
            )
            return
        }
        guard let url = record.resolveDestinationURL() else {
            notice = ScanDeckNotice(
                kind: .error,
                title: "Folder not found",
                message: PublishedBatchStoreError
                    .unresolvableDestination(record.batchName.value)
                    .errorDescription ?? "",
                action: nil
            )
            return
        }
        let imageCount = Self.publishedImageCount(in: url)
        guard imageCount > 0 else {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "No images to check",
                message: "\(record.batchName.value)'s folder holds no "
                    + "front-and-back JPEGs any more, so there is nothing to "
                    + "send.",
                action: nil
            )
            return
        }
        centeringTargetBatchName = record.batchName.value
        armCenteringConsent(
            folderURL: url,
            imageCount: imageCount,
            swapSides: artworkSide.requiresSwappedSides
        )
    }

    private func armCenteringConsent(
        folderURL: URL,
        imageCount: Int,
        swapSides: Bool = false
    ) {
        pendingCenteringFolderURL = folderURL
        pendingCenteringSwapsSides = swapSides
        centeringCheckConsent = CenteringCheckConsent(imageCount: imageCount)
    }

    /// The consent message, naming the batch when it is not the one on screen.
    ///
    /// One alert now serves the completion screen and any previous batch, so it
    /// has to say *which* folder is about to be uploaded. "Send 430 images to
    /// centeringcheck.com?" with no name is exactly the ambiguity an egress
    /// confirmation cannot afford once more than one batch can be its target.
    var centeringCheckConsentMessage: String {
        guard let consent = centeringCheckConsent else {
            return ""
        }
        guard let name = centeringTargetBatchName else {
            return consent.message
        }
        return "This uploads \(name)'s published fronts and backs for "
            + "centering analysis and saves only the returned border overlays "
            + "under that batch's centering folder. Consent applies only to "
            + "this run and will not be remembered."
    }

    /// The published `_F`/`_B` JPEGs directly inside a batch folder.
    ///
    /// Deliberately shallow. `centering/` lives inside the batch folder and
    /// holds the returned overlays; a recursive count would include them and
    /// consent would name a number twice the truth on any second run.
    static func publishedImageCount(in folderURL: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: folderURL.path
        )) ?? []
        return names.count { name in
            let lowercased = name.lowercased()
            guard lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg")
            else {
                return false
            }
            let stem = lowercased
                .replacingOccurrences(of: ".jpeg", with: "")
                .replacingOccurrences(of: ".jpg", with: "")
            return stem.hasSuffix("_f") || stem.hasSuffix("_b")
        }
    }

    /// Whether a centering run has already written into this batch's folder, so
    /// the button can say "Check Centering Again" rather than implying nothing
    /// has happened. A re-run uploads nothing it has already measured.
    func hasCenteringResults(for record: PublishedBatchRecord) -> Bool {
        guard let url = record.resolveDestinationURL() else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: url.appending(path: "centering", directoryHint: .isDirectory)
                .path
        )
    }

    func cancelCenteringCheckConsent() {
        centeringCheckConsent = nil
        pendingCenteringFolderURL = nil
        pendingCenteringSwapsSides = false
        centeringTargetBatchName = nil
    }

    // MARK: - Published batch history

    /// Adds a just-published batch to the history.
    ///
    /// A failure here is reported and otherwise swallowed. The history is a
    /// convenience built on top of a batch that has already published and whose
    /// counter has already committed; a disk that cannot take 350 bytes must not
    /// be able to turn a successful publication into an error the operator reads
    /// as a failed one.
    private func recordPublishedBatch(
        candidate: CompletionCandidate,
        receipt: BatchPublishReceipt,
        releasedWithSizeWarnings: [UInt64],
        releasedWithAcceptedMismatches: [UInt64]
    ) {
        let numbers = candidate.cards.map(\.provisionalSheetNumber)
        let bookmark = try? receipt.publishedFolderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let record = PublishedBatchRecord(
            id: candidate.batchID,
            jobID: candidate.jobID,
            batchName: candidate.batchName,
            cardCount: candidate.cards.count,
            firstSheetNumber: numbers.min(),
            lastSheetNumber: numbers.max(),
            destinationDisplayName: receipt.destinationDescription,
            publishedAt: .now,
            destinationBookmark: bookmark,
            releasedWithSizeWarnings: releasedWithSizeWarnings,
            releasedWithAcceptedMismatches: releasedWithAcceptedMismatches,
            brightness: brightness
        )
        do {
            try publishedBatchStore.append(record)
            publishedBatches = publishedBatchStore.records()
        } catch {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "Batch history not saved",
                message: "\(candidate.batchName.value) published successfully, "
                    + "but ScanDeck could not add it to the batch list: "
                    + error.localizedDescription,
                action: nil
            )
        }
    }

    func showPublishedBatchInFinder(_ record: PublishedBatchRecord) {
        guard let url = record.resolveDestinationURL() else {
            notice = ScanDeckNotice(
                kind: .error,
                title: "Folder not found",
                message: PublishedBatchStoreError
                    .unresolvableDestination(record.batchName.value)
                    .errorDescription ?? "",
                action: nil
            )
            return
        }
        actions.showInFinder(url)
    }

    /// Removes a row from the list. The published folder is untouched — this
    /// forgets a batch, and the copy on the button says so, because a control
    /// next to a folder full of the operator's scans must not be ambiguous
    /// about which one it removes.
    func forgetPublishedBatch(_ record: PublishedBatchRecord) {
        do {
            try publishedBatchStore.forget(record.id)
            publishedBatches = publishedBatchStore.records()
            if sidebarSelection == .publishedBatch(record.id) {
                sidebarSelection = .profiles
            }
        } catch {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "Batch list not updated",
                message: error.localizedDescription,
                action: nil
            )
        }
    }

    func publishedBatch(_ batchID: BatchID) -> PublishedBatchRecord? {
        publishedBatches.first { $0.id == batchID }
    }

    /// Records the operator's answer about which suffix holds the artwork.
    func declareArtworkSide(
        _ side: ArtworkSide,
        for record: PublishedBatchRecord
    ) {
        do {
            try publishedBatchStore.append(record.declaring(side))
            publishedBatches = publishedBatchStore.records()
        } catch {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "Batch list not updated",
                message: error.localizedDescription,
                action: nil
            )
        }
    }

    /// Adds batch folders already sitting in the remembered destination.
    ///
    /// On demand rather than at launch, and deliberately so: the destination is
    /// a Google Drive folder and one of the operator's batches holds 840 files,
    /// so counting images in every subfolder is not something to do on every
    /// window open.
    ///
    /// Imported rows carry `artworkSide == nil`. Nothing about a folder says
    /// which suffix is the artwork, and getting it wrong is the one centering
    /// error that reports bad cards as good — so the row exists, and Check
    /// Centering stays shut until the operator says.
    func importExistingBatches() {
        guard let destination = destinationBookmarkStore.resolveDestination()
        else {
            notice = ScanDeckNotice(
                kind: .warning,
                title: "No destination remembered",
                message: "ScanDeck does not know where your batches are "
                    + "published yet. Start a batch and pick the destination "
                    + "folder once, then try again.",
                action: nil
            )
            return
        }

        let knownNames = Set(publishedBatches.map(\.batchName.value))
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var imported = 0
        for folder in candidates {
            let name = folder.lastPathComponent
            guard !knownNames.contains(name),
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?
                      .isDirectory == true
            else {
                continue
            }
            let imageCount = Self.publishedImageCount(in: folder)
            // A folder with no `_F`/`_B` pair is not a batch. `centering/` and
            // anything else the operator keeps beside their batches is skipped
            // rather than listed as an empty one.
            guard imageCount >= 2 else {
                continue
            }
            guard let batchName = try? BatchName(name) else {
                continue
            }
            let modified = (try? folder.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let bookmark = try? folder.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            do {
                try publishedBatchStore.append(
                    PublishedBatchRecord(
                        id: BatchID(rawValue: UUID()),
                        jobID: JobID(rawValue: profiles.first?.id ?? UUID()),
                        batchName: batchName,
                        cardCount: imageCount / 2,
                        firstSheetNumber: nil,
                        lastSheetNumber: nil,
                        destinationDisplayName: name,
                        publishedAt: modified,
                        destinationBookmark: bookmark,
                        isImported: true,
                        artworkSide: nil
                    )
                )
                imported += 1
            } catch {
                continue
            }
        }

        publishedBatches = publishedBatchStore.records()
        notice = ScanDeckNotice(
            kind: .information,
            title: imported == 0
                ? "No new batches found"
                : imported == 1
                ? "Added 1 batch"
                : "Added \(imported) batches",
            message: imported == 0
                ? "Every batch folder in \(destination.lastPathComponent) is "
                    + "already listed."
                : "Found in \(destination.lastPathComponent). Card counts come "
                    + "from the files on disk. Before checking centering on "
                    + "one, open it and say whether _F holds the artwork or "
                    + "the card back — ScanDeck cannot tell, and the two are "
                    + "graded five times apart.",
            action: nil
        )
    }

    /// This is the only route to the egress action. The short-lived consent
    /// value is consumed first, so a second run must always ask again.
    func confirmCompletedBatchCentering() {
        guard let consent = centeringCheckConsent,
              let publishedFolderURL = pendingCenteringFolderURL,
              !isCenteringCheckRunning
        else {
            cancelCenteringCheckConsent()
            return
        }
        centeringCheckConsent = nil
        pendingCenteringFolderURL = nil
        let request = CenteringCheckRequest(
            publishedFolderURL: publishedFolderURL,
            imageCount: consent.imageCount,
            swapSides: pendingCenteringSwapsSides
        )
        pendingCenteringSwapsSides = false
        let runID = UUID()
        centeringCheckRunID = runID
        let (progressStream, progressContinuation) =
            AsyncStream<CenteringCheckProgress>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        centeringCheckStatus = .running(
            .starting(imageCount: request.imageCount)
        )
        let progressReader = Task { [weak self] in
            for await step in progressStream {
                guard self?.centeringCheckRunID == runID else {
                    continue
                }
                self?.centeringCheckStatus = .running(step)
            }
        }

        Task { [weak self] in
            guard let self else {
                progressContinuation.finish()
                progressReader.cancel()
                return
            }
            do {
                let receipt = try await actions.checkCentering(request) { step in
                    progressContinuation.yield(step)
                }
                progressContinuation.finish()
                await progressReader.value
                guard centeringCheckRunID == runID else {
                    return
                }
                centeringCheckRunID = nil
                centeringCheckStatus = .completed(receipt)
            } catch {
                progressContinuation.finish()
                await progressReader.value
                guard centeringCheckRunID == runID else {
                    return
                }
                centeringCheckRunID = nil
                centeringCheckStatus = .failed(
                    message: "\(error.localizedDescription) Published images "
                        + "are unchanged, and cached results remain safe for "
                        + "Check Centering to resume."
                )
            }
        }
    }

    func showCenteringResultsInFinder() {
        guard case let .completed(receipt) = centeringCheckStatus else {
            return
        }
        actions.showInFinder(receipt.outputFolderURL)
    }

    private func publish(_ candidate: CompletionCandidate) {
        guard let destinationURL = batchContext?.destinationURL else {
            dispatch(
                .completionFailed(
                    attemptID: candidate.attemptID,
                    issue: BatchIssue(
                        kind: .releaseFailed,
                        message: "This batch has no destination folder."
                    )
                )
            )
            return
        }

        let request = BatchPublishRequest(
            candidate: candidate,
            destinationURL: destinationURL,
            masterURLs: masterURLs,
            dpi: batchContext?.profile.resolutionDPI ?? 600,
            brightness: brightness
        )

        // The counts arrive from whichever thread is cropping. Funnelling them
        // through one stream and reading it here is what keeps them in order:
        // hopping each callback onto the main actor separately would let 149
        // arrive after 150 and the number tick backwards.
        let (progressStream, progressContinuation) =
            AsyncStream<BatchPublishProgress>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        publishProgress = .writing(
            filesWritten: 0,
            fileCount: candidate.cards.count * 2
        )
        let progressReader = Task { [weak self] in
            for await step in progressStream {
                self?.publishProgress = step
            }
        }

        Task { [weak self] in
            guard let self else {
                progressContinuation.finish()
                return
            }
            defer {
                progressContinuation.finish()
                progressReader.cancel()
                publishProgress = nil
            }
            do {
                let receipt = try await actions.publish(request) { step in
                    progressContinuation.yield(step)
                }
                dispatch(
                    .completionSucceeded(
                        attemptID: candidate.attemptID,
                        destinationDescription: receipt.destinationDescription
                    )
                )
                if commitCounter(for: candidate) {
                    // Publication and the counter are both durable now, so the
                    // working files have nothing left to protect. Until both
                    // land, this record is the only evidence of which numbers
                    // the batch used.
                    await clearSavedSession()
                }
                // Read back from the reducer rather than recomputed here: the
                // warnings were captured at the moment the phase moved, and
                // by now the batch is completed and no longer projects them.
                var releasedWithSizeWarnings: [UInt64] = []
                var releasedWithAcceptedMismatches: [UInt64] = []
                if case let .completed(reduced) = session?.phase {
                    releasedWithSizeWarnings = reduced.releasedWithSizeWarnings
                    releasedWithAcceptedMismatches =
                        reduced.releasedWithAcceptedMismatches
                }
                centeringCheckStatus = nil
                centeringCheckConsent = nil
                centeringCheckRunID = nil
                completionSummary = BatchCompletionSummary(
                    batchName: candidate.batchName.value,
                    cardCount: candidate.cards.count,
                    counterRange: candidate.cards.map(\.provisionalSheetNumber)
                        .minAndMaxRange(),
                    destinationDisplayName: receipt.destinationDescription,
                    destinationURL: receipt.publishedFolderURL,
                    completedAt: .now,
                    releasedWithSizeWarnings: releasedWithSizeWarnings,
                    releasedWithAcceptedMismatches:
                        releasedWithAcceptedMismatches
                )
                // Recorded after the summary is built and deliberately last: a
                // history that fails to write must not be able to cost the
                // operator the completion screen for a batch that published.
                recordPublishedBatch(
                    candidate: candidate,
                    receipt: receipt,
                    releasedWithSizeWarnings: releasedWithSizeWarnings,
                    releasedWithAcceptedMismatches:
                        releasedWithAcceptedMismatches
                )
                sidebarSelection = .completedBatch
            } catch {
                dispatch(
                    .completionFailed(
                        attemptID: candidate.attemptID,
                        issue: BatchIssue(
                            kind: .releaseFailed,
                            message: error.localizedDescription
                        )
                    )
                )
                notice = ScanDeckNotice(
                    kind: .error,
                    title: "Batch could not be completed",
                    message: "\(error.localizedDescription) The batch folder was "
                        + "not created and every card is still here."
                )
            }
        }
    }

    /// Advances the persistent counter past everything this batch published.
    ///
    /// The batch folder already exists at this point, so a failure here is the
    /// one case where the operator must act: the next batch would otherwise
    /// reuse numbers this one already wrote. TICKET-006 closes the window with a
    /// durable release journal that finishes the commit during recovery.
    @discardableResult
    private func commitCounter(for candidate: CompletionCandidate) -> Bool {
        do {
            try jobCounterStore.commit(
                nextSheetNumber: candidate.nextPersistentCounter,
                for: candidate.jobID
            )
            return true
        } catch {
            notice = ScanDeckNotice(
                kind: .error,
                title: "The counter did not advance",
                message: "\(candidate.batchName.value) published successfully, "
                    + "but the sheet counter could not be saved. ScanDeck will "
                    + "finish saving it the next time it starts. If you scan "
                    + "again before then, set the next number to at least "
                    + "\(SheetNumber.formatted(candidate.nextPersistentCounter)) "
                    + "or the next batch will reuse these numbers. "
                    + "(\(error.localizedDescription))"
            )
            return false
        }
    }

    // MARK: Reducer plumbing

    /// Applies one action and returns its effects, or `nil` when the reducer
    /// rejected it. Rejection is surfaced rather than swallowed: it means the
    /// UI offered something the domain considers unsafe.
    @discardableResult
    private func dispatch(_ action: BatchAction) -> [BatchEffect]? {
        guard var candidate = session else {
            return nil
        }
        do {
            let effects = try BatchSessionReducer.reduce(action, into: &candidate)
            session = candidate
            // Autosave before running effects, not after. `prepareCompletion`
            // publishes, and `SPEC.md` section 5 requires the releasing session
            // to be durable before the destination is touched.
            saveSession()
            handle(effects)
            return effects
        } catch {
            notice = ScanDeckNotice(
                kind: .error,
                title: "That action was refused",
                message: error.localizedDescription
            )
            return nil
        }
    }

    /// Writes the batch to disk after anything that changed it.
    ///
    /// Invariant #1 is only as strong as how recently this ran, so it runs after
    /// every accepted action and every margin verdict rather than on a timer.
    /// The masters are already durable — they were written by the scanner — so
    /// what this protects is the reducer state that gives them meaning: which
    /// side of which card, at which number, with which rotation.
    ///
    /// A failure here is reported once and does not interrupt scanning. Losing
    /// recovery is bad; halting a pass that is physically feeding cards, and
    /// stranding the operator mid-stack, is worse.
    private func saveSession() {
        guard let session, let batchContext else {
            return
        }

        autosaver.save(
            PersistedBatchSession(
                session: session,
                masterURLs: masterURLs,
                startedAt: batchContext.startedAt,
                savedAt: .now,
                destinationBookmark: batchContext.destinationURL.flatMap {
                    try? DestinationBookmarkStore.bookmark(for: $0)
                }
            )
        )
    }

    /// Reports an autosave failure once rather than on every page.
    ///
    /// Scanning is not interrupted. Losing recovery is bad; halting a pass that
    /// is physically feeding cards, and stranding the operator mid-stack, is
    /// worse — and every captured image is already on disk either way.
    private func reportAutosaveFailure(_ error: any Error) {
        guard !hasReportedAutosaveFailure else {
            return
        }
        hasReportedAutosaveFailure = true
        notice = ScanDeckNotice(
            kind: .warning,
            title: "This batch is not being saved for recovery",
            message: "\(error.localizedDescription) Scanning still works and "
                + "every captured image is on disk, but this batch would not "
                + "come back if ScanDeck quit unexpectedly."
        )
    }

    /// Removes the recovery record once the batch is genuinely finished.
    ///
    /// Called only after publication *and* the counter commit have both
    /// succeeded, because until the counter is durable this record is the only
    /// evidence of which numbers the batch used. It goes through the autosaver
    /// so a queued save cannot resurrect what was just deleted.
    private func clearSavedSession() async {
        guard let session else {
            return
        }
        do {
            try await autosaver.discard(session.id)
        } catch {
            // The batch is published and the counter is committed, so nothing
            // is at risk; the leftover directory is tidied on a later run.
            notice = ScanDeckNotice(
                kind: .warning,
                title: "Recovery files were left behind",
                message: "\(session.batchName.value) published successfully, but "
                    + "its working files could not be removed: "
                    + "\(error.localizedDescription)"
            )
        }
    }

    /// Waits for every queued autosave to reach disk. Tests only — production
    /// deliberately never blocks on it.
    func flushPendingSaves() async {
        await autosaver.flush()
    }

    private func handle(_ effects: [BatchEffect]) {
        for effect in effects {
            switch effect {
            case let .assessMargin(masterID, rotation, requestedMargins):
                assessMargin(
                    masterID: masterID,
                    rotation: rotation,
                    margins: requestedMargins
                )

            case .mastersBecameUnreferenced:
                // Intentionally retained. `SPEC.md` section 5 keeps masters on
                // disk until publication and the counter commit are both
                // durable, so recovery can still reach them.
                break

            case let .prepareCompletion(candidate):
                publish(candidate)
            }
        }
    }

    /// Starts one analysis and does not wait for it.
    ///
    /// The scanning path, where sides arrive one at a time off the feeder and
    /// the arrival rate is the bound. Recovery has no such rate and supplies
    /// its own — see `reassessRecoveredMargins`.
    private func assessMargin(
        masterID: MasterID,
        rotation: QuarterTurns,
        margins: ScanMargins
    ) {
        Task { [weak self] in
            await self?.assessMargin(
                masterID: masterID,
                rotation: rotation,
                margins: margins
            )
        }
    }

    private func assessMargin(
        masterID: MasterID,
        rotation: QuarterTurns,
        margins: ScanMargins
    ) async {
        let request = MarginAssessmentRequest(
            masterID: masterID,
            imageURL: masterURLs[masterID],
            rotation: rotation,
            margins: margins,
            dpi: batchContext?.profile.resolutionDPI ?? 600
        )
        let outcome = await actions.assessMargin(request)
        // A stale result for a superseded rotation is refused by the
        // reducer; that is expected and must not raise an error banner.
        guard var candidate = session else {
            return
        }
        publishedCrops[masterID] = outcome.publishedCrop
        let effects = try? BatchSessionReducer.reduce(
            .marginAssessed(
                masterID: masterID,
                rotation: rotation,
                result: outcome.assessment
            ),
            into: &candidate
        )
        guard let effects else {
            return
        }
        session = candidate
        saveSession()
        handle(effects)
        surfacePairMismatch()
    }
}

private extension Array where Element == UInt64 {
    func minAndMaxRange() -> ClosedRange<UInt64>? {
        guard let minimum = self.min(), let maximum = self.max() else {
            return nil
        }
        return minimum...maximum
    }
}
