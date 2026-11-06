import AppKit
import ScanDeckCore
import SwiftUI

struct BatchWorkspaceView: View {
    @Bindable var model: ScanDeckPresentationModel

    private var batch: ActiveBatchViewData? {
        model.activeBatch
    }

    var body: some View {
        Group {
            if let batch {
                cardList(batch)
                    // Pinned rather than scrolled. The banner used to be the
                    // second child of the `LazyVStack`, which is fine at four
                    // cards and useless at 186: pressing Complete Batch at the
                    // foot of the window wrote a banner a thousand points above
                    // the viewport, and the operator — who had just been refused
                    // over 27 cards — saw nothing happen at all and read it as
                    // a hang (TICKET-030). The press that raises a notice is
                    // almost always made from the action bar, so the answer has
                    // to be somewhere the action bar can see.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        BatchBannerStack(model: model)
                    }
                    .safeAreaInset(edge: .bottom) {
                        BatchActionBar(model: model, batch: batch)
                    }
                    .navigationTitle(batch.name)
            } else {
                ContentUnavailableView(
                    "No Active Batch",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Choose a profile to start a new batch.")
                )
            }
        }
    }

    private func cardList(_ batch: ActiveBatchViewData) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                    LazyVStack(spacing: 18) {
                        BatchWorkspaceHeader(batch: batch)

                        if batch.phase == .scanning {
                            ScanningStatusView(
                                intent: model.activeScanKind,
                                selectedCard: model.selectedCard
                            )
                        }

                        if batch.cards.isEmpty, batch.phase != .scanning {
                            EmptyBatchView(
                                scannerReady: model.scannerConnection.isReady
                            ) {
                                model.startOrContinueScan()
                            }
                        } else {
                            ForEach(batch.cards) { card in
                                CardPairRow(
                                    card: card,
                                    isSelected: model.selectedCardID == card.id,
                                    isBlocked: batch.blockedCardIDs.contains(card.id),
                                    resolutionDPI: batch.profile.resolutionDPI,
                                    scanInProgress: batch.phase == .scanning,
                                    brightness: model.brightness,
                                    select: {
                                        model.selectedCardID = card.id
                                    },
                                    rotate: { side in
                                        model.rotate(cardID: card.id, side: side)
                                    },
                                    deleteSide: { side in
                                        model.deleteSide(cardID: card.id, side: side)
                                    },
                                    retry: {
                                        model.retryCard(card.id)
                                    },
                                    replace: {
                                        model.replaceCard(card.id)
                                    },
                                    deleteCard: {
                                        model.deleteCard(card.id)
                                    },
                                    acceptSizes: batch
                                        .overridableSizeBlockedCardIDs
                                        .contains(card.id)
                                        ? { model.requestSizeAcceptance(card.id) }
                                        : nil,
                                    withdrawAcceptance: card
                                        .acceptedSizeDisagreement
                                        ? { model.withdrawSizeAcceptance(card.id) }
                                        : nil
                                )
                            }
                        }
                    }
                    .frame(maxWidth: 1_050)
                    .padding(.horizontal, 30)
                    .padding(.top, 26)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity)
            }
            // A notice that names a card can now put it on screen. The row
            // identifiers were already there; nothing was ever asked to use
            // them, so the selection a blocker made landed somewhere off the
            // bottom of 186 rows and the card visible under the banner was an
            // unrelated one.
            .onChange(of: model.cardRevealRequest) { _, request in
                guard let request else {
                    return
                }
                withAnimation(.snappy) {
                    proxy.scrollTo(request.cardID, anchor: .center)
                }
            }
        }
    }
}

/// The banners, held above the card list rather than inside it.
///
/// Empty when there is nothing to say, so it costs no vertical space in the
/// ordinary case; `safeAreaInset` collapses to nothing for a zero-height view.
private struct BatchBannerStack: View {
    @Bindable var model: ScanDeckPresentationModel

