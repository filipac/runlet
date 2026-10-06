import SwiftUI

// MARK: - Keeping an inspector pane's list still (#320)
//
// SwiftUI's `List` on macOS measures only the rows it has drawn. It estimates every other row at
// about 28 points, whatever the row holds (the table's `rowHeight` is fixed, and neither
// `defaultMinListRowHeight` nor fixed row frames change the estimate), so a list of taller rows
// grows as it draws them: the Commands list from about 4,100 to 6,200 points, History from 3,600
// to 8,000. Whenever SwiftUI measures rows again, or the list's frame changes, its height, its
// scroller, and the rows above the visible ones move. A pane's list must therefore be left alone
// unless its own rows change:
//
// - **Its frame.** What sits above and below the list keeps its height when other state changes:
//   a selection's buttons are always there (disabled without one), and text that changes with
//   time reserves its lines.
// - **Its content.** `StableInspectorList(value) { value in List { … } }` evaluates the list
//   only when `value` changes, so the pane's header, focus, search field, and the window's runs,
//   tabs, and settings don't reach it. Everything the list shows goes into `value`; the content
//   may also use bindings to the pane's state, `InspectorActions`, and observable models (their
//   own changes still update it).
// - **Its rows.** A row takes values, never closures or models to read from: SwiftUI can't
//   compare a closure, so a row with one is drawn again on every render of its pane. What rows do
//   goes through `InspectorActions`, which they compare by identity; what several rows show (a
//   setting, a target's framework) is read once by the pane and passed down.
// - **Its identity.** Rows have stable ids, and nothing gives the list an `.id(...)` that changes.
// - **Its selection.** `List(selection: $selection.ignoringEqualWrites)`: the list sets its
//   selection again, to the same value, from inside its own updates, and that write would update
//   every view that reads the selection once more.
//
// The Debug step `inspector-scroll-state` measures a pane's list (`InspectorScrollDebugSteps`),
// and `scripts/inspector-scroll-check.py` runs the checks for every pane.

/// Evaluates `content` only when `value` changes (#320). A pane wraps its `List` in one, with
/// everything the list shows in `value`, so the rest of the pane re-rendering doesn't make
/// SwiftUI update the list's rows (see "Keeping an inspector pane's list still" above).
///
/// The content must not show anything else of the pane's (its properties or `@State`): the list
/// isn't evaluated again when only those change. It may use `value`, bindings, an
/// `InspectorActions` box, and observable models.
struct StableInspectorList<Value: Equatable & Sendable, Content: View>: View {
    let value: Value
    let content: (Value) -> Content

    init(_ value: Value, @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value
        self.content = content
    }

    var body: some View {
        EquatableView(content: Contents(value: value, content: content))
    }

    private struct Contents: View, Equatable {
        let value: Value
        let content: (Value) -> Content

        nonisolated static func == (lhs: Contents, rhs: Contents) -> Bool { lhs.value == rhs.value }

        var body: some View { content(value) }
    }
}

/// What a pane's rows (and its list's context menu) do, in a box rows compare by identity
/// (#320), so a row needs no closure. The pane keeps it in its `@State` and hands it its
/// current code on each render with `handle(_:)`, so an action always uses the pane's
/// current tab and state.
@MainActor
final class InspectorActions<Action> {
    private var handler: (Action) -> Void = { _ in }

    /// Sets what the actions do from now on; returns the box, for the pane's `body`.
    @discardableResult
    func handle(_ handler: @escaping (Action) -> Void) -> InspectorActions<Action> {
        self.handler = handler
        return self
    }

    func callAsFunction(_ action: Action) {
        handler(action)
    }
}

extension Binding where Value: Equatable {
    /// The same binding, without writes of the value it already has (#320). SwiftUI's `List` on
    /// macOS calls its selection binding's setter from inside its own update (its outline view's
    /// selection-changed callback), also with the selection it already has; the write would
    /// update every view that reads the selection once more.
    var ignoringEqualWrites: Binding<Value> {
        Binding(get: { wrappedValue }, set: { newValue in
            if newValue != wrappedValue { wrappedValue = newValue }
        })
    }
}
