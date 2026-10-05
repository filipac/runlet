#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for Values | Object (#307), for screenshots and scripted checks with
/// scratch data (see `DebugSteps`): `model-display:values|object` switches the current tab as
/// its cards' switch does, `result-model-display:values|object` switches the latest result window
/// (after `result-window`), and `model-state` prints the current tab's choice and, for its last
/// result or dump that holds models, both trees' titles and rows, and the Table's rows and
/// columns in each mode.
@MainActor
enum ModelValuesDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "model-display":
            guard let tab = model.selectedTab, let display = ModelDisplay(rawValue: argument) else {
                log("model-display: no tab or unknown display \(argument)")
                return true
            }
            model.setModelDisplay(display, for: tab)
            log("model-display: \(tab.shownModelDisplay.rawValue)")
        case "result-model-display":
            // The latest result window's own Values | Object switch.
            guard let document = ResultWindows.latest, document.modelTables != nil, let display = ModelDisplay(rawValue: argument) else {
                log("result-model-display: no result window with models")
                return true
            }
            document.setModelDisplay(display)
        case "model-state":
            log("model-state: \(state(model))")
        default:
            return false
        }
        return true
    }

    private static func state(_ model: AppModel) -> String {
        guard let tab = model.selectedTab else { return "no tab" }
        let trees = tab.output.compactMap { item -> (ValueNode, ValueNode)? in
            switch item {
            case .result(_, let result): result.value.flatMap { value in result.modelValues.map { (value, $0) } }
            case .dump(_, let dump, _): dump.modelValues.map { (dump.value, $0) }
            default: nil
            }
        }
        var text = "display=\(tab.shownModelDisplay.rawValue) saved=\(tab.modelDisplay?.rawValue ?? "settings") withModels=\(trees.count)"
        guard let (object, values) = trees.last else { return text }
        func table(_ node: ValueNode) -> String {
            ValueTable.make(from: node).map { "\($0.rows.count)x\($0.columns.count)+\($0.omittedRows)" } ?? "none"
        }
        text += " values=\"\(values.inlineSummary)\" valuesRows=\(values.entries?.count ?? 0) valuesOmitted=\(values.truncation.map { "\($0.reason):\($0.omitted)" } ?? "none")"
        text += " valuesTable=\(table(values)) objectTable=\(table(object))"
        if let first = values.entries?.first?.value, first.model != nil {
            text += " first=\"\(first.compactSummary())\""
        }
        return text
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
