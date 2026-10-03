#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for the SQL values sheet (#145), for screenshots and scripted checks with
/// scratch data (see `DebugSteps`). Open the sheet with `run` (or `sql-run-all`) in an SQL tab
/// whose statement has placeholders, then:
/// `sql-param:<placeholder>=<type>[:<value>]` sets a row's type (text, integer, decimal,
/// boolean, null) and value as the sheet would; `<placeholder>` is `:name`, `?N`, or `?N@S`
/// (the Nth `?` of statement S in Run All); in values `\n` is a newline and `\c` a comma ·
/// `sql-params:run` and `sql-params:cancel` press the sheet's Run (or Run All) and Cancel ·
/// `sql-params:state` prints each row's type, value, and error, and the `@param` problems ·
/// `sql-history` prints the newest Run History entry's code.
@MainActor
enum SQLParameterDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "sql-param":
            guard let request = model.sqlParameters.request else {
                log("sql-param: no values sheet")
                return true
            }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else {
                log("sql-param: can't read \(argument)")
                return true
            }
            let spec = parts[1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let value = spec.count > 1 ? spec[1].replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\c", with: ",") : nil
            guard let type = SQLParameterType(word: spec[0]), request.form.set(parts[0], type: type, text: value) else {
                log("sql-param: can't set \(argument)")
                return true
            }
        case "sql-params":
            guard let request = model.sqlParameters.request else {
                log("sql-params: no values sheet")
                return true
            }
            switch argument {
            case "run":
                if !request.form.isValid { log("sql-params: not valid: \(state(request))") }
                model.confirmSQLParameters(request)
            case "cancel":
                model.cancelSQLParameters(request)
            default:
                log("sql-params: \(state(request))")
            }
        case "sql-history":
            log("sql-history: \(model.history.count) entries; newest: \(model.history.first.map { $0.code.replacingOccurrences(of: "\n", with: "\\n") } ?? "none")")
        default:
            return false
        }
        return true
    }

    private static func state(_ request: SQLParameterRequest) -> String {
        let rows = request.form.fields.map { field in
            let value = request.form.error(for: field).map { "invalid(\($0))" } ?? (try? request.form.value(of: field).get())?.display() ?? "?"
            return "\(field.parameter.placeholder)@\(field.parameter.statement.map { String($0 + 1) } ?? "-") \(field.type.word)=\(value)"
        }
        return "\(request.title) [\(rows.joined(separator: "; "))] problems=\(request.problems)"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
