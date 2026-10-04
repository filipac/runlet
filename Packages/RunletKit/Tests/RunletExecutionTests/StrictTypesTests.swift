import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// The strict-types option: the runner declares `strict_types=1` on the first line, so
/// line numbers never change, and a snippet's own declaration always wins.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct StrictTypesTests {
    var php: String { TestSupport.php()! }
    var plain: TargetSnapshot { TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("plain").path, php: php) }

    let typed = "function g(int $i) { return $i; }\ng('5')"

    @Test func strictRaisesTypeError() async throws {
        let events = try await TestSupport.run(typed, target: plain, strictTypes: true)
        let error = try #require(events.errors.first)
        #expect(error.className == "TypeError")
        #expect(error.stage == .execute)
        #expect(events.finished?.status == .failed)
        // Built-in functions follow the caller's mode too.
        let builtin = try await TestSupport.run("strlen(5)", target: plain, strictTypes: true)
        #expect(builtin.errors.first?.className == "TypeError")
    }

    @Test func offCoercesScalars() async throws {
        let events = try await TestSupport.run(typed, target: plain)
        #expect(events.errors.isEmpty)
        #expect(events.result?.value?.scalar == "5")
        #expect(try await TestSupport.run("strlen(5)", target: plain).result?.value?.scalar == "1")
    }

    @Test func resultsStillCaptured() async throws {
        let events = try await TestSupport.run("$a = [1, 2];\narray_sum($a)", target: plain, strictTypes: true)
        #expect(events.result?.value?.scalar == "3")
        let noResult = try await TestSupport.run("if (true) { $y = 1; }", target: plain, strictTypes: true)
        #expect(noResult.result?.hasValue == false)
        #expect(noResult.finished?.status == .completed)
    }

    @Test func lineNumbersUnchanged() async throws {
        let code = "$a = 1;\n$b = 2;\nstrlen($a);"
        let events = try await TestSupport.run(code, target: plain, strictTypes: true)
        let error = try #require(events.errors.first)
        #expect(error.className == "TypeError")
        #expect(error.snippetLine == 3)

        // Dumps keep their lines.
        let dumps = try await TestSupport.run("$x = 1;\ndump($x);", target: plain, strictTypes: true)
        #expect(dumps.dumps.first?.snippetLine == 2)

        // Parse errors keep their line and column, including on line 1.
        for strict in [false, true] {
            let parse = try await TestSupport.run("$a = ;", target: plain, strictTypes: strict)
            #expect(parse.errors.first?.stage == .parse)
            #expect(parse.errors.first?.snippetLine == 1)
            #expect(parse.errors.first?.snippetColumn == 6)
            let later = try await TestSupport.run("$a = 1;\n$b = ;", target: plain, strictTypes: strict)
            #expect(later.errors.first?.snippetLine == 2)
        }
    }

    @Test func ownOpenTagNamespacesAndEchoTags() async throws {
        let tagged = try await TestSupport.run("<?php\n\nfunction g(int $i) { return $i; }\ng('5');", target: plain, strictTypes: true)
        #expect(tagged.errors.first?.className == "TypeError")
        // A user function's argument error points at the function; the call site is in the message.
        #expect(tagged.errors.first?.snippetLine == 3)
        #expect(tagged.errors.first?.message.contains("called in snippet on line 4") == true)

        // Whitespace before `<?php` would be output before the declaration (not allowed); lines stay put.
        let leading = try await TestSupport.run("\n\n<?php\nstrlen(5);", target: plain, strictTypes: true)
        #expect(leading.errors.first?.className == "TypeError")
        #expect(leading.errors.first?.snippetLine == 4)

        let namespaced = try await TestSupport.run("namespace Foo;\nfunction g(int $i) { return $i; }\ng('5')", target: plain, strictTypes: true)
        #expect(namespaced.errors.first?.className == "TypeError")
        #expect(namespaced.errors.first?.message.contains("called in snippet on line 3") == true)

        let braced = try await TestSupport.run("namespace App { function v(int $i) { return $i; } }\nnamespace { App\\v('3'); }", target: plain, strictTypes: true)
        #expect(braced.errors.first?.className == "TypeError")

        let echoTag = try await TestSupport.run("<?= strlen(5) ?>", target: plain, strictTypes: true)
        #expect(echoTag.errors.first?.className == "TypeError")
    }

    @Test func snippetDeclarationWins() async throws {
        // An explicit strict_types=0 keeps coercion even with the option on (and is not a duplicate).
        let off = try await TestSupport.run("declare(strict_types=0);\nstrlen(5)", target: plain, strictTypes: true)
        #expect(off.errors.isEmpty)
        #expect(off.result?.value?.scalar == "1")

        // A snippet that already declares strict types is left alone (no second declaration).
        let on = try await TestSupport.run("<?php declare(strict_types=1);\nstrlen(5);", target: plain, strictTypes: true)
        let error = try #require(on.errors.first)
        #expect(error.className == "TypeError")
        #expect(error.snippetLine == 2)
        let spaced = try await TestSupport.run("DECLARE ( /* x */ STRICT_TYPES = 1 );\nstrlen(5);", target: plain, strictTypes: true)
        #expect(spaced.errors.first?.className == "TypeError")

        // Other declarations don't count, and a mention in a comment or string doesn't either.
        let ticks = try await TestSupport.run("declare(ticks=1);\n// declare(strict_types=0);\n$s = 'declare(strict_types=0)';\nstrlen(5);", target: plain, strictTypes: true)
        #expect(ticks.errors.first?.className == "TypeError")
        #expect(ticks.errors.first?.snippetLine == 4)
    }

    @Test func selectionRunsMapToEditorLines() async throws {
        let selection = SourceSelection(startLine: 10, startColumn: 5, utf16Range: .init(location: 0, length: 0))
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: plain, code: "$x = 1;\nstrlen($x);", selection: selection, strictTypes: true)
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        let error = try #require(events.errors.first)
        #expect(error.className == "TypeError")
        #expect(error.snippetLine == 2)
        #expect(request.editorLine(forSnippetLine: 2) == 11)

        // The same selection without the option coerces.
        let relaxed = RunRequest(tabId: UUID(), documentVersion: 1, target: plain, code: "$x = 1;\nstrlen($x);", selection: selection)
        var relaxedEvents: [RunEvent] = []
        for await event in try await engine.start(relaxed) { relaxedEvents.append(event) }
        #expect(relaxedEvents.errors.isEmpty)
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd PHP 7.4"))
    func php74() async throws {
        let target = TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("plain").path, php: TestSupport.herdPHP74!)
        let strict = try await TestSupport.run("$a = 1;\nstrlen($a);", target: target, strictTypes: true)
        #expect(strict.errors.first?.className == "TypeError")
        #expect(strict.errors.first?.snippetLine == 2)
        let own = try await TestSupport.run("declare(strict_types=0);\nstrlen(5)", target: target, strictTypes: true)
        #expect(own.result?.value?.scalar == "1")
    }
}

