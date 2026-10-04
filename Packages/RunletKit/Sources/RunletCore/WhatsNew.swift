import Foundation

// The guided tour and What's New (#232): the bundled manifest (`Runlet/WhatsNew.json`), its
// versions, and the anchors its tour steps point at. The app draws the coach marks and the
// window; everything that decides what to show lives here, so it can be tested.

/// A version and build of Runlet, as Info.plist has them: `CFBundleShortVersionString` ("0.4.0",
/// betas too) and `CFBundleVersion` (13, counting up across every release and pre-release).
/// Ordered by the version's numbers, then the build.
public struct AppVersion: Sendable, Codable, Hashable, Comparable, CustomStringConvertible {
    public var version: String
    public var build: Int

    public init(version: String, build: Int) {
        self.version = version
        self.build = build
    }

    /// Info.plist's strings; nil when either doesn't parse ("0.4", "0.4.0.1", and "1" work; a
    /// build must be a whole number).
    public init?(version: String, build: String) {
        guard let number = Int(build.trimmingCharacters(in: .whitespaces)) else { return nil }
        self.init(version: version.trimmingCharacters(in: .whitespaces), build: number)
        guard isValid else { return nil }
    }

    /// The running app's, from its Info.plist.
    public init?(infoDictionary: [String: Any]?) {
        guard let version = infoDictionary?["CFBundleShortVersionString"] as? String,
              let build = infoDictionary?["CFBundleVersion"] as? String else { return nil }
        self.init(version: version, build: build)
    }

    /// The version's numbers: "0.4.0" → [0, 4, 0]; empty when it isn't dotted whole numbers.
    public var components: [Int] {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !parts.isEmpty, numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return [] }
        return numbers
    }

    /// One to four dotted whole numbers and a build of at least 1.
    public var isValid: Bool { (1...4).contains(components.count) && build >= 1 }

    /// Whether `other` has the same version (any build): two betas of 0.4.0.
    public func sameVersion(as other: AppVersion) -> Bool {
        Self.compare(components, other.components) == .orderedSame
    }

    public var description: String { "\(version) (\(build))" }

    /// "0.4" and "0.4.0" of the same build are the same; versions that don't parse compare as text.
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        guard lhs.build == rhs.build else { return false }
        let (left, right) = (lhs.components, rhs.components)
        guard !left.isEmpty, !right.isEmpty else { return lhs.version == rhs.version }
        return compare(left, right) == .orderedSame
    }

    public func hash(into hasher: inout Hasher) {
        var numbers = components
        while numbers.last == 0 { numbers.removeLast() }
        if components.isEmpty { hasher.combine(version) } else { hasher.combine(numbers) }
        hasher.combine(build)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        switch compare(lhs.components, rhs.components) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.build < rhs.build
        }
    }

    /// Compares dotted numbers, a missing part counting as 0 ("0.4" == "0.4.0").
    static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// A place in Runlet's UI a tour step can point at. Views mark themselves with
/// `.tourAnchor(_:)`; a manifest step names one by its raw value. Never rename an id the
/// manifest uses: `WhatsNewTests` checks every id the manifest names is here.
public enum TourAnchor: String, Sendable, CaseIterable, Codable {
    /// The toolbar's target menu: the sandbox, projects, Docker, and SSH.
    case targetMenu = "target-menu"
    /// The toolbar's Run button (Stop while running).
    case runButton = "run-button"
    /// A PHP tab's Dry Run button in the toolbar (#13).
    case dryRunToggle = "dry-run-toggle"
    /// The toolbar's History & Snippets button.
    case inspectorToggle = "inspector-toggle"
    /// The History & Snippets panel's pane picker (History, Snippets, Commands, Database).
    case libraryPanePicker = "library-pane-picker"
    /// The + that adds a tab (tab strip or vertical tab list).
    case newTabButton = "new-tab-button"
    /// The current tab's editor.
    case editor
    /// The output pane's Structured / Plain / Raw picker.
    case outputModePicker = "output-mode-picker"
    /// The output pane.
    case outputPane = "output-pane"
    /// The status bar's connection count, which opens the Connection Manager (#180).
    case connectionsStatus = "connections-status"
    /// The status bar's language-service status (PHPantom).
    case languageStatus = "language-status"
    /// The bar above an SQL, Redis, or MongoDB tab's editor.
    case databaseTabBar = "database-tab-bar"
    /// That bar's connection picker.
    case connectionPicker = "connection-picker"
    /// A Redis or MongoDB tab's Builder button (#217, #218).
    case builderButton = "builder-button"

    /// Where a stop's card goes, relative to the element.
    public enum Placement: Sendable { case below, above, leading, inside }

