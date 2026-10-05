import AppKit
import Observation
import RunletCore
import UniformTypeIdentifiers

/// An open Import from TablePlus… sheet (#188): what was read, the user's choices, and the
/// summary once imported. Nothing here connects.
@MainActor
@Observable
final class TablePlusImportSession: Identifiable {
    enum Phase: Equatable {
        case choosing
        /// Reading TablePlus's Keychain items (macOS may be asking) and saving.
        case importing
        case done(TablePlusImportSummary)
    }

    let id = UUID()
    var plan: TablePlusImportPlan
    /// The file read, for the sheet's header ("~/Library/…/Connections.plist").
    var source: String?
    /// Why nothing could be read (no TablePlus list at the default location, an unreadable file).
    var readError: String?
    var options = TablePlusImportOptions()
    var phase: Phase = .choosing
    /// A row the list scrolls to (the `tableplus-scroll` Debug step).
    var scrollTarget: String?

    /// The open sheet, for Debug steps.
    static weak var current: TablePlusImportSession?

    init(plan: TablePlusImportPlan = TablePlusImportPlan(TablePlusParser.Result()), source: String? = nil, readError: String? = nil) {
        self.plan = plan
        self.source = source
        self.readError = readError
    }

    var summary: TablePlusImportSummary? {
        if case .done(let summary) = phase { return summary }
        return nil
    }

    func isSelected(_ row: TablePlusImportRow) -> Bool { options.selected.contains(row.id) }

    func setSelected(_ row: TablePlusImportRow, _ selected: Bool) {
        guard row.canImport else { return }
        if selected { options.selected.insert(row.id) } else { options.selected.remove(row.id) }
    }

    func selectAll(_ selected: Bool) {
        options.selected = selected ? Set(plan.rows.filter(\.canImport).map(\.id)) : []
    }
}

/// Import from TablePlus… (#188), behind the feature flag of #187. TablePlus's files are read
/// only when the user opens the sheet or chooses a file, and its Keychain items only when the
/// user ticks "Also copy passwords" and imports.
extension AppModel {
    /// `RUNLET_TABLEPLUS_DIR` (Debug builds only): a folder with fixture `Connections.plist`,
    /// `ConnectionGroups.plist`, and `keychain-fixture.json`, read instead of TablePlus's.
    /// `RUNLET_DEBUG_TABLEPLUS_PATH` sets the path the sheet shows for it (#304).
    static var tablePlusFixtureFolder: URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["RUNLET_TABLEPLUS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        return nil
    }

