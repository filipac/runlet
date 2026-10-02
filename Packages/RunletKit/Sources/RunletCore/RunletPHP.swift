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

    public init(version: String, build: String, assets: [String: Asset]) {
        self.version = version
        self.build = build
        self.assets = assets
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
        build: "r1",
        assets: [
            "arm64": Asset(
                url: URL(string: "https://github.com/filipac/runlet/releases/download/php-8.5.8-r1/runlet-php-8.5.8-r1-macos-arm64.tar.gz")!,
                sha256: "e253ce068b86e5856d96499642d36a04c4ddc6fe882c5a8f2129db4709df3a04",
                size: 25_730_675
            ),
            "x86_64": Asset(
                url: URL(string: "https://github.com/filipac/runlet/releases/download/php-8.5.8-r1/runlet-php-8.5.8-r1-macos-x86_64.tar.gz")!,
                sha256: "0000000000000000000000000000000000000000000000000000000000000000",
                size: 0
            ),
        ]
    )
}
