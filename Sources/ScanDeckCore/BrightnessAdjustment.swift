import Foundation

/// How much to lift or lower the tone of a published card, as a curve rather
/// than an offset.
///
/// This is a *render* parameter, not a capture one, and that distinction is the
/// whole design. The fi-8170 cannot do it — checked on the device 2026-08-06,
/// where all sixteen of the feeder's vendor features are enumerations and the
/// only tone control PFU publishes is `tone_adjustment` with five fixed steps,
/// applied before the pixels exist and impossible to preview or undo.
/// `ImageCaptureCore` itself has no brightness, contrast, or gamma property at
/// all. So the adjustment happens here, over a master ScanDeck keeps, which is
/// what lets the operator move a slider and see the answer before committing to
/// it.
///
/// **The curve never clips.** It is a gamma applied to the normalised channel
/// value, so nothing is added and nothing saturates: pure black and pure white
/// are fixed points, and every value between them moves monotonically. That
/// matters more than it looks. Card stock on a black background is midtones
/// under bright white borders and foil already sitting near the ceiling, and a
/// linear offset would flatten exactly the border-to-card transition that
/// centeringcheck.com measures — on the front, where the tolerance is five
/// times tighter than the back. A curve that cannot reach the ceiling cannot
/// crush that edge.
///
/// The adjustment is deliberately *not* part of the batch session record.
/// Nothing about it needs to survive a crash — the masters are untouched and
/// the value is re-appliable from scratch — and putting it in the session would
/// have meant migrating a schema while a real 33-card batch was sitting
/// unpublished in it.
public struct BrightnessAdjustment: Codable, Equatable, Hashable, Sendable {
    /// The full travel of the control. Negative darkens, positive brightens.
    public static let range = -1.0...1.0

    /// Publishes exactly what ScanDeck published before this type existed.
    public static let identity = BrightnessAdjustment(amount: 0)

    /// The gamma at full travel.
    ///
    /// At `amount == 1` a mid-grey moves from 0.50 to 0.69, which is a large
    /// but not absurd lift — the top of a slider should be past where anyone
    /// wants to live, or the useful range is compressed into the last third of
    /// the track.
    private static let gammaAtFullTravel = 3.0

    /// Clamped on the way in, so a value from a settings file written by a
    /// future version, or one an out-of-range slider produced, is a usable
    /// setting rather than a crash or a black card.
    public let amount: Double

    public init(amount: Double) {
        // NaN alone is special-cased: it compares false against everything, so
        // `min`/`max` would carry it straight through the clamp and into `pow`,
        // and a NaN lookup table is a black card. An infinity clamps correctly
        // on its own and means what the ends of the slider mean.
        guard !amount.isNaN else {
            self.amount = 0
            return
        }
        self.amount = min(
            Self.range.upperBound,
            max(Self.range.lowerBound, amount)
        )
    }

    /// True when the curve is the identity function.
    ///
    /// Every consumer checks this and skips its work entirely rather than
    /// running a table that happens to map each value to itself. Two reasons,
    /// and the second is the load-bearing one: publication runs the curve 800
    /// times on a real batch and an unnecessary bitmap pass is a cost
    /// TICKET-035 already fought for, and a batch published with the control at
    /// rest must be *byte-identical* to what this app produced before the
    /// control existed. Anything less would mean every past batch was
    /// reproducible only by luck.
    public var isIdentity: Bool {
        amount == 0
    }

    /// The 256-entry channel mapping this adjustment applies.
    ///
    /// Precomputed rather than evaluated per pixel: a 600 dpi side is about
    /// 8.7 million pixels and 26 million channel values, so calling `pow` per
    /// channel would cost more than the rest of publication put together.
    public func lookupTable() -> [UInt8] {
        guard !isIdentity else {
            return Self.identityTable
        }
        let exponent = 1.0 / pow(Self.gammaAtFullTravel, amount)
        return (0...255).map { value in
            let normalized = Double(value) / 255.0
            let adjusted = pow(normalized, exponent) * 255.0
            // The curve's own endpoints are exact, but `pow` is not, so a
            // value is still rounded and pinned rather than trusted to land
            // inside the byte range on its own.
            return UInt8(min(255, max(0, adjusted.rounded())))
        }
    }

    private static let identityTable: [UInt8] = (0...255).map { UInt8($0) }

    /// How the setting reads to the operator, and how it is recorded.
    public var operatorDescription: String {
        guard !isIdentity else {
            return "None"
        }
        let percent = Int((amount * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }

    /// Encoded as a bare number, so a history record reads `"brightness": 0.35`
    /// rather than carrying a wrapper object for one field.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(amount: try container.decode(Double.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(amount)
    }
}
