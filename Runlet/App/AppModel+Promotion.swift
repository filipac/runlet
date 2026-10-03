import AppKit
import RunletCore
import UniformTypeIdentifiers

/// What Save as Artisan Command… and Save as Test… make from a snippet (#39).
enum PromotionKind: String, CaseIterable {
    case artisanCommand
    case test

    /// "Save as Artisan Command…"
    var commandTitle: String {
        switch self {
        case .artisanCommand: "Save as Artisan Command…"
        case .test: "Save as Test…"
        }
    }

    /// "an Artisan command"
    var noun: String {
        switch self {
        case .artisanCommand: "an Artisan command"
        case .test: "a test"
        }
    }
}

/// A file that Save as Artisan Command… or Save as Test… wrote. `PromotedFileSheet` shows it on
/// its window and offers to open it in the editor or reveal it in Finder.
struct PromotedFile: Identifiable {
    let id = UUID()
    /// The window the sheet belongs to.
    var windowId: UUID?
    var url: URL
    var kind: PromotionKind
    /// "Pest test", "PHPUnit test", or "Artisan command".
    var description: String
    /// The file relative to the project, e.g. "app/Console/Commands/RefundOrder.php".
    var relativePath: String
    var projectName: String?
    /// How to run it once reviewed, e.g. "php artisan app:refund-order".
    var nextStep: String
    /// The TODOs in the file.
    var notes: [String]
}

/// Promote a snippet (#39): the current tab's code (or selection), or a saved snippet, becomes
/// an Artisan command class or a Pest or PHPUnit test in the target's project folder.
/// `SnippetPromotion` generates the file; it is written only where the user chooses in a save
/// panel (which asks before replacing a file). Nothing runs: no Artisan, no tests, no PHP.
extension AppModel {
    // MARK: Availability

    /// Why `kind` isn't available for code on `target`, or nil when it is.
    func promotionUnavailableReason(_ kind: PromotionKind, target: TargetRef, language: TabLanguage, framework: String?) -> String? {
        if language == .sql { return "SQL can't become \(kind.noun). Switch the tab to PHP." }
        guard let root = projectRoot(for: target) else {
            switch target {
            case .sandbox:
                return "The sandbox has no project folder to save \(kind.noun) in. Use a local project, or a Docker or SSH profile with a local folder."
            case .local:
                return "This tab's project was removed."
            case .docker(let id):
                return "“\(library.dockerProfile(id)?.name ?? "This Docker profile")” has no local source folder. Set one in the Docker profile to save \(kind.noun) in the project."
            case .ssh(let id):
                return "“\(library.sshProfile(id)?.name ?? "This SSH profile")” has no local folder. Set the project's checkout on this Mac in the SSH profile to save \(kind.noun) in it."
            }
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return "\(root.path) doesn't exist." }
        if kind == .artisanCommand, commandFlavor(framework: framework, projectRoot: root) == nil {
            return "Artisan commands need a Laravel, Lumen, or Laravel Zero project" + (framework.flatMap(Self.projectPhrase).map { "; this is \($0)." } ?? ".")
        }
        return nil
    }

    func promotionUnavailableReason(_ kind: PromotionKind, for tab: TabModel?) -> String? {
        guard let tab else { return "Open a tab first." }
        return promotionUnavailableReason(kind, target: tab.target, language: tab.language, framework: framework(for: tab))
    }

    /// "a Symfony project" for a framework id, or nil.
    private static func projectPhrase(_ framework: String) -> String? {
        if framework.hasPrefix("custom:") { return "a project with its own .runlet driver" }
        switch framework {
        case "symfony": return "a Symfony project"
        case "wordpress": return "a WordPress site"
        case "composer": return "a Composer project"
        case "plain": return "a plain PHP project"
        default: return nil
        }
    }

    /// The framework a target last reported, from the current tab when it uses the target.
    func framework(for target: TargetRef) -> String? {
        if let tab = selectedTab, tab.target == target, let framework = framework(for: tab) { return framework }
        return targetFacts[target.stableKey]?.framework
    }

