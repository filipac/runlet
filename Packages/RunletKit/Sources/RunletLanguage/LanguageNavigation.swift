import Foundation

// Navigation requests (#22): Go to Definition, Find References, inlay hints, code actions, and
// folding ranges. Positions are LSP coordinates here; `NavigationResolver`, `ScratchEditPlanner`,
// and `InlayHintPlacement` map them to the editor through the hidden lines.

/// What PHPantom offers beyond completion, read from its `initialize` result. Runlet asks for a
/// feature only when the server advertises it.
public enum LanguageFeature: String, Sendable, CaseIterable {
    case definition, references, inlayHints, codeActions, foldingRanges

    /// The server capability that advertises the feature.
    public var capabilityKey: String {
        switch self {
        case .definition: "definitionProvider"
        case .references: "referencesProvider"
        case .inlayHints: "inlayHintProvider"
        case .codeActions: "codeActionProvider"
        case .foldingRanges: "foldingRangeProvider"
        }
    }
}

public enum LanguageNavigation {
    /// Code action kinds Runlet lists (`codeActionLiteralSupport`).
    static let codeActionKinds = ["", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source", "source.organizeImports"]

    /// Whether `capabilities` (an `initialize` result's `capabilities`) advertise `feature`: a
    /// provider that is `true` or an options object; `false`, null, or absent is not.
    public static func supports(_ feature: LanguageFeature, in capabilities: JSONValue) -> Bool {
        switch capabilities[feature.capabilityKey] {
        case .bool(let value): value
        case .object: true
        default: false
        }
    }

    /// Whether code actions can be listed before their edits are computed (`codeAction/resolve`).
    public static func resolvesCodeActions(in capabilities: JSONValue) -> Bool {
        if case .bool(true) = capabilities["codeActionProvider"]?["resolveProvider"] { return true }
        return false
    }
}

/// A place in a document: `Location`, or a `LocationLink`'s target selection.
public struct LSPLocation: Sendable, Hashable {
    public var uri: String
    public var range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }

    /// `Location`, `Location[]`, `LocationLink[]`, or null (an empty list).
    public static func parseList(_ value: JSONValue) -> [LSPLocation] {
        let items = value.arrayValue ?? (value == .null ? [] : [value])
        return items.compactMap { item in
            if let uri = item["targetUri"]?.stringValue,
               let range = (try? item["targetSelectionRange"]?.decode(LSPRange.self)) ?? (try? item["targetRange"]?.decode(LSPRange.self)) {
                return LSPLocation(uri: uri, range: range)
            }
            guard let uri = item["uri"]?.stringValue, let range = try? item["range"]?.decode(LSPRange.self) else { return nil }
            return LSPLocation(uri: uri, range: range)
        }
    }
}

/// An inlay hint: a parameter name before an argument, or an inferred type.
public struct InlayHint: Sendable, Hashable {
    public enum Kind: Int, Sendable, Hashable {
        case type = 1
        case parameter = 2
    }

    public var position: LSPPosition
    public var label: String
    public var kind: Kind?
    public var tooltip: String?
    public var paddingLeft: Bool
    public var paddingRight: Bool

    public init(position: LSPPosition, label: String, kind: Kind?, tooltip: String? = nil, paddingLeft: Bool = false, paddingRight: Bool = false) {
        self.position = position
        self.label = label
        self.kind = kind
        self.tooltip = tooltip
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
    }

    static func parse(_ value: JSONValue) -> InlayHint? {
        guard let position = try? value["position"]?.decode(LSPPosition.self) else { return nil }
        let label: String
        switch value["label"] {
        case .string(let text): label = text
        case .array(let parts): label = parts.compactMap { $0["value"]?.stringValue }.joined()
        default: return nil
        }
        var padding = (left: false, right: false)
        if case .bool(true) = value["paddingLeft"] { padding.left = true }
        if case .bool(true) = value["paddingRight"] { padding.right = true }
        return InlayHint(position: position, label: label, kind: value["kind"]?.intValue.flatMap(Kind.init(rawValue:)),
                         tooltip: markupText(value["tooltip"]), paddingLeft: padding.left, paddingRight: padding.right)
    }
}

/// The text changes of a code action. Runlet applies them to the tab's own text only.
public struct LSPWorkspaceEdit: Sendable, Hashable {
    /// Edits by document URI (`changes`, or the text edits of `documentChanges`).
    public var changes: [String: [LSPTextEdit]]
    /// Files the edit would create, rename, or delete (`documentChanges` resource operations).
    public var resourceOperations: [String]

    public init(changes: [String: [LSPTextEdit]], resourceOperations: [String] = []) {
        self.changes = changes
        self.resourceOperations = resourceOperations
    }

    static func parse(_ value: JSONValue?) -> LSPWorkspaceEdit? {
        guard let value, case .object = value else { return nil }
        var changes: [String: [LSPTextEdit]] = [:]
        var operations: [String] = []
        if case .object(let byURI) = value["changes"] {
            for (uri, edits) in byURI {
                changes[uri, default: []] += (try? edits.decode([LSPTextEdit].self)) ?? []
            }
        }
        for change in value["documentChanges"]?.arrayValue ?? [] {
            if let kind = change["kind"]?.stringValue {
                operations.append("\(kind) \(change["uri"]?.stringValue ?? change["newUri"]?.stringValue ?? "")")
            } else if let uri = change["textDocument"]?["uri"]?.stringValue {
                // Annotated edits decode as plain ones (their annotation is ignored).
                changes[uri, default: []] += (try? change["edits"]?.decode([LSPTextEdit].self)) ?? []
            }
        }
        return LSPWorkspaceEdit(changes: changes, resourceOperations: operations)
    }
}