    public var placement: Placement {
        switch self {
        case .targetMenu, .runButton, .dryRunToggle, .inspectorToggle, .libraryPanePicker, .newTabButton,
             .outputModePicker, .databaseTabBar, .connectionPicker, .builderButton: .below
        case .connectionsStatus, .languageStatus: .above
        case .editor, .outputPane: .inside
        }
    }

    /// Its symbol, for a stop shown centred because the element isn't on screen.
    public var symbol: String {
        switch self {
        case .targetMenu: "shippingbox"
        case .runButton: "play.fill"
        case .dryRunToggle: "arrow.uturn.backward.circle"
        case .inspectorToggle, .libraryPanePicker: "sidebar.trailing"
        case .newTabButton: "plus.rectangle.on.rectangle"
        case .editor: "character.cursor.ibeam"
        case .outputModePicker, .outputPane: "text.alignleft"
        case .connectionsStatus: "point.3.connected.trianglepath.dotted"
        case .languageStatus: "checkmark.seal"
        case .databaseTabBar, .connectionPicker: "cylinder.split.1x2"
        case .builderButton: "hammer"
        }
    }

    /// Where it is, for a centred stop: "It's in the toolbar of PHP tabs."
    public var whereToFind: String {
        switch self {
        case .targetMenu: "It's the menu at the left of the toolbar."
        case .runButton: "It's in the toolbar."
        case .dryRunToggle: "It's in the toolbar of PHP tabs."
        case .inspectorToggle: "It's the button at the right of the toolbar."
        case .libraryPanePicker: "It's at the top of the History & Snippets panel."
        case .newTabButton: "It's the + at the end of the tabs."
        case .editor: "It's the editor of the current tab."
        case .outputModePicker: "It's at the top of the output pane."
        case .outputPane: "It's next to the editor (or below it)."
        case .connectionsStatus: "It's in the status bar, at the bottom of the window."
        case .languageStatus: "It's at the right of the status bar."
        case .databaseTabBar, .connectionPicker: "It's in the bar above the editor of SQL, Redis, and MongoDB tabs."
        case .builderButton: "It's in the bar above the editor of Redis and MongoDB tabs."
        }
    }
}

/// UI a step may open first so its element is on screen. Only harmless ones exist: none runs
/// code, connects, loads anything, or changes data (the Commands pane isn't one, since listing
/// commands boots the application).
public enum TourPreparation: String, Sendable, CaseIterable, Codable {
    case inspectorHistory = "inspector-history"
    case inspectorSnippets = "inspector-snippets"
    /// The Database pane shows what is already loaded; loading stays a click on Load.
    case inspectorDatabase = "inspector-database"
    case outputPane = "output-pane"
}

/// One coach mark: a card pointing at `anchor`, or shown centred with a small illustration when
/// it has none (a menu command) or the element isn't on screen.
public struct TourStep: Sendable, Codable, Equatable {
    /// A `TourAnchor` raw value; nil for a centred stop.
    public var anchor: String?
    public var title: String
    public var text: String
    /// The menu path the illustration shows: "View ▸ Logs".
    public var menu: String?
    /// A command id (the app's `CommandCatalog`) whose shortcut, as the user mapped it, the card shows.
    public var command: String?
    /// Keys to show when there is no command: "⌥↑ ⌥↓".
    public var keys: String?
    /// A `TourPreparation` raw value.
    public var prepare: String?
    /// The illustration's symbol for a centred stop (else the anchor's, else a light bulb).
    public var symbol: String?

    public init(anchor: TourAnchor? = nil, title: String, text: String, menu: String? = nil, command: String? = nil,
                keys: String? = nil, prepare: TourPreparation? = nil, symbol: String? = nil) {
        self.anchor = anchor?.rawValue
        self.title = title
        self.text = text
        self.menu = menu
        self.command = command
        self.keys = keys
        self.prepare = prepare?.rawValue
        self.symbol = symbol
    }

    public var tourAnchor: TourAnchor? { anchor.flatMap(TourAnchor.init(rawValue:)) }
    public var preparation: TourPreparation? { prepare.flatMap(TourPreparation.init(rawValue:)) }
    /// What a centred card draws.
    public var illustrationSymbol: String { symbol ?? tourAnchor?.symbol ?? "lightbulb" }
}

/// One highlighted feature of a release.
public struct WhatsNewFeature: Sendable, Codable, Equatable, Identifiable {
    /// Unique in the manifest, lowercase words with dashes ("log-viewer").
    public var id: String
    public var title: String
    /// One or two sentences.
    public var text: String
    public var symbol: String?
    /// Featured at the top, on a banner card.
    public var important: Bool
    /// An optional image in the app's asset catalog.
    public var image: String?
    /// A `FeatureFlag` id when the feature is behind one: the card says how to turn it on.
    public var flag: String?
    /// Show Me's mini-tour; empty for none.
    public var tour: [TourStep]

