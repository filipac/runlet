import Foundation
import RunletCore

/// Owns PHPantom sessions: one per workspace/configuration, shared by every tab that uses
/// the same workspace, stopped when the last tab releases it.
public actor LanguageService {
    public nonisolated let binary: URL
    public nonisolated let dataDirectory: URL
    private var sessions: [LanguageWorkspace: (session: LanguageServerSession, users: Set<UUID>)] = [:]

    public init(binary: URL, dataDirectory: URL) {
        self.binary = binary
        self.dataDirectory = dataDirectory
    }

    /// Workspace with no project source, used for unmapped Docker containers.
    public nonisolated var basicWorkspaceRoot: URL { dataDirectory.appendingPathComponent("basic-workspace", isDirectory: true) }

    public var isBinaryAvailable: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    /// Registers `user` (a tab) with the workspace's session, starting it if necessary.
    public func acquire(_ workspace: LanguageWorkspace, for user: UUID) -> LanguageServerSession {
        if var entry = sessions[workspace] {
            entry.users.insert(user)
            sessions[workspace] = entry
            return entry.session
        }
        let session = LanguageServerSession(workspace: workspace, binary: binary, configBase: dataDirectory)
        sessions[workspace] = (session, [user])
        Task { await session.start() }
        return session
    }

    /// Releases a tab's use of a workspace; the server stops when nobody uses it.
    public func release(_ workspace: LanguageWorkspace, for user: UUID) async {
        guard var entry = sessions[workspace] else { return }
        entry.users.remove(user)
        if entry.users.isEmpty {
            sessions[workspace] = nil
            await entry.session.stop()
        } else {
            sessions[workspace] = entry
        }
    }

    public func stopAll() async {
        let all = sessions.values.map(\.session)
        sessions = [:]
        for session in all { await session.stop() }
    }

    public var activeWorkspaces: [LanguageWorkspace] { Array(sessions.keys) }

    /// A stable, never-written document URI under the workspace root for one editor tab.
    /// PHPantom resolves it with the real project root; no file is created on disk.
    public static func scratchURI(root: URL, documentId: UUID) -> String {
        root.appendingPathComponent(".runlet-scratch", isDirectory: true)
            .appendingPathComponent("tab-\(documentId.uuidString.lowercased()).php").absoluteString
    }
}
