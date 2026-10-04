import Foundation

/// A hidden or experimental feature that Settings ▸ Advanced turns on (#187). Every flag is off
/// by default. Code asks through one accessor (`AppSettings.isEnabled(_:forcedOn:)`, or the
/// app's `AppModel.isEnabled(_:)`), never by reading `featureFlags` itself.
public struct FeatureFlag: Sendable, Hashable, Identifiable {
    /// Stable key in `settings.json` (`featureFlags`). Never reuse an id for another feature.
    public let id: String
    public let title: String
    /// One line for Settings ▸ Advanced.
    public let summary: String
    /// The GitHub issue that adds the feature.
    public let issue: Int?
    public let defaultValue: Bool

    public init(id: String, title: String, summary: String, issue: Int? = nil, defaultValue: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.issue = issue
        self.defaultValue = defaultValue
    }

    /// Import from TablePlus… in Settings ▸ Databases and Edit Connections (#188).
    public static let tablePlusImport = FeatureFlag(
        id: "tablePlusImport",
        title: "Import connections from TablePlus",
        summary: "Adds Import from TablePlus… to Settings ▸ Databases and Edit Connections. It reads TablePlus's connection list only when you click it, and its Keychain items only if you ask.",
        issue: 188
    )

    /// Every registered flag, in the order Settings ▸ Advanced lists them.
    public static let all: [FeatureFlag] = [.tablePlusImport]

    public static func named(_ id: String) -> FeatureFlag? {
        all.first { $0.id == id }
    }

    /// The ids in `RUNLET_FEATURE_FLAGS` (Debug builds only; the app decides whether to read
    /// it): comma- or space-separated, case-insensitive against the registry. Unknown ids are
    /// dropped.
    public static func ids(in list: String?) -> Set<String> {
        guard let list else { return [] }
        let words = list.split { $0 == "," || $0 == " " || $0 == ";" }.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return Set(all.filter { words.contains($0.id.lowercased()) }.map(\.id))
    }
}

extension AppSettings {
    /// Whether `flag` is on: forced on (`RUNLET_FEATURE_FLAGS` in Debug builds), else the saved
    /// choice, else the flag's default (off).
    public func isEnabled(_ flag: FeatureFlag, forcedOn: Set<String> = []) -> Bool {
        forcedOn.contains(flag.id) || (featureFlags[flag.id] ?? flag.defaultValue)
    }

    /// Saves the choice. Other entries, including flags this Runlet doesn't know (from a newer
    /// or older one), stay as they are. Turning a flag off only hides its UI: nothing the
    /// feature created is removed.
    public mutating func setEnabled(_ flag: FeatureFlag, _ enabled: Bool) {
        featureFlags[flag.id] = enabled
    }
}