/// The option reaches the runner inside a container too (fixture from `scripts/setup-fixtures.sh docker`).
@Suite(.serialized, .live(.docker), .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
struct StrictTypesDockerTests {
    @Test func appliesInsideContainer() async throws {
        let containers = try await TestSupport.docker!.runningContainers()
        let container = try #require(containers.first { $0.composeProject == "runlet-fixtures" && $0.composeService == "restricted" }, "start fixtures with scripts/setup-fixtures.sh docker")
        let target = TargetSnapshot(kind: .docker, label: container.name, targetId: container.id, workingDirectory: "/app", phpExecutable: "php", containerId: container.id, containerName: container.name, image: container.image, temporaryDirectory: "/scratch")
        let strict = try await TestSupport.run("$a = 1;\nstrlen($a);", target: target, strictTypes: true)
        #expect(strict.errors.first?.className == "TypeError", "\(strict.errors)")
        #expect(strict.errors.first?.snippetLine == 2)
        let relaxed = try await TestSupport.run("$a = 1;\nstrlen($a)", target: target)
        #expect(relaxed.result?.value?.scalar == "1", "\(relaxed.errors)")
    }
}

/// The request plumbing, without PHP.
struct StrictTypesRequestTests {
    private func request(in script: Data, bundle: RunnerBundle) throws -> [String: Any] {
        let text = String(decoding: script.dropFirst(bundle.source.count), as: UTF8.self)
        let start = try #require(text.range(of: "main('"))
        let end = try #require(text.range(of: "');", range: start.upperBound..<text.endIndex))
        let data = try #require(Data(base64Encoded: String(text[start.upperBound..<end.lowerBound])))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func scriptCarriesStrictTypesOnlyWhenOn() throws {
        let bundle = RunnerBundle(source: Data("<?php\n".utf8))
        let on = try request(in: bundle.script(code: "1", nonce: "n", runId: UUID(), strictTypes: true, limits: RunLimits()), bundle: bundle)
        #expect(on["strictTypes"] as? Bool == true)
        let off = try request(in: bundle.script(code: "1", nonce: "n", runId: UUID(), limits: RunLimits()), bundle: bundle)
        #expect(off["strictTypes"] == nil)
    }

    @Test func runRequestDecodesWithoutStrictTypes() throws {
        let target = TargetSnapshot(kind: .local, label: "t", targetId: "t", workingDirectory: "/tmp", phpExecutable: "php")
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: "1", strictTypes: true)
        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(RunRequest.self, from: encoded).strictTypes == true)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "strictTypes")
        let legacy = try JSONDecoder().decode(RunRequest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.strictTypes == false)
        #expect(legacy.code == "1")
    }

    @Test func effectiveValueUsesOverrideThenGlobal() throws {
        let inherit = LocalProject(name: "a", path: "/a")
        let forcedOff = LocalProject(name: "b", path: "/b", strictTypes: false)
        let forcedOn = DockerProfile(name: "c", identity: ContainerIdentity(containerName: "c"), workingDirectory: "/app", strictTypes: true)
        let library = TargetLibrary(localProjects: [inherit, forcedOff], dockerProfiles: [forcedOn])
        #expect(library.strictTypes(for: .sandbox, global: true) == true)
        #expect(library.strictTypes(for: .sandbox, global: false) == false)
        #expect(library.strictTypes(for: .local(inherit.id), global: true) == true)
        #expect(library.strictTypes(for: .local(forcedOff.id), global: true) == false)
        #expect(library.strictTypes(for: .docker(forcedOn.id), global: false) == true)
        // A removed target falls back to the global value.
        #expect(library.strictTypes(for: .local(UUID()), global: true) == true)
    }

    @Test func settingsAndTargetsDecodeWithoutStrictTypes() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 15}"#.utf8))
        #expect(settings.strictTypes == false)
        #expect(settings.fontSize == 15)
        var on = AppSettings()
        on.strictTypes = true
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(on)).strictTypes == true)

        let projectJSON = #"{"id":"\#(UUID().uuidString)","name":"p","path":"/p","revision":1}"#
        #expect(try JSONDecoder().decode(LocalProject.self, from: Data(projectJSON.utf8)).strictTypes == nil)
        var project = LocalProject(name: "p", path: "/p")
        project.strictTypes = false
        #expect(try JSONDecoder().decode(LocalProject.self, from: JSONEncoder().encode(project)).strictTypes == false)

        let profile = DockerProfile(name: "d", identity: ContainerIdentity(containerName: "d"), workingDirectory: "/app")
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object.removeValue(forKey: "strictTypes")
        #expect(try JSONDecoder().decode(DockerProfile.self, from: JSONSerialization.data(withJSONObject: object)).strictTypes == nil)
    }
}
