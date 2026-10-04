#if DEBUG
import AppKit
import RunletCore
import SwiftUI

/// RUNLET_DEBUG_STEPS for the relations diagram (#153), for screenshots and scripted checks with
/// scratch data (see `DebugSteps`). They act on the most recently opened diagram window:
/// `relations:<table>` (Show Relations on the current tab's explorer schema, as the Database
/// pane's row button does) · `relations-hops:1|2` · `relations-columns:all|keys` ·
/// `relations-focus:<table>` (a click on the table: centres on it) · `relations-back` and
/// `relations-forward` · `relations-expand:<group id>|all` (a click on "+N more"; group ids are
/// `referenced-1`, `referencing-2`, …) · `relations-select:<from table>|<to table>` (a click on
/// that foreign key's line; `relations-select:` clears it) · `relations-copy-join[:reverse]`
/// (Copy Join for the selected line; prints what was copied and puts the clipboard back) ·
/// `relations-insert-join` (Insert Join into the current SQL tab) · `relations-key-menu:<from>|<to>`
/// and `relations-key-menu:off` (that line's context menu items in a popover, since a menu can't
/// be snapshotted) · `relations-zoom:<percent>` · `relations-export:png|svg:<path>` (writes the
/// export to `<path>` instead of asking in the save panel) · `relations-state` (prints the focus,
/// options, tables, keys, collapsed groups, history, selection, and the last action).
@MainActor
enum RelationsDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        let document = RelationsWindows.latest
        switch name {
        case "relations":
            guard let tab = model.selectedTab else { return true }
            model.showSchemaRelations(argument, from: tab)
        case "relations-hops":
            document?.hops = Int(argument) ?? 1
        case "relations-columns":
            document?.allColumns = argument == "all"
        case "relations-focus":
            document?.recentre(on: argument)
        case "relations-back":
            document?.back()
        case "relations-forward":
            document?.forward()
        case "relations-expand":
            guard let document, let layout = layout(document, model: model) else { return true }
            if argument == "all" { document.expanded.formUnion(layout.groups.map(\.id)) } else { document.expanded.insert(argument) }
        case "relations-select":
            guard let document else { return true }
            document.selectedEdge = edge(argument, document, model: model)?.id
        case "relations-key-menu":
            guard let document else { return true }
            document.debugMenuEdge = argument == "off" ? nil : edge(argument, document, model: model)?.id
        case "relations-copy-join":
            guard let document, let relation = selected(document, model: model) else { log("relations-copy-join: nothing selected"); return true }
            let pasteboard = NSPasteboard.general
            let saved = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
            model.copyRelationJoin(relation, in: document, reverse: argument == "reverse")
            log("relations-copy-join: copied \(pasteboard.string(forType: .string) ?? "nothing")")
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            })
        case "relations-insert-join":
            guard let document, let relation = selected(document, model: model) else { log("relations-insert-join: nothing selected"); return true }
            model.insertRelationJoin(relation, in: document)
            log("relations-insert-join: \(document.lastAction ?? "nothing inserted") · tab text: \(model.relationsInsertTab(document)?.editor.text.replacingOccurrences(of: "\n", with: "⏎") ?? "no SQL tab")")
        case "relations-zoom":
            document?.zoom = (Double(argument) ?? 100) / 100
            document?.scrollRequest += 1
        case "relations-export":
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard let document, parts.count == 2, let layout = layout(document, model: model) else { log("relations-export: \(argument)?"); return true }
            let format: RelationsExport.Format = parts[0] == "svg" ? .svg : .png
            let scheme: ColorScheme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            let url = RelationsExport.save(layout, format: format, colorScheme: scheme, to: URL(fileURLWithPath: parts[1]))
            let size = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
            log("relations-export: \(parts[0]) \(url == nil ? "failed" : "wrote \(size) bytes")")
        case "relations-state":
            log("relations-state: \(state(model))")
        default:
            return false
        }
        return true
    }

    private static func layout(_ document: RelationsDocument, model: AppModel) -> SQLRelationsLayout? {
        model.relationsSchema(document).flatMap { document.layout(for: $0.schema, token: $0.token) }
    }

    /// The line from `<from>|<to>` (the first, by id).
    private static func edge(_ argument: String, _ document: RelationsDocument, model: AppModel) -> SQLRelationsLayout.Edge? {
        let parts = argument.components(separatedBy: "|")
        guard parts.count == 2 else { return nil }
        return layout(document, model: model)?.edges.first { $0.relation?.from == parts[0] && $0.relation?.to == parts[1] }
    }

    private static func selected(_ document: RelationsDocument, model: AppModel) -> SQLRelations.Relation? {
        guard let id = document.selectedEdge else { return nil }
        return layout(document, model: model)?.edges.first { $0.id == id }?.relation
    }

    private static func state(_ model: AppModel) -> String {
        guard let document = RelationsWindows.latest else { return "no diagram" }
        let window = NSApp.windows.first { $0.isVisible && $0.title == document.title }
        var parts = ["\(document.title) — \(document.subtitle)", "window \(window.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none")",
                     "hops \(document.hops)", document.allColumns ? "all columns" : "key columns", "zoom \(Int((document.zoom * 100).rounded()))%",
                     "history \(document.history.joined(separator: " > ")) at \(document.focus)"]
        if let layout = layout(document, model: model) {
            parts.append(layout.summary)
            parts.append("tables \(layout.boxes.map { "\($0.id)[\($0.node.side.rawValue) \($0.node.hop)\($0.node.isMissing ? " missing" : "")]" }.joined(separator: ", "))")
            parts.append("keys \(layout.edges.compactMap { $0.relation.map { "\($0.summary)\($0.isSelfReference ? " (loop)" : "")" } }.joined(separator: "; "))")
            parts.append("groups \(layout.groups.map { "\($0.id) \($0.title)" }.joined(separator: ", "))")
            if let id = document.selectedEdge, let relation = layout.edges.first(where: { $0.id == id })?.relation {
                parts.append("selected \(relation.summary) → \(model.relationJoin(relation, in: document) ?? "no join")")
            }
        } else {
            parts.append(model.relationsSchema(document) == nil ? "schema not loaded" : "no such table")
        }
        parts.append("last: \(document.lastAction ?? "none")")
        return parts.joined(separator: " · ")
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
