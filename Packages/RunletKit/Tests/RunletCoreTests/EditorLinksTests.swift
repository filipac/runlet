import Foundation
import Testing
@testable import RunletCore

struct EditorLinksTests {
    // MARK: URLs

    @Test func phpStormURL() {
        let url = EditorLinks.url(for: .phpstorm, path: "/Users/dev/My App/app/User.php", line: 42)
        #expect(url?.absoluteString == "phpstorm://open?file=/Users/dev/My%20App/app/User.php&line=42")
        #expect(EditorLinks.url(for: .phpstorm, path: "/a.php", line: nil)?.absoluteString == "phpstorm://open?file=/a.php")
    }

    @Test func fileSchemeURLsForVSCodeCursorAndZed() {
        #expect(EditorLinks.url(for: .vscode, path: "/Users/dev/app/a.php", line: 7)?.absoluteString == "vscode://file/Users/dev/app/a.php:7")
        #expect(EditorLinks.url(for: .vscode, scheme: "vscode-insiders", path: "/x/a b.php", line: 3)?.absoluteString == "vscode-insiders://file/x/a%20b.php:3")
        #expect(EditorLinks.url(for: .cursor, path: "/x/a.php", line: 1)?.absoluteString == "cursor://file/x/a.php:1")
        #expect(EditorLinks.url(for: .zed, path: "/x/a.php", line: 12)?.absoluteString == "zed://file/x/a.php:12")
        #expect(EditorLinks.url(for: .zed, path: "/x/project", line: nil)?.absoluteString == "zed://file/x/project")
    }

    @Test func openURLSchemesForSublimeAndTextMate() {
        #expect(EditorLinks.url(for: .sublime, path: "/x/a.php", line: 9)?.absoluteString == "subl://open?url=file:///x/a.php&line=9")
        #expect(EditorLinks.url(for: .textmate, path: "/x/a&b.php", line: 2)?.absoluteString == "txmt://open?url=file:///x/a%26b.php&line=2")
    }

    @Test func pathsAreFullyPercentEncoded() {
        // Characters with meaning in URLs and non-ASCII names stay inside the path value.
        let url = EditorLinks.url(for: .vscode, path: "/x/ä#?:%.php", line: 5)
        #expect(url?.absoluteString == "vscode://file/x/%C3%A4%23%3F%3A%25.php:5")
        #expect(EditorLinks.url(for: .none, path: "/a", line: 1) == nil)
        #expect(EditorLinks.url(for: .custom, path: "/a", line: 1) == nil)
        // Line 0 or negative is treated as "no line".
        #expect(EditorLinks.url(for: .zed, path: "/a.php", line: 0)?.absoluteString == "zed://file/a.php")
    }

    @Test func cliArgumentsPerEditor() {
        #expect(EditorLinks.cliArguments(for: .phpstorm, path: "/a.php", line: 3) == ["--line", "3", "/a.php"])
        #expect(EditorLinks.cliArguments(for: .vscode, path: "/a b.php", line: 3) == ["--goto", "/a b.php:3"])
        #expect(EditorLinks.cliArguments(for: .cursor, path: "/a.php", line: 3) == ["--goto", "/a.php:3"])
        #expect(EditorLinks.cliArguments(for: .zed, path: "/a.php", line: 3) == ["/a.php:3"])
        #expect(EditorLinks.cliArguments(for: .sublime, path: "/a.php", line: 3) == ["/a.php:3"])
        #expect(EditorLinks.cliArguments(for: .textmate, path: "/a.php", line: 3) == ["-l", "3", "/a.php"])
        #expect(EditorLinks.cliArguments(for: .vscode, path: "/project", line: nil) == ["/project"])
    }

    @Test func everyEditorHasKnownApplications() {
        for editor in ExternalEditor.allCases where editor != .none && editor != .custom {
            #expect(!editor.applications.isEmpty, "\(editor)")
        }
        #expect(ExternalEditor.vscode.applications.map(\.urlScheme).contains("vscode-insiders"))
    }

    // MARK: Custom commands

    @Test func customTemplateBecomesArgumentArray() throws {
        let args = try EditorLinks.customCommand("code --goto {file}:{line}", path: "/Users/dev/My App/a.php", line: 12)
        #expect(args == ["code", "--goto", "/Users/dev/My App/a.php:12"])
    }

    @Test func customTemplateWithoutLine() throws {
        #expect(try EditorLinks.customCommand("code --goto {file}:{line}", path: "/p", line: nil) == ["code", "--goto", "/p"])
        #expect(try EditorLinks.customCommand("mate -l {line} {file}", path: "/p", line: nil) == ["mate", "-l", "1", "/p"])
    }

    @Test func customTemplateAppendsFileWhenMissing() throws {
        #expect(try EditorLinks.customCommand("/usr/local/bin/nova", path: "/p/a.php", line: 4) == ["/usr/local/bin/nova", "/p/a.php"])
    }

    @Test func shellMetacharactersAreNeverInterpreted() throws {
        let path = "/tmp/$(rm -rf ~); `x` && y | z > w.php"
        let args = try EditorLinks.customCommand("editor {file}", path: path, line: 1)
        #expect(args == ["editor", path])
        let literal = try EditorLinks.customCommand("editor $HOME *.php ; echo", path: "/p", line: 1)
        #expect(literal == ["editor", "$HOME", "*.php", ";", "echo", "/p"])
    }