    var body: some View {
        let notice = model.notice
        let scannerIsUnavailable = !model.scannerConnection.isReady

        if notice != nil || scannerIsUnavailable {
            VStack(spacing: 12) {
                if let notice {
                    let acceptableCardID = model.noticeAcceptablePairCardID
                    BatchNoticeBanner(
                        notice: notice,
                        performAction: { model.performNoticeAction() },
                        revealCard: { model.revealNoticeCard() },
                        requestDeletion: { model.requestNoticeCardDeletion() },
                        acceptSizes: acceptableCardID.map { cardID in
                            { model.requestSizeAcceptance(cardID) }
                        },
                        dismiss: { model.dismissNotice() }
                    )
                }

                if scannerIsUnavailable {
                    ScannerUnavailableBanner(connection: model.scannerConnection)
                }
            }
            .frame(maxWidth: 1_050)
            .padding(.horizontal, 30)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }
}

private struct BatchWorkspaceHeader: View {
    let batch: ActiveBatchViewData

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(batch.name)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    PhaseBadge(phase: batch.phase)
                }

                HStack(spacing: 16) {
                    Label(batch.profile.name, systemImage: "slider.horizontal.3")
                    Label("\(batch.profile.resolutionDPI) dpi", systemImage: "scope")
                    Label(batch.margins.summary, systemImage: "crop")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(batch.cards.count)")
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text(batch.cards.count == 1 ? "card" : "cards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PhaseBadge: View {
    let phase: ScanDeckWorkspacePhase

    private var title: String {
        switch phase {
        case .ready:
            "Ready"
        case .scanning:
            "Scanning"
        case .review:
            "Review"
        case .completing:
            "Publishing"
        case .completed:
            "Completed"
        }
    }

    private var color: Color {
        switch phase {
        case .ready:
            .secondary
        case .scanning:
            .accentColor
        case .review:
            .orange
        case .completing:
            .blue
        case .completed:
            .green
        }
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct BatchNoticeBanner: View {
    let notice: ScanDeckNotice
    let performAction: () -> Void
    let revealCard: () -> Void
    let requestDeletion: () -> Void
    /// Non-nil only while the reducer is refusing this notice's card over a
    /// wide size disagreement — the one blocker the operator may overrule
    /// (TICKET-037). It is a separate closure rather than a `notice.action`
    /// case because it is not the *corrective* step: Replace Card stays the
    /// primary button, because re-feeding the card usually fixes it outright.
    let acceptSizes: (() -> Void)?
    let dismiss: () -> Void

    private var color: Color {
        switch notice.kind {
        case .information:
            .accentColor
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    private var symbol: String {
        switch notice.kind {
        case .information:
            "info.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)

            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.headline)
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let action = notice.action {
                Button(action.title, action: performAction)
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .accessibilityHint("Runs the corrective step for this notice")
            }

            // Offered on every card-specific notice, beside the retry rather
            // than instead of it: some cards can be rescanned and some are
            // simply not worth another pass, and until now the banner could
            // only propose feeding more paper.
            if let acceptSizes {
                Button("Publish Anyway…", action: acceptSizes)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Accept these two sizes and let the batch complete")
                    .accessibilityHint(
                        "Publishes this card despite its two sides disagreeing"
                    )
            }

            if notice.cardID != nil {
                Button("Delete Card…", role: .destructive, action: requestDeletion)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityHint("Removes this card from the batch")

                Button("Show Card", systemImage: "scope", action: revealCard)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Scroll this card into view and select it")
                    .accessibilityLabel("Show the card this notice is about")
            }

            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("Dismiss \(notice.title)")
        }
        .padding(15)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(color.opacity(0.22))
        }
        .accessibilityElement(children: .contain)
    }
}

/// Why Scan is unavailable, on screen rather than in a tooltip.
///
/// The Scan button is genuinely disabled while the scanner is not usable —
/// unlike Complete Batch, pressing it could not accomplish anything — so the
/// reason has to live somewhere the operator is already looking. A hover
/// tooltip is where reasons go to hide (TICKET-023).
private struct ScannerUnavailableBanner: View {
    let connection: ScannerConnection

    private var color: Color {
        switch connection {
        case .searching, .inUseElsewhere, .severalScanners,
             .pinnedScannerMissing:
            .orange
        case .ready, .disconnected, .unsupported:
            .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "scanner.fill")
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.title)
                    .font(.headline)
                if let correctiveAction = connection.correctiveAction {
                    // No `fixedSize(vertical: true)` here, and it is
                    // load-bearing that none returns: inside the workspace's
                    // pinned top inset, macOS 26's split view probes the
                    // column at an unspecified width, and a vertically fixed
                    // multiline text answers that probe with its many-line
                    // height. The split view then adopts — and persists — a
                    // frame taller than the screen, which is how the whole
                    // window rendered clipped on every edge with Complete
                    // Batch unreachable below the bottom.
                    Text(correctiveAction)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(color.opacity(0.22))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(connection.title). \(connection.correctiveAction ?? "")"
        )
    }
}

private struct ScanningStatusView: View {
    let intent: ScanPassKind?
    let selectedCard: CardPairViewData?

    private var title: String {
        switch intent {
        case .append, .none:
            "Scanning feeder…"
        case .retry:
            "Retrying card \(selectedNumber)"
        case .replace:
            "Replacing card \(selectedNumber)"
        }
    }

    private var detail: String {
        switch intent {
        case .append, .none:
            "Front and back pages will appear together as each card clears the feeder."
        case .retry:
            "The incomplete row changes only after both replacement sides arrive."
        case .replace:
            "The original pair stays untouched until an exact two-page duplex scan succeeds."
        }
    }

    private var selectedNumber: String {
        guard let number = selectedCard?.sheetNumber else {
            return ""
        }
        return SheetNumber.formatted(number)
    }

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Image(systemName: "scanner.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(17)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor.opacity(0.22))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

private struct EmptyBatchView: View {
    let scannerReady: Bool
    let scan: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.accentColor.opacity(0.09))
                    .frame(width: 132, height: 112)
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(spacing: 7) {
                Text("Load cards, then scan")
                    .font(.title2.weight(.semibold))
                Text("Place card fronts facing the feeder direction. ScanDeck keeps every front and back together.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            Button(action: scan) {
                Label("Scan Feeder", systemImage: "scanner.fill")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!scannerReady)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityHint("Starts one duplex feeder pass")
        }
        .frame(maxWidth: .infinity, minHeight: 390)
        .padding(34)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [7, 7]))
                .foregroundStyle(Color.primary.opacity(0.15))
        }
    }
}

