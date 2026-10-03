import Foundation
import Security

/// A secret, such as a saved database connection's password (#138), that never prints:
/// `description`, `debugDescription`, string interpolation, `dump()`, and mirrors all show
/// `•••`. It isn't `Codable`, so it can't end up in a JSON document by accident. Call
/// `revealed()` only where the value is handed on (the runner request on stdin, the Keychain).
public struct SensitiveString: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let storage: String

    public init(_ value: String) {
        storage = value
    }

    public func revealed() -> String { storage }

    public var isEmpty: Bool { storage.isEmpty }

    public static let redacted = "•••"

    public var description: String { Self.redacted }
    public var debugDescription: String { "SensitiveString(\(Self.redacted))" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

public struct CredentialStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    public var status: Int32
    public var description: String

    public init(status: Int32, _ description: String) {
        self.status = status
        self.description = description
    }
}

/// Where Runlet keeps saved connections' passwords (#138): the macOS Keychain in the app
/// (`KeychainCredentialStore`), memory in tests and Debug runs with scratch data
/// (`InMemoryCredentialStore`). Accounts are connection ids. Only the app uses a store; the
/// `runlet` command and `runlet mcp` never read one.
public protocol CredentialStore: Sendable {
    /// Saves (or replaces) the secret. `label` names the item in Keychain Access.
    func set(_ secret: SensitiveString, for account: UUID, label: String) throws
    /// The secret, or nil when none is saved. May show macOS's Keychain prompt.
    func read(_ account: UUID) throws -> SensitiveString?
    /// Deletes the secret; deleting a missing one is not an error.
    func delete(_ account: UUID) throws
    /// Whether a secret is saved, without reading it (no Keychain prompt).
    func exists(_ account: UUID) -> Bool
}

/// Secrets in memory only, for tests and Debug runs (`RUNLET_CREDENTIALS=memory`).
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: SensitiveString] = [:]
    private var labels: [UUID: String] = [:]
    /// Tests: make `set` fail, as a Keychain write can.
    public var failsWrites = false

    public init() {}

    public func set(_ secret: SensitiveString, for account: UUID, label: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failsWrites { throw CredentialStoreError(status: -1, "The test store refused the write.") }
        secrets[account] = secret
        labels[account] = label
    }

    public func read(_ account: UUID) throws -> SensitiveString? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    public func delete(_ account: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = nil
        labels[account] = nil
    }

    public func exists(_ account: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account] != nil
    }

    public func label(_ account: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return labels[account]
    }

    public var accounts: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(secrets.keys)
    }
}

/// Generic-password items in the login keychain (#138): service `dev.runlet.Runlet.database`
/// (with a data-folder suffix for a scratch `RUNLET_DATA_DIR`), account = the connection's
/// UUID, never synchronized to iCloud. The app is ad-hoc signed, so it uses the file-based
/// login keychain; macOS may ask once after an update before the new build can read an item
/// (Always Allow), until Developer ID signing (#24).
public struct KeychainCredentialStore: CredentialStore {
    public static let baseService = "dev.runlet.Runlet.database"
    public static let comment = "Runlet saved database connection"

    public let service: String

    public init(service: String = KeychainCredentialStore.baseService) {
        self.service = service
    }

    /// The base service for the standard data folder; for any other (a scratch
    /// `RUNLET_DATA_DIR`), the base plus 8 hex digits of a hash of its path, so development
    /// runs never read or write the real items.
    public static func service(for paths: AppPaths, standard: AppPaths? = nil) -> String {
        let standardRoot = (standard ?? Self.standardPaths).root.standardizedFileURL.path
        let root = paths.root.standardizedFileURL.path
        return root == standardRoot ? baseService : baseService + "." + MCPSocketPaths.shortHash(root)
    }

    /// `~/Library/Application Support/Runlet`, whatever `RUNLET_DATA_DIR` says.
    static var standardPaths: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppPaths(root: base.appendingPathComponent("Runlet", isDirectory: true))
    }

    private func query(_ account: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    public func set(_ secret: SensitiveString, for account: UUID, label: String) throws {
        let data = Data(secret.revealed().utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
            kSecAttrComment as String: Self.comment,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account).merging(attributes) { $1 }
            // Ignored by the file-based keychain; kept for the move to the data-protection
            // keychain once Runlet is Developer ID signed (#24).
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecParam || status == errSecNoSuchAttr {
                item[kSecAttrAccessible as String] = nil
                status = SecItemAdd(item as CFDictionary, nil)
            }
        }
        guard status == errSecSuccess else { throw Self.error(status, doing: "save the password in") }
    }

    public func read(_ account: UUID) throws -> SensitiveString? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status, doing: "read the password from") }
        return SensitiveString(String(decoding: data, as: UTF8.self))
    }

    public func delete(_ account: UUID) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, doing: "delete the password from") }
    }

    public func exists(_ account: UUID) -> Bool {
        var item = query(account)
        item[kSecReturnAttributes as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess
    }

    static func error(_ status: OSStatus, doing action: String) -> CredentialStoreError {
        let reason: String
        switch status {
        case errSecUserCanceled, errSecAuthFailed:
            reason = "macOS didn't allow it (Deny was chosen, or the password was wrong)."
        case errSecInteractionNotAllowed:
            reason = "the keychain is locked or can't ask right now."
        default:
            reason = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)."
        }
        return CredentialStoreError(status: status, "Runlet couldn't \(action) the Keychain: \(reason)")
    }
}