/// A quick fix or refactoring the server offers for a range.
public struct LSPCodeAction: Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var kind: String?
    public var isPreferred: Bool
    /// Why the server shows the action but won't run it (`disabled.reason`).
    public var disabledReason: String?
    public var edit: LSPWorkspaceEdit?
    /// The action also (or only) runs a server command, which Runlet never executes.
    public var hasCommand: Bool
    /// The action as received, sent back for `codeAction/resolve`.
    public var raw: JSONValue

    /// The edit is computed on request (`codeAction/resolve`).
    public var needsResolve: Bool { edit == nil && raw["data"] != nil }

    public var isQuickFix: Bool { kind?.hasPrefix("quickfix") ?? false }

    static func parse(_ value: JSONValue, index: Int) -> LSPCodeAction? {
        guard let title = value["title"]?.stringValue else { return nil }
        // A bare `Command` (no kind, no edit) only runs something on the server: not offered.
        if case .string = value["command"] { return nil }
        var preferred = false
        if case .bool(true) = value["isPreferred"] { preferred = true }
        return LSPCodeAction(id: index, title: title, kind: value["kind"]?.stringValue, isPreferred: preferred,
                             disabledReason: value["disabled"]?["reason"]?.stringValue, edit: LSPWorkspaceEdit.parse(value["edit"]),
                             hasCommand: value["command"] != nil, raw: value)
    }

    /// Quick fixes first, the preferred ones before the rest, then the server's order.
    public static func ordered(_ actions: [LSPCodeAction]) -> [LSPCodeAction] {
        actions.enumerated().sorted { lhs, rhs in
            let left = (lhs.element.isQuickFix ? 0 : 1, lhs.element.isPreferred ? 0 : 1, lhs.offset)
            let right = (rhs.element.isQuickFix ? 0 : 1, rhs.element.isPreferred ? 0 : 1, rhs.offset)
            return left < right
        }.map(\.element)
    }
}

/// A foldable range of lines (`textDocument/foldingRange`).
public struct LSPFoldingRange: Sendable, Hashable {
    public var startLine: Int
    public var endLine: Int
    /// "comment", "imports", "region", or nil.
    public var kind: String?

    public init(startLine: Int, endLine: Int, kind: String? = nil) {
        self.startLine = startLine
        self.endLine = endLine
        self.kind = kind
    }

    static func parse(_ value: JSONValue) -> LSPFoldingRange? {
        guard let start = value["startLine"]?.intValue, let end = value["endLine"]?.intValue, end > start else { return nil }
        return LSPFoldingRange(startLine: start, endLine: end, kind: value["kind"]?.stringValue)
    }
}

extension LanguageServerSession {
    /// Whether the running server advertised `feature` (false until it is ready).
    public func supports(_ feature: LanguageFeature) -> Bool {
        LanguageNavigation.supports(feature, in: serverCapabilities)
    }

    public func definition(uri: String, position: LSPPosition) async throws -> [LSPLocation] {
        let connection = try await readyConnection()
        guard supports(.definition) else { return [] }
        let result = try await connection.request("textDocument/definition", .object(Self.positionParams(uri: uri, position: position)), timeout: .seconds(10))
        return LSPLocation.parseList(result)
    }

    public func references(uri: String, position: LSPPosition, includeDeclaration: Bool = true) async throws -> [LSPLocation] {
        let connection = try await readyConnection()
        guard supports(.references) else { return [] }
        var params = Self.positionParams(uri: uri, position: position)
        params["context"] = .object(["includeDeclaration": .bool(includeDeclaration)])
        let result = try await connection.request("textDocument/references", .object(params), timeout: .seconds(20))
        return LSPLocation.parseList(result)
    }

    public func inlayHints(uri: String, range: LSPRange) async throws -> [InlayHint] {
        let connection = try await readyConnection()
        guard supports(.inlayHints) else { return [] }
        let params: JSONValue = .object(["textDocument": .object(["uri": .string(uri)]), "range": try JSONValue.from(range)])
        let result = try await connection.request("textDocument/inlayHint", params, timeout: .seconds(5))
        return (result.arrayValue ?? []).compactMap(InlayHint.parse)
    }

    /// Actions for `range`, given the diagnostics shown there (in LSP coordinates).
    public func codeActions(uri: String, range: LSPRange, diagnostics: [LSPDiagnostic]) async throws -> [LSPCodeAction] {
        let connection = try await readyConnection()
        guard supports(.codeActions) else { return [] }
        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(uri)]),
            "range": try JSONValue.from(range),
            "context": .object(["diagnostics": try JSONValue.from(diagnostics), "triggerKind": .number(1)]),
        ])
        let result = try await connection.request("textDocument/codeAction", params, timeout: .seconds(10))
        return (result.arrayValue ?? []).enumerated().compactMap { LSPCodeAction.parse($1, index: $0) }
    }

    /// Computes a listed action's edit. An action that already has one is returned as is.
    public func resolve(_ action: LSPCodeAction) async throws -> LSPCodeAction {
        guard action.needsResolve, LanguageNavigation.resolvesCodeActions(in: serverCapabilities) else { return action }
        let connection = try await readyConnection()
        let result = try await connection.request("codeAction/resolve", action.raw, timeout: .seconds(10))
        return LSPCodeAction.parse(result, index: action.id) ?? action
    }

    public func foldingRanges(uri: String) async throws -> [LSPFoldingRange] {
        let connection = try await readyConnection()
        guard supports(.foldingRanges) else { return [] }
        let result = try await connection.request("textDocument/foldingRange", .object(["textDocument": .object(["uri": .string(uri)])]), timeout: .seconds(5))
        return (result.arrayValue ?? []).compactMap(LSPFoldingRange.parse)
    }
}
