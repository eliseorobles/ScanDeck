import Foundation
import Testing
@testable import ScanDeckCore

@Suite("Published brightness")
struct BrightnessAdjustmentTests {
    @Test("The identity maps every channel value to itself")
    func identityIsIdentity() {
        let table = BrightnessAdjustment.identity.lookupTable()
        #expect(table.count == 256)
        for value in 0...255 {
            #expect(table[value] == UInt8(value))
        }
        #expect(BrightnessAdjustment.identity.isIdentity)
    }

    /// The property the whole curve was chosen for. A card front is white
    /// border and foil already sitting near the ceiling, and centeringcheck.com
    /// measures the border-to-card transition on the *published* file — so a
    /// curve that can saturate would erode the edge the grader needs, on the
    /// side whose tolerance is five times tighter.
    @Test(
        "Black and white are fixed points at every setting, so nothing clips",
        arguments: [-1.0, -0.75, -0.3, -0.05, 0.05, 0.4, 0.85, 1.0]
    )
    func endpointsAreFixed(amount: Double) {
        let table = BrightnessAdjustment(amount: amount).lookupTable()
        #expect(table[0] == 0)
        #expect(table[255] == 255)
    }

    @Test(
        "The curve is monotonic, so no two tones are ever swapped or flattened",
        arguments: [-1.0, -0.5, 0.5, 1.0]
    )
    func curveIsMonotonic(amount: Double) {
        let table = BrightnessAdjustment(amount: amount).lookupTable()
        for value in 1...255 {
            #expect(table[value] >= table[value - 1])
        }
    }

    @Test("A positive amount lifts midtones and a negative one lowers them")
    func directionFollowsSign() {
        let brighter = BrightnessAdjustment(amount: 0.5).lookupTable()
        let darker = BrightnessAdjustment(amount: -0.5).lookupTable()

        #expect(brighter[128] > 128)
        #expect(darker[128] < 128)
        // Monotonic in the setting too, not merely in the right direction.
        let brightest = BrightnessAdjustment(amount: 1.0).lookupTable()
        #expect(brightest[128] > brighter[128])
    }

    @Test("An out-of-range or non-finite amount clamps rather than failing")
    func clampsUnusableAmounts() {
        #expect(BrightnessAdjustment(amount: 4).amount == 1)
        #expect(BrightnessAdjustment(amount: -9).amount == -1)
        #expect(BrightnessAdjustment(amount: .nan).isIdentity)
        #expect(BrightnessAdjustment(amount: .infinity).amount == 1)
    }

    @Test("Encodes as a bare number so a record stays readable")
    func encodesAsNumber() throws {
        let encoded = try JSONEncoder().encode(
            BrightnessAdjustment(amount: 0.35)
        )
        #expect(String(decoding: encoded, as: UTF8.self) == "0.35")

        let decoded = try JSONDecoder().decode(
            BrightnessAdjustment.self,
            from: encoded
        )
        #expect(decoded == BrightnessAdjustment(amount: 0.35))
    }

    @Test("A stored value beyond the range decodes as the clamped setting")
    func decodeClamps() throws {
        let decoded = try JSONDecoder().decode(
            BrightnessAdjustment.self,
            from: Data("7.5".utf8)
        )
        #expect(decoded.amount == 1)
    }

    @Test("Reads to the operator as a signed percentage")
    func describesItself() {
        #expect(BrightnessAdjustment.identity.operatorDescription == "None")
        #expect(
            BrightnessAdjustment(amount: 0.35).operatorDescription == "+35%"
        )
        #expect(
            BrightnessAdjustment(amount: -0.2).operatorDescription == "-20%"
        )
    }

    /// A settings file written before the field existed must still open, or the
    /// operator loses every other preference in it.
    @Test("Settings written before brightness existed decode as unadjusted")
    func settingsWithoutBrightnessDecode() throws {
        let legacy = Data(#"{"autoContinueSeconds":9}"#.utf8)
        let settings = try JSONDecoder().decode(
            ScanDeckSettings.self,
            from: legacy
        )
        #expect(settings.autoContinueSeconds == 9)
        #expect(settings.brightness.isIdentity)
    }

    /// The identity is the *correct* reading for an older record, unlike
    /// `artworkSide` — nothing could have adjusted those batches.
    @Test("A history record written before brightness existed reads unadjusted")
    func recordWithoutBrightnessDecodes() throws {
        let legacy = Data(
            """
            {
              "id": { "rawValue": "8CFB5A35-D7AE-4004-86EB-528A58E66100" },
              "jobID": { "rawValue": "A577C440-0374-4D99-82D5-6296519E16F2" },
              "batchName": { "value": "batch-12" },
              "cardCount": 60,
              "destinationDisplayName": "Scans / batch-12",
              "publishedAt": 776000000,
              "isImported": false,
              "artworkSide": "frontSuffix"
            }
            """.utf8
        )
        let record = try JSONDecoder().decode(
            PublishedBatchRecord.self,
            from: legacy
        )
        #expect(record.batchName.value == "batch-12")
        #expect(record.brightness.isIdentity)
    }
}
