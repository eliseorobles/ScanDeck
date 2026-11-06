import Foundation

/// Operator preferences that are not part of a job or a batch.
///
/// Everything a *job* owns — margins, naming, resolution, counter — belongs to
/// the job (`SPEC.md` section 3), and the destination and counter already have
/// stores of their own. What is left is the small set of choices about this
/// installation rather than about the work, which is what lives here.
public struct ScanDeckSettings: Codable, Equatable, Sendable {
    /// Which scanner a pass should take, by name.
    ///
    /// `nil` means "whichever supported scanner is attached", which stays the
    /// default deliberately: pinning a name the operator never chose would fail
    /// for every supported device that is not the one it was pinned to, and a
    /// device that cannot do duplex, 600 dpi, and the PFU cropping features
    /// fails loudly while being configured rather than scanning something
    /// subtly wrong. The pin exists for the one case the probe genuinely cannot
    /// resolve: two supported scanners attached at once.
    public var preferredScannerName: String?

    /// Seconds to wait before starting the next pass by itself, when the
    /// operator has turned that on. Persisted because it is a property of how
    /// this person feeds a scanner, not of one batch.
    public var autoContinueSeconds: Int

    /// The tone curve baked into published cards.
    ///
    /// An installation preference rather than a job or batch property, because
    /// it describes this scanner under this lamp on this operator's desk — the
    /// same reason `autoContinueSeconds` lives here. It is read at publication
    /// and applied to previews throughout review, so the operator sets it once
    /// and every later batch inherits it.
    public var brightness: BrightnessAdjustment

    public static let autoContinueSecondsRange = 1...60

    public init(
        preferredScannerName: String? = nil,
        autoContinueSeconds: Int = 5,
        brightness: BrightnessAdjustment = .identity
    ) {
        self.preferredScannerName = preferredScannerName
        self.autoContinueSeconds = autoContinueSeconds
        self.brightness = brightness
    }

    /// Decoded field by field so a record written before a field existed still
    /// reads. A settings file that fails to decode costs the operator every
    /// other preference in it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredScannerName = try container.decodeIfPresent(
            String.self,
            forKey: .preferredScannerName
        )
        autoContinueSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .autoContinueSeconds
        ) ?? 5
        brightness = try container.decodeIfPresent(
            BrightnessAdjustment.self,
            forKey: .brightness
        ) ?? .identity
    }

    public static let `default` = ScanDeckSettings()
}

/// Persistence seam for settings.
///
/// A protocol for the same reason `DestinationBookmarkStorage` is one: a test
/// that writes to the real defaults database changes the operator's app.
public protocol ScanDeckSettingsStorage: AnyObject {
    var settingsData: Data? { get set }
}

public final class UserDefaultsScanDeckSettingsStorage: ScanDeckSettingsStorage {
    public static let defaultKey = "me.eliseorobles.ScanDeck.settings"

    private let userDefaults: UserDefaults
    private let key: String

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = UserDefaultsScanDeckSettingsStorage.defaultKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    public var settingsData: Data? {
        get {
            userDefaults.data(forKey: key)
        }
        set {
            if let newValue {
                userDefaults.set(newValue, forKey: key)
            } else {
                userDefaults.removeObject(forKey: key)
            }
        }
    }
}

public final class InMemoryScanDeckSettingsStorage: ScanDeckSettingsStorage {
    public var settingsData: Data?

    public init(settingsData: Data? = nil) {
        self.settingsData = settingsData
    }
}

/// Reads and writes ``ScanDeckSettings``.
///
/// A value over the storage, so two copies backed by the same defaults always
/// agree — which is what lets the scan provider read the current preference at
/// the moment a pass starts without being handed a reference to the UI.
public struct ScanDeckSettingsStore {
    private let storage: any ScanDeckSettingsStorage

    public init(
        storage: any ScanDeckSettingsStorage =
            UserDefaultsScanDeckSettingsStorage()
    ) {
        self.storage = storage
    }

    /// Unreadable settings fall back to the defaults rather than throwing.
    ///
    /// Nothing here is worth failing a launch over: every field has a safe
    /// default, and the alternative is an app that will not start because of a
    /// preference.
    public func load() -> ScanDeckSettings {
        guard let data = storage.settingsData,
              let settings = try? JSONDecoder().decode(
                  ScanDeckSettings.self,
                  from: data
              )
        else {
            return .default
        }
        return settings
    }

    public func save(_ settings: ScanDeckSettings) throws {
        storage.settingsData = try JSONEncoder().encode(settings)
    }
}