    public init(id: String, title: String, text: String, symbol: String? = nil, important: Bool = false,
                image: String? = nil, flag: String? = nil, tour: [TourStep] = []) {
        self.id = id
        self.title = title
        self.text = text
        self.symbol = symbol
        self.important = important
        self.image = image
        self.flag = flag
        self.tour = tour
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        important = try c.decodeIfPresent(Bool.self, forKey: .important) ?? false
        image = try c.decodeIfPresent(String.self, forKey: .image)
        flag = try c.decodeIfPresent(String.self, forKey: .flag)
        tour = try c.decodeIfPresent([TourStep].self, forKey: .tour) ?? []
    }
}

/// The entries of one version and build: each beta build can have its own.
public struct WhatsNewRelease: Sendable, Codable, Equatable {
    /// `CFBundleShortVersionString`, e.g. "0.4.0".
    public var version: String
    /// `CFBundleVersion`.
    public var build: Int
    /// What people call it: "0.4.0 beta 7", "0.4.0".
    public var label: String
    /// ISO date of the release, for the window.
    public var date: String?
    /// Its release notes (a GitHub release).
    public var notes: String?
    public var features: [WhatsNewFeature]
    /// "Also in this version": short lines.
    public var also: [String]

    public init(version: String, build: Int, label: String, date: String? = nil, notes: String? = nil,
                features: [WhatsNewFeature] = [], also: [String] = []) {
        self.version = version
        self.build = build
        self.label = label
        self.date = date
        self.notes = notes
        self.features = features
        self.also = also
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        build = try c.decode(Int.self, forKey: .build)
        label = try c.decode(String.self, forKey: .label)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        features = try c.decodeIfPresent([WhatsNewFeature].self, forKey: .features) ?? []
        also = try c.decodeIfPresent([String].self, forKey: .also) ?? []
    }

    public var appVersion: AppVersion { AppVersion(version: version, build: build) }
}

/// What the What's New window shows for one version: its builds' entries together, newest first.
public struct WhatsNewSection: Sendable, Equatable, Identifiable {
    /// Its builds, newest first.
    public var releases: [WhatsNewRelease]

    public var id: String { releases.first.map { "\($0.version)+\($0.build)" } ?? "" }
    /// The newest build's label: "0.4.0 beta 7".
    public var label: String { releases.first?.label ?? "" }
    public var version: String { releases.first?.version ?? "" }
    /// Important features first, then the rest; newest build first within each.
    public var features: [WhatsNewFeature] {
        let all = releases.flatMap(\.features)
        return all.filter(\.important) + all.filter { !$0.important }
    }
    public var also: [String] { releases.flatMap(\.also) }
    /// The newest build's release notes.
    public var notes: URL? { releases.first?.notes.flatMap(URL.init(string:)) }
}

/// The bundled manifest: the first-launch tour and each release's entries.
public struct WhatsNewManifest: Sendable, Codable, Equatable {
    /// The first-launch guided tour (Help ▸ Show Tour replays it).
    public var tour: [TourStep]
    public var releases: [WhatsNewRelease]
    /// The full changelog, linked under the entries.
    public var changelog: String?

    public init(tour: [TourStep] = [], releases: [WhatsNewRelease] = [], changelog: String? = nil) {
        self.tour = tour
        self.releases = releases
        self.changelog = changelog
    }

    public static func decode(_ data: Data) throws -> WhatsNewManifest {
        try JSONDecoder().decode(WhatsNewManifest.self, from: data)
    }

    /// Releases newer than `seen` and no newer than `current`, newest first. With `seen` nil
    /// (someone who used an older Runlet before What's New existed), every build of `current`'s
    /// version up to it.
    public func releases(after seen: AppVersion?, through current: AppVersion) -> [WhatsNewRelease] {
        releases
            .filter { release in
                let key = release.appVersion
                guard key.isValid, key <= current else { return false }
                if let seen { return seen < key }
                return key.sameVersion(as: current)
            }
            .sorted { $0.appVersion > $1.appVersion }
    }

    /// `releases(after:through:)` grouped by version, newest first.
    public func sections(after seen: AppVersion?, through current: AppVersion) -> [WhatsNewSection] {
        Self.group(releases(after: seen, through: current))
    }

    /// Help ▸ What's New: every build of the newest version this app has entries for (up to
    /// it); a development build older than every entry gets the newest version's.
    public func currentSections(for current: AppVersion) -> [WhatsNewSection] {
        let valid = releases.filter(\.appVersion.isValid)
        let upTo = valid.filter { $0.appVersion <= current }
        let pool = upTo.isEmpty ? valid : upTo
        guard let newest = pool.max(by: { $0.appVersion < $1.appVersion }) else { return [] }
        return Self.group(pool.filter { $0.appVersion.sameVersion(as: newest.appVersion) }.sorted { $0.appVersion > $1.appVersion })
    }

