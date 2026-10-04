import AppKit
import RunletCore
import RunletLanguage

/// PHPantom navigation (#22): what the editor needs from the app to open definitions.
extension AppModel {
    /// Why Go to Definition, Find References, and Show Code Actions can't act on `tab`.
    func navigationDisabledReason(for tab: TabModel?) -> String? {
        guard let tab else { return "No tab is open." }
        guard tab.language == .php else { return "Navigation works in PHP tabs." }
        guard settings.languageServiceEnabled else { return "The language service is off in Settings." }
        guard tab.editorIfLoaded?.navigation.isAvailable == true else { return "PHPantom isn't running for this tab." }
        return nil
    }

    /// Connects the tab's editor to the external editor and its target's path mapping.
    func configureNavigation(for tab: TabModel) {
        tab.editor.navigation.host = TabNavigationHost(model: self, tab: tab)
    }
}

/// Opens what the tab's editor finds: project files in the external editor, at their line.
@MainActor
final class TabNavigationHost: EditorNavigationHost {
    private weak var model: AppModel?
    private weak var tab: TabModel?

    init(model: AppModel, tab: TabModel) {
        self.model = model
        self.tab = tab
    }

    func navigationEnvironment() -> EditorNavigationEnvironment {
        guard let model, let tab else { return EditorNavigationEnvironment() }
        // Without an editor, project files are peeked (Reveal in Finder is in the peek).
        let name: String? = model.settings.externalEditor == .none ? nil : model.externalEditorName
        return EditorNavigationEnvironment(pathMapping: model.editorPathMapping(for: tab), editorName: name)
    }

    func openInExternalEditor(path: String, line: Int) {
        model?.openInExternalEditor(path: path, line: line)
    }

    func revealInFinder(path: String) {
        model?.revealInFinder(path: path)
    }
}
