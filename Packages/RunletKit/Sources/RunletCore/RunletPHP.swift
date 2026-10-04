import Foundation

/// Runlet's own PHP ([#2](https://github.com/filipac/runlet/issues/2)): a static PHP CLI built
/// by `.github/workflows/php-runtime.yml` (static-php-cli, `scripts/php-runtime/craft.yml`)
/// and published as a GitHub release asset per CPU type. It is downloaded only when the user
/// asks, into Application Support, verified by SHA-256, and used only when no installed PHP
/// fits (it is listed after every discovered installation).
public struct RunletPHPRelease: Sendable, Equatable, Codable {
    public struct Asset: Sendable, Equatable, Codable {
        public var url: URL
        /// Lowercase hex SHA-256 of the `.tar.gz`.
        public var sha256: String
        /// Size of the `.tar.gz` in bytes (shown before downloading; larger downloads are refused).
        public var size: Int64

        public init(url: URL, sha256: String, size: Int64) {
            self.url = url
            self.sha256 = sha256
            self.size = size
        }
    }

    /// PHP version, e.g. "8.5.8".
    public var version: String
    /// Runlet's build of that version, e.g. "r1" (a new build for new extensions or fixes).
    public var build: String
    /// Keyed by `arm64` and `x86_64`.
    public var assets: [String: Asset]
    /// What this build adds over the previous one, shown when an older build is installed.
    public var changes: String?

    public init(version: String, build: String, assets: [String: Asset], changes: String? = nil) {
        self.version = version
        self.build = build
        self.assets = assets
        self.changes = changes
    }

    /// "8.5.8-r1": the install folder and the archive's top-level folder (`php-8.5.8-r1`).
    public var identifier: String { "\(version)-\(build)" }

    /// The archive for this Mac: arm64 on Apple silicon (also when Runlet itself runs under
    /// Rosetta), else x86_64.
    public var assetForThisMac: Asset? { assets[Self.machineArchitecture] }

    public static var machineArchitecture: String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 { return "arm64" }
        return "x86_64"
    }

    /// The release this build of Runlet installs.
    public static let current = RunletPHPRelease(
        version: "8.5.8",
        build: "r3",
        assets: [
            "arm64": Asset(
                url: URL(string: "https://github.com/filipac/runlet/releases/download/php-8.5.8-r3/runlet-php-8.5.8-r3-macos-arm64.tar.gz")!,
                sha256: "5433d93bef324d534705d60c363ca93e0193e75f2a8ab19b7b6408f6fd8f964b",
                size: 26_391_664
            ),
            "x86_64": Asset(
                url: URL(string: "https://github.com/filipac/runlet/releases/download/php-8.5.8-r3/runlet-php-8.5.8-r3-macos-x86_64.tar.gz")!,
                sha256: "37ef4416ea00386629236de39f9b2cf3328cbc08938104a09d2dc1e8ce9b85e3",
                size: 26_897_537
            ),
        ],
        changes: "Adds the mongodb extension for MongoDB connections from this Mac."
    )
}