    /// The kind of console command for a framework id; a project not detected yet counts as
    /// Laravel when it has an `artisan` file.
    func commandFlavor(framework: String?, projectRoot: URL) -> SnippetPromotion.CommandFlavor? {
        if let framework { return SnippetPromotion.CommandFlavor(framework: framework) }
        return FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("artisan").path) ? .laravel : nil
    }

    /// The target a saved snippet is promoted into: its own, else the current tab's.
    func promotionTarget(for snippet: Snippet) -> TargetRef? {
        snippet.target ?? selectedTab?.target
    }

    func promotionUnavailableReason(_ kind: PromotionKind, snippet: Snippet) -> String? {
        guard let target = promotionTarget(for: snippet) else { return "Associate the snippet with a project, or open a tab on one." }
        return promotionUnavailableReason(kind, target: target, language: snippet.tabLanguage, framework: framework(for: target))
    }

    func promotionUnavailableReason(_ kind: PromotionKind, projectSnippet: ProjectSnippet, target: TargetRef) -> String? {
        promotionUnavailableReason(kind, target: target, language: projectSnippet.language, framework: framework(for: target))
    }

    // MARK: Promoting

    /// File ▸ Save as Artisan Command… / Save as Test…: the current tab's selection, or its
    /// code (a selection brings the tab's imports along).
    func promoteCurrentTab(_ kind: PromotionKind, destination: URL? = nil) {
        guard let tab = selectedTab else { return }
        let text = tab.editor.text
        let selection = tab.editor.selectedText.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let title = tab.fileURL != nil ? (tab.title as NSString).deletingPathExtension : tab.title
        promote(kind, code: selection ?? text, contextCode: selection == nil ? nil : text, title: title, description: nil,
                target: tab.target, language: tab.language, framework: framework(for: tab), destination: destination)
    }

    /// From the Snippets panel: a personal snippet, into its own target's project (else the
    /// current tab's).
    func promote(_ kind: PromotionKind, snippet: Snippet) {
        guard let target = promotionTarget(for: snippet) else { return }
        promote(kind, code: snippet.code, contextCode: nil, title: snippet.label, description: snippet.description,
                target: target, language: snippet.tabLanguage, framework: framework(for: target))
    }

    /// From the Snippets panel: a project snippet, into its project. Its metadata `@input`
    /// declarations come along (`personalCode`).
    func promote(_ kind: PromotionKind, projectSnippet: ProjectSnippet, target: TargetRef) {
        promote(kind, code: projectSnippet.personalCode, contextCode: nil, title: projectSnippet.label, description: projectSnippet.description,
                target: target, language: projectSnippet.language, framework: framework(for: target))
    }

    /// Generates the file and writes it where the user chooses in a save panel; `destination`
    /// (Debug steps only) skips the panel. Then shows `PromotedFileSheet`.
    func promote(_ kind: PromotionKind, code: String, contextCode: String?, title: String, description: String?,
                 target: TargetRef, language: TabLanguage, framework: String?, destination: URL? = nil) {
        let failureTitle = "Can't save \(kind.noun)"
        if let reason = promotionUnavailableReason(kind, target: target, language: language, framework: framework) {
            alert = AppAlert(title: failureTitle, message: reason)
            return
        }
        guard let root = projectRoot(for: target) else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "<?php" else {
            alert = AppAlert(title: failureTitle, message: "There's no code to save.")
            return
        }
        let layout = SnippetPromotion.ProjectLayout.read(projectRoot: root)
        let flavor = commandFlavor(framework: framework, projectRoot: root) ?? .laravel
        let style = layout.testStyle
        let source = SnippetPromotion.Source(code: code, contextCode: contextCode, title: title, description: description, strictTypes: strictTypes(for: target))

        let url: URL
        if let destination {
            url = destination
        } else {
            guard let chosen = choosePromotionFile(kind, root: root, layout: layout, flavor: flavor, source: source) else { return }
            url = chosen
        }

        let className = url.deletingPathExtension().lastPathComponent
        let directory = SnippetPromotion.relativeDirectory(of: url, in: root)
        let output: SnippetPromotion.Output
        let kindDescription: String
        let nextStep: String
        switch kind {
        case .artisanCommand:
            let namespace = directory.flatMap(layout.namespace(forDirectory:)) ?? (directory == flavor.directory ? flavor.defaultNamespace : nil)
            let name = SnippetPromotion.commandName(forClass: className, flavor: flavor)
            output = SnippetPromotion.artisanCommand(source, className: className, namespace: namespace, commandName: name, flavor: flavor)
            kindDescription = "Artisan command"
            nextStep = flavor == .laravel
                ? "Review it, then run it yourself with “php artisan \(name)”. Runlet didn't run anything."
                : "Review it, then run it yourself as the “\(name)” command of your application. Runlet didn't run anything."
        case .test:
            let namespace = style == .phpunit ? directory.flatMap(layout.namespace(forDirectory:)) : nil
            output = SnippetPromotion.test(source, style: style, className: className, namespace: namespace, baseClass: layout.testBaseClass)
            kindDescription = style == .pest ? "Pest test" : "PHPUnit test"
            nextStep = "Review it and add its assertions, then run it from the Tests group of the Commands pane. Runlet didn't run anything."
        }
        do {
            try Data(output.source.utf8).write(to: url, options: .atomic)
        } catch {
            alert = AppAlert(title: "Couldn't save \(url.lastPathComponent)", message: error.localizedDescription)
            return
        }
        promotedFile = PromotedFile(windowId: activeWindowId, url: url, kind: kind, description: kindDescription,
                                    relativePath: directory.map { $0.isEmpty ? url.lastPathComponent : $0 + "/" + url.lastPathComponent } ?? url.path,
                                    projectName: projectName(for: target), nextStep: nextStep, notes: output.notes)
    }

    /// The save panel: in the project's commands or feature-tests folder (the deepest one that
    /// exists), with the file name filled in. Names that can't work are refused in the panel.
    private func choosePromotionFile(_ kind: PromotionKind, root: URL, layout: SnippetPromotion.ProjectLayout, flavor: SnippetPromotion.CommandFlavor, source: SnippetPromotion.Source) -> URL? {
        let folder = kind == .artisanCommand ? flavor.directory : "tests/Feature"
        var start = root.appendingPathComponent(folder, isDirectory: true)
        while start.path.count > root.path.count, !FileManager.default.fileExists(atPath: start.path) {
            start.deleteLastPathComponent()
        }
        let panel = NSSavePanel()
        panel.directoryURL = start
        panel.nameFieldStringValue = SnippetPromotion.className(fromTitle: source.title, suffix: kind == .test ? "Test" : "") + ".php"
        panel.allowedContentTypes = [UTType(filenameExtension: "php") ?? .sourceCode]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = kind == .artisanCommand ? "Save as Artisan Command" : "Save as Test"
        switch kind {
        case .artisanCommand:
            panel.message = "Save the snippet as an Artisan command class. \(flavor == .laravel ? "Laravel" : "Laravel Zero") finds commands in \(folder). The file name is the class name. Runlet runs nothing."
        case .test:
            panel.message = "Save the snippet as a \(layout.usesPest ? "Pest" : "PHPUnit") test. The file name must end in Test.php. Runlet runs nothing."
        }
        panel.prompt = "Save"
        let validator = PromotionNameValidator(kind: kind, style: layout.testStyle, source: source)
        panel.delegate = validator
        let response = withExtendedLifetime(validator) { panel.runModal() }
        guard response == .OK else { return nil }
        return panel.url
    }

    /// Why a file name can't hold the generated class or test, or nil when it can.
    static func promotionNameProblem(_ url: URL, kind: PromotionKind, style: SnippetPromotion.TestStyle, source: SnippetPromotion.Source) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension.lowercased() == "php" else { return "The file needs the .php extension." }
        if kind == .test, !name.hasSuffix("Test") {
            return "Pest and PHPUnit run files whose names end in Test.php, like \(SnippetPromotion.className(fromTitle: name, suffix: "Test")).php."
        }
        if kind == .test, style == .pest { return nil }
        guard SnippetPromotion.isValidClassName(name) else {
            return "“\(name)” can't be a PHP class name. Use letters, digits, and underscores, starting with a letter, like \(SnippetPromotion.className(fromTitle: name, suffix: kind == .test ? "Test" : "")).php."
        }
        if let conflict = SnippetPromotion.conflictingImport(className: name, code: source.code, contextCode: source.contextCode) {
            return "The snippet's import “\(conflict)” already uses the name \(name). Choose another file name."
        }
        return nil
    }
}

/// Refuses file names that can't hold the generated class, keeping the save panel open.
private final class PromotionNameValidator: NSObject, NSOpenSavePanelDelegate {
    let kind: PromotionKind
    let style: SnippetPromotion.TestStyle
    let source: SnippetPromotion.Source

    init(kind: PromotionKind, style: SnippetPromotion.TestStyle, source: SnippetPromotion.Source) {
        self.kind = kind
        self.style = style
        self.source = source
    }

    func panel(_ sender: Any, validate url: URL) throws {
        if let problem = AppModel.promotionNameProblem(url, kind: kind, style: style, source: source) {
            throw NSError(domain: "Runlet", code: 1, userInfo: [NSLocalizedDescriptionKey: problem])
        }
    }
}
