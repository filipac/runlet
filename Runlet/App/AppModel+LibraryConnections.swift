import Foundation
import RunletCore

/// Where library code with a connection comes from (#149), for the SQL bar's note.
enum LibraryConnectionSource: String {
    case historyEntry = "entry"
    case snippet
}

/// Run History entries and SQL snippets remember their connection (#149). Opening one puts the
/// SQL tab on that connection, resolved on the tab's target (`TargetLibrary.resolve`): never a
/// different target's own saved connection. A saved connection that no longer exists leaves the
/// tab on the default connection, with a note in its SQL bar. Nothing connects or runs; how a
/// run is marked (production, #139) follows the tab's connection as always.
extension AppModel {
    /// Puts an SQL tab on `reference` (nil keeps the tab's connection). Called after the tab
    /// got the entry's or snippet's code and language; a PHP tab ignores it.
    func applyLibraryConnection(_ reference: SQLConnectionReference?, to tab: TabModel, from source: LibraryConnectionSource) {
        tab.sqlConnectionNote = nil
        guard let reference, let family = tab.language.connectionFamily else { return }
        switch library.resolve(reference, on: tab.target, family: family) {
        case .application(let name):
            setSQLConnection(name, for: tab)
        case .saved(let connection):
            setSQLSavedConnection(connection, for: tab)
        case .missing(let name):
            setSQLConnection(nil, for: tab)
            tab.sqlConnectionNote = SQLConnectionReference.missingNote(name, source: source.rawValue)
        }
    }

    /// The connection a snippet saved from an SQL tab keeps (#149): by name and kind, never an
    /// id; nil for the default connection and for PHP tabs.
    func snippetConnection(for tab: TabModel) -> SQLConnectionReference? {
        guard tab.language.usesDatabaseConnection else { return nil }
        switch sqlConnectionChoice(for: tab) {
        case .app(let name): return name.map { .application($0) }
        case .saved(let connection): return SQLConnectionReference(connection).forSnippet
        case .missing(let name): return .saved(name: name)
        }
    }

    /// "Reporting (saved connection of all targets)" for help texts and the snippet sheets.
    func describe(_ reference: SQLConnectionReference) -> String {
        switch reference {
        case .application(nil): "the application's default connection"
        case .application(let name?): "the application connection “\(name)”"
        case .saved(let name, _, let allTargets): "the saved connection “\(name)”" + (allTargets ? " (all targets)" : "")
        case .named(let name): "the connection “\(name)”"
        }
    }
}