    @Test func quotingRules() throws {
        #expect(try EditorLinks.splitArguments(#"  "/Applications/My Editor.app/bin/ed"  --line={line} '{file}' "#) == ["/Applications/My Editor.app/bin/ed", "--line={line}", "{file}"])
        #expect(try EditorLinks.splitArguments(#"a\ b "c \"d\" \x" 'e\f'"#) == ["a b", #"c "d" \x"#, #"e\f"#])
        #expect(try EditorLinks.splitArguments(#"a "" ''"#) == ["a", "", ""])
        #expect(throws: EditorLinks.CommandError.unterminatedQuote) { try EditorLinks.splitArguments(#"a "b"#) }
        #expect(throws: EditorLinks.CommandError.unterminatedQuote) { try EditorLinks.splitArguments("a 'b") }
        #expect(throws: EditorLinks.CommandError.empty) { try EditorLinks.customCommand("   ", path: "/p", line: 1) }
    }

    // MARK: Path mapping

    @Test func hostPathsPassThrough() {
        #expect(EditorPathMapping.host.resolve("/Users/dev/app/a.php") == .mapped("/Users/dev/app/a.php"))
        #expect(EditorPathMapping.host.resolve("/Users/dev/app/../lib/./a.php") == .mapped("/Users/dev/lib/a.php"))
        #expect(EditorPathMapping.host.resolve("snippet").path == nil)
    }

    @Test func containerPathsMapThroughLocalSource() {
        let mapping = EditorPathMapping.container(root: "/var/www/html/", hostRoot: "/Users/dev/shop")
        #expect(mapping.resolve("/var/www/html/app/Models/User.php") == .mapped("/Users/dev/shop/app/Models/User.php"))
        #expect(mapping.resolve("/var/www/html") == .mapped("/Users/dev/shop"))
        // A sibling directory that only shares the prefix is not inside the root.
        #expect(mapping.resolve("/var/www/html2/a.php").path == nil)
        let outside = mapping.resolve("/usr/local/lib/php/x.php")
        #expect(outside.path == nil)
        #expect(outside.reason?.contains("outside the mapped directory /var/www/html") == true)
    }

    @Test func containerPathsWithoutLocalSourceExplainWhy() {
        let mapping = EditorPathMapping.container(root: "/var/www/html", hostRoot: nil)
        let resolution = mapping.resolve("/var/www/html/a.php")
        #expect(resolution.path == nil)
        #expect(resolution.reason?.contains("local source folder") == true)
        #expect(EditorPathMapping.container(root: "/app", hostRoot: "  ").resolve("/app/a.php").path == nil)
    }

    @Test func mappingFollowsTheRunSnapshot() {
        let local = TargetSnapshot(kind: .local, label: "l", targetId: "x", workingDirectory: "/Users/dev/app", phpExecutable: "php")
        #expect(EditorPathMapping.forSnapshot(local, dockerLocalSource: "/ignored") == .host)
        let sandboxLocal = TargetSnapshot(kind: .sandboxLocal, label: "s", targetId: "sandbox", workingDirectory: "/Users/dev/Library/Sandbox", phpExecutable: "php")
        #expect(EditorPathMapping.forSnapshot(sandboxLocal, dockerLocalSource: nil).resolve("/Users/dev/Library/Sandbox/app/A.php") == .mapped("/Users/dev/Library/Sandbox/app/A.php"))
        let sandboxDocker = TargetSnapshot(kind: .sandboxDocker, label: "s", targetId: "sandbox", workingDirectory: "/sandbox", phpExecutable: "php", hostMountDirectory: "/Users/dev/Library/Sandbox")
        #expect(EditorPathMapping.forSnapshot(sandboxDocker, dockerLocalSource: nil).resolve("/sandbox/vendor/autoload.php") == .mapped("/Users/dev/Library/Sandbox/vendor/autoload.php"))
        let docker = TargetSnapshot(kind: .docker, label: "d", targetId: "p", workingDirectory: "/var/www/html", phpExecutable: "php", containerId: "abc")
        #expect(EditorPathMapping.forSnapshot(docker, dockerLocalSource: "/Users/dev/shop").resolve("/var/www/html/routes/web.php") == .mapped("/Users/dev/shop/routes/web.php"))
        #expect(EditorPathMapping.forSnapshot(docker, dockerLocalSource: nil).resolve("/var/www/html/routes/web.php").path == nil)
    }

    // MARK: Settings

    @Test func editorSettingsDecodeTolerantly() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 14}"#.utf8))
        #expect(old.editorFontName == nil)
        #expect(old.lineHeight == 1.15)
        #expect(old.ligatures == false)
        #expect(old.softWrap == false)
        #expect(old.externalEditor == .none)
        #expect(old.externalEditorCommand == nil)

        let custom = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"editorFontName": "JetBrains Mono", "lineHeight": 9, "ligatures": true, "softWrap": true, "externalEditor": "zed", "externalEditorCommand": "zed {file}:{line}"}"#.utf8))
        #expect(custom.editorFontName == "JetBrains Mono")
        #expect(custom.lineHeight == 2.0, "clamped to the supported range")
        #expect(custom.ligatures && custom.softWrap)
        #expect(custom.externalEditor == .zed)
        #expect(custom.externalEditorCommand == "zed {file}:{line}")

        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"externalEditor": "emacs", "editorFontName": ""}"#.utf8))
        #expect(unknown.externalEditor == .none)
        #expect(unknown.editorFontName == nil)

        var settings = AppSettings()
        settings.editorFontName = "Fira Code"
        settings.externalEditor = .phpstorm
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTripped == settings)
    }
}