    /// The newest release in the manifest.
    public var newest: AppVersion? { releases.map(\.appVersion).filter(\.isValid).max() }

    /// Whether `version` has its own entry (same version and build).
    public func hasEntry(for version: AppVersion) -> Bool {
        releases.contains { $0.appVersion == version }
    }

    /// Whether a build of `version` is covered: it has its own entry, or the manifest already
    /// has entries for a newer build (written before the release commit sets the version).
    public func covers(_ version: AppVersion) -> Bool {
        hasEntry(for: version) || (newest.map { version < $0 } ?? false)
    }

    /// A feature by id, with the release it's in.
    public func feature(_ id: String) -> (feature: WhatsNewFeature, release: WhatsNewRelease)? {
        for release in releases {
            if let feature = release.features.first(where: { $0.id == id }) { return (feature, release) }
        }
        return nil
    }

    /// What is wrong with the manifest: versions that don't parse, a build listed twice, empty
    /// texts, repeated or badly formed feature ids, anchors, preparations, feature flags, or
    /// (when `commands` is given) command ids that don't exist, and URLs that don't parse.
    public func problems(flags: Set<String> = Set(FeatureFlag.all.map(\.id)), commands: Set<String>? = nil) -> [String] {
        var problems: [String] = []
        func check(_ steps: [TourStep], _ owner: String) {
            for (index, step) in steps.enumerated() {
                let name = "\(owner) step \(index + 1)"
                if step.title.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(name) has no title") }
                if step.text.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(name) has no text") }
                if let anchor = step.anchor, TourAnchor(rawValue: anchor) == nil { problems.append("\(name) points at unknown anchor \(anchor)") }
                if let prepare = step.prepare, TourPreparation(rawValue: prepare) == nil { problems.append("\(name) has unknown preparation \(prepare)") }
                if let command = step.command, let commands, !commands.contains(command) { problems.append("\(name) names unknown command \(command)") }
                if step.anchor == nil, step.menu == nil, step.command == nil, step.keys == nil {
                    problems.append("\(name) has no anchor, menu, command, or keys to show")
                }
            }
        }
        if tour.isEmpty { problems.append("the first-launch tour has no steps") }
        if tour.count > 10 { problems.append("the first-launch tour has \(tour.count) steps; keep it to 10 or fewer") }
        check(tour, "tour")
        var seenVersions: Set<AppVersion> = []
        var seenIds: Set<String> = []
        for release in releases {
            let name = "\(release.label) (\(release.version) build \(release.build))"
            if !release.appVersion.isValid { problems.append("\(name): the version or build doesn't parse") }
            if !seenVersions.insert(release.appVersion).inserted { problems.append("\(name) is listed twice") }
            if release.label.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(name) has no label") }
            if release.features.isEmpty, release.also.isEmpty { problems.append("\(name) has no entries") }
            if let notes = release.notes, URL(string: notes)?.scheme == nil { problems.append("\(name): notes isn't a URL") }
            for feature in release.features {
                if !seenIds.insert(feature.id).inserted { problems.append("feature \(feature.id) is listed twice") }
                if feature.id.isEmpty || feature.id.contains(where: { !($0.isLowercase || $0.isNumber || $0 == "-") }) {
                    problems.append("feature id \(feature.id) isn't lowercase words with dashes")
                }
                if feature.title.trimmingCharacters(in: .whitespaces).isEmpty || feature.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    problems.append("feature \(feature.id) has no title or text")
                }
                if let flag = feature.flag, !flags.contains(flag) { problems.append("feature \(feature.id) names unknown feature flag \(flag)") }
                check(feature.tour, "feature \(feature.id)")
            }
            for line in release.also where line.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(name) has an empty Also line") }
        }
        if let changelog, URL(string: changelog)?.scheme == nil { problems.append("changelog isn't a URL") }
        return problems
    }

    /// Every anchor the manifest's steps name.
    public var anchorIds: Set<String> {
        Set((tour + releases.flatMap { $0.features.flatMap(\.tour) }).compactMap(\.anchor))
    }

    static func group(_ releases: [WhatsNewRelease]) -> [WhatsNewSection] {
        var sections: [WhatsNewSection] = []
        for release in releases {
            if let last = sections.last?.releases.first, last.appVersion.sameVersion(as: release.appVersion) {
                sections[sections.count - 1].releases.append(release)
            } else {
                sections.append(WhatsNewSection(releases: [release]))
            }
        }
        return sections
    }
}