    /// Debug builds with scratch data (`RUNLET_DATA_DIR`) never read TablePlus's real files or
    /// Keychain items: development runs and screenshots use `RUNLET_TABLEPLUS_DIR` or a chosen file.
    static var tablePlusRealDataBlocked: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return !(environment["RUNLET_DATA_DIR"] ?? "").isEmpty || tablePlusFixtureFolder != nil
        #else
        return false
        #endif
    }

    /// TablePlus's connection list: the standalone app's, else the Setapp edition's.
    static var tablePlusDefaultFiles: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ["com.tinyapp.TablePlus", "com.tinyapp.TablePlus-setapp"].map {
            support.appendingPathComponent($0).appendingPathComponent("Data/Connections.plist")
        }
    }

    /// Reads the database passwords: the Keychain, or in Debug runs with fixtures or scratch
    /// data, `keychain-fixture.json` (never the Keychain).
    var tablePlusKeychainReader: TablePlusKeychainReader {
        #if DEBUG
        if Self.tablePlusRealDataBlocked {
            let fixture = Self.tablePlusFixtureFolder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("keychain-fixture.json")) }
            return FakeTablePlusKeychainReader(fixture: fixture ?? Data("{}".utf8))
        }
        #endif
        return SecurityTablePlusKeychainReader()
    }

    /// Opens the sheet on TablePlus's own list (Import from TablePlus…).
    func makeTablePlusImportSession() -> TablePlusImportSession {
        let session: TablePlusImportSession
        if let folder = Self.tablePlusFixtureFolder {
            session = readTablePlusFile(folder.appendingPathComponent("Connections.plist"))
            #if DEBUG
            // `RUNLET_DEBUG_TABLEPLUS_PATH` (#304): the path the sheet shows for the fixture's
            // file, so screenshots name TablePlus's own location instead of a scratch folder.
            if let shown = ProcessInfo.processInfo.environment["RUNLET_DEBUG_TABLEPLUS_PATH"], !shown.isEmpty { session.source = shown }
            #endif
        } else if Self.tablePlusRealDataBlocked {
            session = TablePlusImportSession(readError: "Debug builds with scratch data don't read TablePlus's own files. Set RUNLET_TABLEPLUS_DIR to a fixture folder, or choose a file.")
        } else if let file = Self.tablePlusDefaultFiles.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            session = readTablePlusFile(file)
        } else {
            session = TablePlusImportSession(readError: "TablePlus's connection list wasn't found in ~/Library/Application Support/com.tinyapp.TablePlus/Data. Choose File… to pick a copy of Connections.plist.")
        }
        TablePlusImportSession.current = session
        return session
    }

    /// A session for `file` (and the `ConnectionGroups.plist` next to it, when there is one).
    func readTablePlusFile(_ file: URL) -> TablePlusImportSession {
        let display = (file.path as NSString).abbreviatingWithTildeInPath
        do {
            let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= TablePlusParser.maximumFileSize else {
                return TablePlusImportSession(source: display, readError: "\(display) is larger than \(TablePlusParser.maximumFileSize >> 20) MB, so it isn't a TablePlus connection list.")
            }
            let data = try Data(contentsOf: file)
            let groupsFile = file.deletingLastPathComponent().appendingPathComponent("ConnectionGroups.plist")
            let groups = (try? groupsFile.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 <= TablePlusParser.maximumFileSize ? try? Data(contentsOf: groupsFile) : nil }
            let parsed = TablePlusParser.parse(connections: data, groups: groups)
            return TablePlusImportSession(plan: TablePlusImportPlan(parsed), source: display, readError: parsed.connections.isEmpty ? (parsed.problems.first ?? "\(display) has no connections.") : nil)
        } catch {
            return TablePlusImportSession(source: display, readError: "Runlet couldn't read \(display): \(error.localizedDescription)")
        }
    }

    /// Choose File…: a copy of `Connections.plist` (or TablePlus's own, wherever it is).
    func chooseTablePlusFile(into session: TablePlusImportSession, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose TablePlus's Connections.plist, or a copy of it. ConnectionGroups.plist next to it names the groups."
        panel.prompt = "Read"
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self, weak session] response in
            guard response == .OK, let url = panel.url, let self, let session else { return }
            let read = self.readTablePlusFile(url)
            session.plan = read.plan
            session.source = read.source
            session.readError = read.readError
            session.options = TablePlusImportOptions(scope: session.options.scope, duplicates: session.options.duplicates, copyPasswords: session.options.copyPasswords)
            session.phase = .choosing
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: apply) } else { apply(panel.runModal()) }
    }

    /// Import: reads the passwords if asked (off the main thread; macOS asks per item), then
    /// saves the SSH profiles and connections, and the passwords in the credential store.
    func performTablePlusImport(_ session: TablePlusImportSession) {
        guard session.phase == .choosing else { return }
        let plan = session.plan
        let options = session.options
        let requests = plan.passwordRequests(options: options, library: library)
        let reader = tablePlusKeychainReader
        session.phase = .importing
        Task { [weak self, weak session] in
            let passwords = requests.isEmpty ? [:] : await Task.detached(priority: .userInitiated) {
                TablePlusImport.readPasswords(requests, reader: reader)
            }.value
            // The import completes even if the sheet went away meanwhile.
            guard let self else { return }
            var updated = self.library
            let outcome = TablePlusImport.apply(plan, options: options, library: &updated, passwords: passwords, credentials: self.credentials)
            self.library = updated
            self.saveLibrary()
            for id in outcome.savedConnections {
                self.databaseUI.passwordSaved[id] = nil
                if let connection = self.library.databaseConnection(id) {
                    self.forgetSQLSchema(target: connection.scope ?? .sandbox, ref: .saved(id))
                }
                self.cancelSQLTunnel(for: id)
            }
            session?.phase = .done(outcome.summary)
        }
    }
}
