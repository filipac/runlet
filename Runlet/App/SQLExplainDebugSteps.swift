#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for Explain Statement (#147), for screenshots and scripted checks with
/// scratch data (see `DebugSteps`):
/// `sql-explain` (Explain Statement in the current SQL tab, waitable with `wait-run`) and
/// `sql-explain:analyze` (Explain Analyze; a statement that can write asks first, and
/// production asks with its sheet) · `analyze-confirm:yes|no` answers Explain Analyze's
/// question as its buttons do · `sql-plan:raw|tree` switches the output's plan cards between
/// Raw and Plan, `sql-plan:collapse:<step>` collapses a step (its number in the plan, from 0)
/// and `sql-plan:expand` expands them all · `sql-plan:state` prints the current tab's last
/// plan: its steps, full scans, and the pending question.
@MainActor
enum SQLExplainDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "sql-explain":
            guard let tab = model.selectedTab else { return true }
            DebugRunTiming.start(tab)
            model.explainSQL(tab, mode: argument == "analyze" ? .analyze : .plan)
        case "analyze-confirm":
            log("analyze-confirm: \(model.sqlExplainUI.pendingAnalyze.map { "\($0.title) | \($0.message)" } ?? "no question")")
            model.answerAnalyzeConfirmation(argument == "yes")
        case "sql-plan":
            if argument == "state" {
                log("sql-plan: \(state(model))")
            } else {
                NotificationCenter.default.post(name: .debugSQLPlan, object: argument)
            }
        default:
            return false
        }
        return true
    }

    private static func state(_ model: AppModel) -> String {
        let question = model.sqlExplainUI.pendingAnalyze.map { " question=\($0.title)" } ?? ""
        guard let tab = model.selectedTab else { return "no tab" + question }
        let plans = tab.output.compactMap { item -> SQLPlanInfo? in
            if case .sqlPlan(_, let info) = item { return info }
            return nil
        }
        guard let info = plans.last else { return "no plan" + question }
        let steps = info.plan?.nodes.map { String(repeating: ">", count: $0.depth) + $0.title + ($0.fullScan ? " [full scan]" : "") }.joined(separator: " | ") ?? "unparsed: \(info.parseError ?? "")"
        return "\(info.isAnalyze ? "analyze" : "plan") \(info.dialect ?? "?") \(info.plan?.summary ?? "") rolledBack=\(info.rolledBack == true) steps=[\(steps)]\(question)"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