private struct CardPairRow: View {
    let card: CardPairViewData
    let isSelected: Bool
    /// Whether the reducer is refusing completion over this card — carried
    /// rather than derived, because the blocker that matters most here is the
    /// one no side of the row can show.
    let isBlocked: Bool
    let resolutionDPI: Int
    let scanInProgress: Bool
    let brightness: BrightnessAdjustment
    let select: () -> Void
    let rotate: (OutputSide) -> Void
    let deleteSide: (OutputSide) -> Void
    let retry: () -> Void
    let replace: () -> Void
    let deleteCard: () -> Void
    /// Non-nil when this row is the one refusing the batch over a wide size
    /// disagreement, so the override is reachable from the card itself and not
    /// only from a banner that may be scrolled a thousand points away.
    let acceptSizes: (() -> Void)?
    /// Non-nil once accepted, so the decision can be taken back from the same
    /// place it was made.
    let withdrawAcceptance: (() -> Void)?

    /// One badge per row, and it must be able to say the thing the row cannot
    /// otherwise show.
    ///
    /// A pair whose two sides measured different item sizes reads
    /// `.sufficient` on both of them, so every per-side affordance is happy
    /// and the row used to say "Ready" about a card the app knows one crop of
    /// is wrong. Icon, colour *and* text on each one, never colour alone.
    @ViewBuilder
    private var statusBadge: some View {
        if card.isIncomplete {
            Label("Incomplete", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if card.hasMarginIssue {
            Label("Check border", systemImage: "crop")
                .foregroundStyle(.orange)
        } else if isBlocked {
            Label("Blocked", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Blocked from completion")
        } else if let disagreement = card.sizeDisagreementPixels {
            let millimeters = (
                Double(disagreement) / Double(resolutionDPI) * 25.4
            ).formatted(.number.precision(.fractionLength(1)))
            // An accepted card is no longer `isBlocked`, so it arrives here —
            // and it must not borrow the sentence written for a pair that was
            // never refused. This one *was* refused, and the row is the only
            // lasting place that says a person overruled it (TICKET-037).
            if card.acceptedSizeDisagreement {
                Label(
                    "Published anyway — \(millimeters) mm",
                    systemImage: "exclamationmark.shield.fill"
                )
                .foregroundStyle(.orange)
                .help(
                    "This card's front and back measured item sizes "
                        + "\(disagreement) px apart, which is wide enough for "
                        + "ScanDeck to refuse the batch. You chose to publish "
                        + "it, so one of its two borders is not the real one."
                )
                .accessibilityLabel(
                    "Accepted despite sides differing by \(millimeters) "
                        + "millimetres"
                )
            } else {
                Label(
                    "Sides differ by \(millimeters) mm",
                    systemImage: "ruler"
                )
                .foregroundStyle(.yellow)
                .help(
                    "This card's front and back measured item sizes "
                        + "\(disagreement) px apart, so one side's crop is wrong. "
                        + "It is close enough to publish; replace the card if the "
                        + "border matters."
                )
            }
        } else {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(SheetNumber.formatted(card.sheetNumber))
                    .font(.system(.headline, design: .monospaced))
                    .textSelection(.enabled)

                statusBadge
                    .font(.caption.weight(.semibold))

                Spacer()

                if card.isIncomplete {
                    Button("Retry", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .disabled(scanInProgress)
                } else {
                    Button("Replace", systemImage: "arrow.triangle.2.circlepath", action: replace)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(scanInProgress)
                }

                if let acceptSizes {
                    Button("Publish Anyway…", action: acceptSizes)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(scanInProgress)
                        .help("Accept these two sizes and let the batch complete")
                } else if let withdrawAcceptance {
                    Button("Block Again", action: withdrawAcceptance)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(scanInProgress)
                        .help("Refuse this card again until it is replaced")
                }
            }
            .frame(width: 105, alignment: .leading)

            HStack(spacing: 14) {
                ScanSideCard(
                    cardNumber: card.sheetNumber,
                    side: .front,
                    scan: card.front,
                    disabled: scanInProgress,
                    brightness: brightness,
                    rotate: { rotate(.front) },
                    delete: { deleteSide(.front) }
                )
                ScanSideCard(
                    cardNumber: card.sheetNumber,
                    side: .back,
                    scan: card.back,
                    disabled: scanInProgress,
                    brightness: brightness,
                    rotate: { rotate(.back) },
                    delete: { deleteSide(.back) }
                )
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            card.isIncomplete ? Color.orange.opacity(0.055) : Color.clear,
            in: RoundedRectangle(cornerRadius: 20)
        )
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    isSelected
                        ? Color.accentColor
                        : card.isIncomplete
                            ? Color.orange.opacity(0.45)
                            : Color.primary.opacity(0.085),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .shadow(color: .black.opacity(0.045), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture(perform: select)
        .contextMenu {
            if card.isIncomplete {
                Button("Retry Card", systemImage: "arrow.clockwise", action: retry)
            } else {
                Button("Replace Card…", systemImage: "arrow.triangle.2.circlepath", action: replace)
            }
            Divider()
            Button("Rotate Front", systemImage: "rotate.right") {
                rotate(.front)
            }
            .disabled(card.front == nil)
            Button("Rotate Back", systemImage: "rotate.right") {
                rotate(.back)
            }
            .disabled(card.back == nil)
            Divider()
            Button("Delete Card", systemImage: "trash", role: .destructive, action: deleteCard)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Card \(SheetNumber.formatted(card.sheetNumber)), "
                + (card.isIncomplete ? "incomplete" : "front and back ready")
        )
    }
}

private struct ScanSideCard: View {
    let cardNumber: UInt64
    let side: OutputSide
    let scan: ScanSideViewData?
    let disabled: Bool
    let brightness: BrightnessAdjustment
    let rotate: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(side.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let scan {
                    MarginStatusBadge(state: scan.marginAssessment)
                } else {
                    Label("Missing", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black)

                if let scan {
                    ScanImageContent(
                        scan: scan,
                        side: side,
                        brightness: brightness
                    )
                    .padding(13)
                } else {
                    MissingSideContent(side: side)
                }

                if scan != nil, isHovering {
                    GlassEffectContainer(spacing: 7) {
                        HStack(spacing: 7) {
                            Button(action: rotate) {
                                Label("Rotate \(side.title)", systemImage: "rotate.right")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .help("Rotate \(side.title) Clockwise")

                            Button(role: .destructive, action: delete) {
                                Label("Delete \(side.title)", systemImage: "trash")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .help("Delete \(side.title)")
                        }
                    }
                    .padding(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .aspectRatio(previewAspectRatio, contentMode: .fit)
            .animation(.snappy, value: scan?.rotation)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { hovering in
                withAnimation(.snappy(duration: 0.18)) {
                    isHovering = hovering
                }
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(disabled ? 0.72 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Card \(SheetNumber.formatted(cardNumber)) \(side.title)"
        )
        .accessibilityValue(
            scan == nil
                ? "Missing"
                : "Captured, rotated \(Int(scan?.rotation.degrees ?? 0)) degrees"
        )
        .accessibilityHint(scan == nil ? "Retry the card to replace both sides" : "Hover for image actions")
    }

    /// The tile takes the published crop's own shape instead of imposing one.
    ///
    /// Review must show the file being published and nothing else. A fixed
    /// landscape tile around a portrait crop pads it with black fill that is
    /// indistinguishable from captured background — the operator read it as
    /// empty space in the output on the first real batch. Until analysis
    /// lands, the scan frame's own portrait shape (~3232 × 4248 on the
    /// fi-8170) is the honest placeholder; a quarter-turned side swaps axes.
    private var previewAspectRatio: CGFloat {
        let scanFrameShape: CGFloat = 0.76
        guard let scan else {
            return scanFrameShape
        }
        var ratio = scanFrameShape
        if let crop = scan.publishedCrop,
           crop.bounds.width > 0, crop.bounds.height > 0
        {
            ratio = CGFloat(crop.bounds.width) / CGFloat(crop.bounds.height)
        }
        return scan.rotation.swapsDisplayAxes ? 1 / ratio : ratio
    }
}

/// Re-decodes only when the master or its crop changes, so the preview swaps to
/// the true published framing the moment analysis finishes.
private struct PreviewRequest: Equatable {
    let url: URL?
    let crop: PublishedCrop?
    let brightness: BrightnessAdjustment
}

private struct ScanImageContent: View {
    let scan: ScanSideViewData
    let side: OutputSide
    let brightness: BrightnessAdjustment

    @State private var preview: CGImage?

    var body: some View {
        // Laid out at the pre-rotation size, then turned: a quarter-turned
        // side must still fill the tile, so the fitting box is the tile's
        // frame with its axes swapped back.
        GeometryReader { proxy in
            let swapsAxes = scan.rotation.swapsDisplayAxes
            Group {
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    DemoCardFace(side: side)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
            .frame(
                width: swapsAxes ? proxy.size.height : proxy.size.width,
                height: swapsAxes ? proxy.size.width : proxy.size.height
            )
            .rotationEffect(.degrees(scan.rotation.degrees))
            .animation(.snappy, value: scan.rotation)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Never bind the full-resolution master here — `SPEC.md` section 6.3.
        // The store decodes a bounded preview off the main thread and caches it.
        //
        // Cropped to the published bounds, so the grid shows the file that will
        // be written rather than the whole scan frame. Until analysis lands the
        // preview is the uncropped master, which is honest: nothing yet knows
        // where the card is.
        //
        // Keyed on the tone curve as well, so dragging the brightness slider
        // re-renders the grid rather than leaving the operator looking at the
        // previous setting while the file that would be written has moved on.
        .task(
            id: PreviewRequest(
                url: scan.imageURL,
                crop: scan.publishedCrop,
                brightness: brightness
            )
        ) {
            guard let url = scan.imageURL else {
                preview = nil
                return
            }
            preview = await ThumbnailStore.shared.thumbnail(
                for: url,
                croppedTo: scan.publishedCrop,
                brightness: brightness
            )
        }
    }
}

private struct DemoCardFace: View {
    let side: OutputSide

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: side == .front
                            ? [
                                Color.accentColor.opacity(0.9),
                                Color.accentColor.opacity(0.38),
                            ]
                            : [
                                Color.secondary.opacity(0.75),
                                Color.secondary.opacity(0.28),
                            ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 9) {
                Image(systemName: side == .front ? "sparkles.rectangle.stack" : "text.alignleft")
                    .font(.system(size: 34, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(side == .front ? "CARD FRONT" : "CARD BACK")
                    .font(.caption2.weight(.bold))
                    .tracking(1.6)
            }
            .foregroundStyle(.white.opacity(0.92))
        }
    }
}

private struct MissingSideContent: View {
    let side: OutputSide

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 32, weight: .light))
            Text("\(side.title) missing")
                .font(.callout.weight(.medium))
            Text("Retry scans both sides")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white.opacity(0.78))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MarginStatusBadge: View {
    let state: MarginAssessment

    var body: some View {
        switch state {
        case .sufficient:
            Label("Border ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption2.weight(.semibold))
        case .pending:
            Label("Checking", systemImage: "hourglass")
                .foregroundStyle(.secondary)
                .font(.caption2.weight(.semibold))
        case let .insufficient(edges):
            Label(
                edges.map(\.title).sorted().joined(separator: ", "),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            .font(.caption2.weight(.semibold))
        }
    }
}

/// Brightness: one slider for the whole batch, previewed before it is spent.
///
/// One control, not one per card. At 186 rows a per-card adjustment is not a
/// feature, it is 186 decisions — and the reason to reach for this at all is
/// that a whole stack scanned dark, which is a property of the pass rather than
/// of any card in it.
///
/// The value is stepped rather than continuous. A drag is doing real work per
/// tick — every visible preview re-decodes — so the step is what keeps a slow
/// sweep from queueing hundreds of decodes it will immediately discard, and 5%
/// is finer than the eye can separate on a card face anyway.
private struct BrightnessControl: View {
    @Bindable var model: ScanDeckPresentationModel

    private var amount: Binding<Double> {
        Binding(
            get: { model.brightness.amount },
            set: { model.brightness = BrightnessAdjustment(amount: $0) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.max")
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityHidden(true)

            Slider(
                value: amount,
                in: BrightnessAdjustment.range,
                step: 0.05
            )
            .frame(width: 96)
            .controlSize(.mini)
            .accessibilityLabel("Brightness")
            .accessibilityValue(model.brightness.operatorDescription)

            // The number is not decoration. The curve is baked into the
            // published file, so the operator needs to be able to say what a
            // batch was published at — and to put it back to None exactly,
            // which a slider alone cannot promise.
            Button {
                model.brightness = .identity
            } label: {
                Text(model.brightness.operatorDescription)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(
                        model.brightness.isIdentity ? .tertiary : .secondary
                    )
                    .frame(width: 38, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(model.brightness.isIdentity)
            .help(
                model.brightness.isIdentity
                    ? "Published cards are unadjusted."
                    : "Reset brightness to None."
            )
        }
        .help(
            "Lifts the tone of every card in this batch. The preview shows "
                + "exactly what will be published; the masters are never "
                + "changed, so this can be adjusted until you complete the "
                + "batch."
        )
    }
}

/// The automatic-continue control: a switch, an interval, and a countdown.
///
/// It presses Continue Scanning so a manual feeder does not have to. Every pass
/// it starts is an ordinary one — same gates, same reducer — so the countdown
/// is the whole of the feature, and the Stop beside it is what makes handing
/// the button over reversible.
private struct AutoContinueControl: View {
    @Bindable var model: ScanDeckPresentationModel

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $model.isAutoContinueEnabled) {
                Text("Auto")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(
                "Starts the next pass by itself after each successful one, so "
                    + "you can keep feeding without pressing Continue Scanning."
            )
            .accessibilityLabel("Scan automatically")

            if let countdown = model.autoContinueCountdown {
                Button {
                    model.isAutoContinueEnabled = false
                } label: {
                    Label("Stop · \(countdown)s", systemImage: "stop.fill")
                        .monospacedDigit()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .accessibilityLabel("Stop automatic scanning, \(countdown) seconds left")
            } else {
                HStack(spacing: 3) {
                    TextField(
                        "Seconds",
                        value: $model.autoContinueSeconds,
                        format: .number
                    )
                    .frame(width: 34)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .accessibilityLabel("Seconds between passes")
                    Text("s")
                        .foregroundStyle(.tertiary)
                    Stepper(
                        "Seconds between passes",
                        value: $model.autoContinueSeconds,
                        in: ScanDeckSettings.autoContinueSecondsRange
                    )
                    .labelsHidden()
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(.quaternary, in: Capsule())
    }
}

private struct BatchActionBar: View {
    @Bindable var model: ScanDeckPresentationModel
    let batch: ActiveBatchViewData

    private var statusText: String {
        if batch.phase == .scanning {
            return "Scanning feeder…"
        }
        if batch.phase == .completing {
            // A bare "Validating and publishing…" is what the operator was
            // watching when they mistook a refused press for a hang. The
            // publisher reports counts now, so show them.
            return model.publishProgress?.operatorDescription
                ?? "Validating and publishing…"
        }
        if !batch.incompleteCards.isEmpty {
            let count = batch.incompleteCards.count
            return "\(count) incomplete \(count == 1 ? "card" : "cards") blocks scanning"
        }
        if !batch.cardsWithMarginIssues.isEmpty {
            return "Resolve border warnings before completion"
        }
        if batch.cards.isEmpty {
            return "Ready for the first feeder pass"
        }
        // Anything the reducer is refusing, whether or not a row can show it.
        // A mismatched pair reads `.sufficient` on both sides, so the two
        // checks above are blind to it — and on `carlsoboxone` this line said
        // "186 cards ready" while 27 were blocked.
        // A pair the reducer only warns about no longer holds the batch, so
        // this line is the last summary before Complete Batch. Saying "186
        // cards ready" over two knowingly-wrong crops is the same silence
        // TICKET-030 was about, one threshold along — so the count is appended
        // whether or not something else is already refusing the batch.
        // An accepted card is counted apart from a merely warned one. Folding
        // the two together would let "3 with sides that differ" stand for three
        // cards the app flagged *or* three refusals a person overruled, and
        // those are not the same batch (TICKET-037).
        let accepted = batch.cardsPublishedAnyway.count
        let warned = batch.cardsWithSizeDisagreement.count - accepted
        var warning = warned > 0 ? " · \(warned) with sides that differ" : ""
        if accepted > 0 {
            warning += " · \(accepted) published anyway"
        }
        if !batch.blockedCardIDs.isEmpty {
            let count = batch.blockedCardIDs.count
            return "\(count) \(count == 1 ? "card" : "cards") "
                + "\(count == 1 ? "blocks" : "block") completion"
                + warning
        }
        return "\(batch.completedCardCount) "
            + "\(batch.completedCardCount == 1 ? "card" : "cards") ready"
            + warning
    }

    var body: some View {
        HStack(spacing: 16) {
            if batch.phase == .scanning || batch.phase == .completing {
                ProgressView()
                    .controlSize(.small)
            } else {
                // Anything the reducer refuses, not just what a row can show.
                // A green tick beside "26 cards block completion" is the same
                // lie the text used to tell on its own, and the icon is what
                // gets read first.
                let isRefused = !batch.incompleteCards.isEmpty
                    || !batch.blockedCardIDs.isEmpty
                let isWarned = !batch.cardsWithSizeDisagreement.isEmpty
                Image(
                    systemName: isRefused
                        ? "exclamationmark.triangle.fill"
                        : isWarned
                        ? "exclamationmark.circle.fill"
                        : "checkmark.circle.fill"
                )
                .foregroundStyle(
                    isRefused ? .orange : isWarned ? .yellow : .green
                )
            }

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            // The brightness control yields first when the bar runs out of
            // room. The bar's fixed controls set the detail column's minimum
            // width, and on macOS 26 a split view that cannot seat its
            // columns lays out wider than the window instead of compressing
            // — with the open inspector that pushed Complete Batch off the
            // window's right edge. Scan and Complete must never be the
            // controls that give way, and the slider stays reachable by
            // closing the inspector or widening the window.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    // Hidden until there is something to look at: a slider
                    // over an empty grid adjusts nothing and previews
                    // nothing.
                    if !batch.cards.isEmpty {
                        BrightnessControl(model: model)
                        Divider().frame(height: 22)
                    }
                    trailingControls
                }
                trailingControls
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 16) {
            AutoContinueControl(model: model)

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        model.startOrContinueScan()
                    } label: {
                        Label(model.scanButtonTitle, systemImage: "scanner.fill")
                    }
                    .buttonStyle(.glass)
                    .disabled(!model.canStartScan)
                    .keyboardShortcut("r", modifiers: .command)
                    .help(
                        batch.incompleteCards.isEmpty
                            ? "Start another duplex feeder pass"
                            : "Retry or delete incomplete cards first"
                    )

                    Button {
                        model.completeBatch()
                    } label: {
                        Label("Complete Batch", systemImage: "checkmark")
                    }
                    .buttonStyle(.glassProminent)
                    // Pressable while blocked: a disabled button cannot say
                    // why, and a hover tooltip is where reasons go to hide.
                    // The press surfaces the first blocker as a notice with
                    // its corrective action; the reducer still refuses the
                    // completion itself.
                    .disabled(
                        batch.phase == .scanning || batch.phase == .completing
                    )
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help(model.completionBlockReason ?? "Publish the final batch folder")
                }
            }
        }
    }
}
