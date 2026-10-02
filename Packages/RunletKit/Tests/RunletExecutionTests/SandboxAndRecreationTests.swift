import Foundation
import RunletCore
import Testing
@testable import RunletExecution

// Integration tests for the pinned Laravel sandbox (local PHP and Docker), real Compose
// container recreation, and host PHP discovery. Covers acceptance scenarios 1, 6, 9 (Docker
// sandbox Stop), and 12 (sandbox without host PHP) from plan.md.

/// Shared helpers for this file only.
private enum SandboxFixture {
    static var template: URL { TestSupport.repoRoot.appendingPathComponent("Resources/Sandbox/laravel", isDirectory: true) }

    static var hasManifest: Bool {
        FileManager.default.fileExists(atPath: template.appendingPathComponent("runlet-sandbox.json").path)
    }

    /// `scripts/build-sandbox.sh` installs the template's Composer dependencies.
    static var hasVendor: Bool {
        FileManager.default.fileExists(atPath: template.appendingPathComponent("vendor/autoload.php").path)
    }

    static var laravelFixtureReady: Bool {
        FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("laravel-app/vendor").path)
    }

    /// Directories the sandbox must be able to write to.
    static let writableDirectories = [
        "storage/logs", "storage/framework/cache/data", "storage/framework/sessions",
        "storage/framework/views", "storage/app/private", "storage/app/public", "bootstrap/cache",
    ]

    /// A unique app-data root per test, so nothing touches the real Application Support.
    static func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runlet-sandbox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func manager(root: URL, template: URL = template) throws -> SandboxManager {
        try SandboxManager(templateURL: template, paths: AppPaths(root: root))
    }

    static func localTarget(_ manager: SandboxManager) -> TargetSnapshot {
        TargetSnapshot(kind: .sandboxLocal, label: "Sandbox · Laravel \(manager.manifest.laravelVersion)", targetId: "sandbox", workingDirectory: manager.installURL.path, phpExecutable: TestSupport.php()!)
    }

    static func dockerTarget(_ manager: SandboxManager) -> TargetSnapshot {
        TargetSnapshot(kind: .sandboxDocker, label: "Sandbox · Laravel \(manager.manifest.laravelVersion) (Docker)", targetId: "sandbox", workingDirectory: SandboxManager.containerDirectory, phpExecutable: "php", image: manager.manifest.dockerImage, hostMountDirectory: manager.installURL.path)
    }

    /// Parses KEY=VALUE lines (no interpolation; good enough for Runlet's generated .env).
    static func environment(at url: URL) throws -> [String: String] {
        var values: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            values[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
        }
        return values
    }

    /// Scalars of a list result, in order.
    static func scalars(_ events: [RunEvent]) -> [String?] {
        events.result?.value?.entries?.map { $0.value.scalar } ?? []
    }

    /// Relative path -> (size, modification date) for everything outside `vendor`, used to
    /// prove the packaged template is never written to.
    static func fingerprint(_ root: URL) -> [String: String] {
        var result: [String: String] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return result }
        let base = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if relative == "vendor" || relative == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            result[relative] = "\(values?.fileSize ?? -1)@\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        }
        return result
    }

    /// Files (not dot-files) under a directory, recursively.
    static func dataFiles(in directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { item -> String? in
            guard let url = item as? URL, !url.lastPathComponent.hasPrefix("."),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return url.lastPathComponent
        }
    }

    /// A copy of the template shaped like the app bundle's copy (`scripts/embed-resources.sh`
    /// excludes .env, tests, logs, compiled views, sessions, cache data, and bootstrap caches).
    static func packagedTemplateCopy(in root: URL) throws -> URL {
        let fm = FileManager.default
        let copy = root.appendingPathComponent("PackagedTemplate/laravel", isDirectory: true)
        try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: template, to: copy)
        for relative in [".env", "tests", "node_modules", ".git"] {
            try? fm.removeItem(at: copy.appendingPathComponent(relative))
        }
        func removeContents(of relative: String, where keep: (String) -> Bool) throws {
            let directory = copy.appendingPathComponent(relative)
            for entry in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !keep(entry) {
                try fm.removeItem(at: directory.appendingPathComponent(entry))
            }
        }
        try removeContents(of: "storage/logs") { !$0.hasSuffix(".log") }
        try removeContents(of: "storage/framework/views") { !$0.hasSuffix(".php") }
        try removeContents(of: "storage/framework/sessions") { _ in false }
        try removeContents(of: "storage/framework/cache/data") { _ in false }
        try removeContents(of: "bootstrap/cache") { !$0.hasSuffix(".php") }
        return copy
    }
}

@Suite struct SandboxAndRecreationTests {
    // MARK: - SandboxManager (no Docker)

    @Suite(.enabled(if: SandboxFixture.hasManifest, "requires Resources/Sandbox/laravel/runlet-sandbox.json"))
    struct SandboxManagerTests {
        @Test(.enabled(if: SandboxFixture.hasVendor, "requires scripts/build-sandbox.sh"))
        func ensureInstalledCreatesConfiguredWritableSandbox() throws {
            let fm = FileManager.default
            let root = try SandboxFixture.makeRoot()
            defer { try? fm.removeItem(at: root) }
            let manager = try SandboxFixture.manager(root: root)
            let templateBefore = SandboxFixture.fingerprint(SandboxFixture.template)

            #expect(!manager.isInstalled)
            let url = try manager.ensureInstalled()
            #expect(url == manager.installURL)
            #expect(manager.isInstalled)
            #expect(url.path.hasPrefix(manager.paths.sandboxes.path), "the install lives in app-owned storage")
            #expect(url.lastPathComponent == "laravel-\(manager.manifest.laravelVersion)")

            // Sandbox .env: its own key, SQLite, mail to the log.
            let env = try SandboxFixture.environment(at: url.appendingPathComponent(".env"))
            let key = try #require(env["APP_KEY"])
            #expect(key.hasPrefix("base64:"))
            #expect(Data(base64Encoded: String(key.dropFirst("base64:".count)))?.count == 32, "APP_KEY must be 32 random bytes")
            #expect(env["DB_CONNECTION"] == "sqlite")
            #expect(env["MAIL_MAILER"] == "log")
            #expect(env["DB_DATABASE"] == nil, "a relative default database path keeps the install usable from Docker")
            let templateEnv = try? SandboxFixture.environment(at: SandboxFixture.template.appendingPathComponent(".env"))
            if let templateKey = templateEnv?["APP_KEY"] {
                #expect(templateKey != key, "the install must not reuse the template's key")
            }

            var isDirectory: ObjCBool = false
            #expect(fm.fileExists(atPath: url.appendingPathComponent("database/database.sqlite").path, isDirectory: &isDirectory) && !isDirectory.boolValue)
            for relative in SandboxFixture.writableDirectories {
                let directory = url.appendingPathComponent(relative)
                #expect(fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue, "\(relative) exists")
                #expect(fm.isWritableFile(atPath: directory.path), "\(relative) is writable")
                let probe = directory.appendingPathComponent(".runlet-write-probe")
                #expect(fm.createFile(atPath: probe.path, contents: Data("x".utf8)), "\(relative) accepts writes")
                try? fm.removeItem(at: probe)
            }

            // No staging directory is left behind next to the install.
            #expect(try fm.contentsOfDirectory(atPath: manager.paths.sandboxes.path) == [url.lastPathComponent])

            // Idempotent: a second call neither reinstalls nor discards sandbox data.
            let userData = url.appendingPathComponent("runlet-user-data.txt")
            try "keep".write(to: userData, atomically: true, encoding: .utf8)
            #expect(try manager.ensureInstalled() == url)
            #expect(fm.fileExists(atPath: userData.path))
            #expect(try SandboxFixture.environment(at: url.appendingPathComponent(".env"))["APP_KEY"] == key)

            // The packaged template is never written to.
            #expect(!fm.fileExists(atPath: SandboxFixture.template.appendingPathComponent(".runlet-installed").path))
            #expect(SandboxFixture.fingerprint(SandboxFixture.template) == templateBefore)
        }

        @Test(.enabled(if: TestSupport.hasPHP && SandboxFixture.hasVendor, "requires host PHP and scripts/build-sandbox.sh"))
        func runsLaravelInInstalledSandboxWithLocalPHP() async throws {
            let root = try SandboxFixture.makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let manager = try SandboxFixture.manager(root: root)
            try manager.ensureInstalled()
            let target = SandboxFixture.localTarget(manager)

            let sum = try await TestSupport.run("collect([1, 2, 3])->sum()", target: target)
            #expect(sum.finished?.status == .completed, "\(sum.errors) \(sum.stderr)")
            #expect(sum.result?.value?.scalar == "6")
            #expect(sum.started?.framework == "laravel")
            #expect(sum.bootstrapped?.framework == "laravel")
            #expect(sum.bootstrapped?.frameworkVersion == manager.manifest.laravelVersion)

            // Services are the sandbox's own: SQLite, file cache, mail to log.
            let write = try await TestSupport.run("""
            cache()->put('runlet-k', 'v', 60);
            DB::table('users')->insert(['name' => 'Runlet', 'email' => 'runlet@example.test', 'password' => 'x']);
            dump(cache()->get('runlet-k'), DB::table('users')->count());
            [config('database.default'), config('mail.default'), config('cache.default'), config('app.name')]
            """, target: target)
            #expect(write.finished?.status == .completed, "\(write.errors) \(write.stderr)")
            #expect(write.dumps.map { $0.value.scalar } == ["v", "1"])
            #expect(SandboxFixture.scalars(write) == ["sqlite", "log", "file", "Runlet Sandbox"])

            // Writes land in the app-owned install, never in the template.
            #expect(!SandboxFixture.dataFiles(in: manager.installURL.appendingPathComponent("storage/framework/cache/data")).isEmpty)
            #expect(SandboxFixture.dataFiles(in: SandboxFixture.template.appendingPathComponent("storage/framework/cache/data")).isEmpty)

            // A fresh process per run still sees the saved data.
            let read = try await TestSupport.run("[cache()->get('runlet-k'), DB::table('users')->count()]", target: target)
            #expect(SandboxFixture.scalars(read) == ["v", "1"], "\(read.errors)")
        }

        @Test(.enabled(if: SandboxFixture.hasVendor, "requires scripts/build-sandbox.sh"))
        func resetRemovesOnlySandboxOwnedDataAndLeavesTemplateUntouched() async throws {
            let fm = FileManager.default
            let root = try SandboxFixture.makeRoot()
            defer { try? fm.removeItem(at: root) }
            let manager = try SandboxFixture.manager(root: root)
            let templateBefore = SandboxFixture.fingerprint(SandboxFixture.template)
            let templateEnvBefore = try? Data(contentsOf: SandboxFixture.template.appendingPathComponent(".env"))
            let templateDatabaseBefore = try Data(contentsOf: SandboxFixture.template.appendingPathComponent("database/database.sqlite"))

            let url = try manager.ensureInstalled()
            let keyBefore = try SandboxFixture.environment(at: url.appendingPathComponent(".env"))["APP_KEY"]

            // Sandbox-owned data: a user file, a cache entry, and a database row.
            let marker = url.appendingPathComponent("runlet-reset-marker.txt")
            try "marker".write(to: marker, atomically: true, encoding: .utf8)
            let cacheFile = url.appendingPathComponent("storage/framework/cache/data/runlet-marker")
            try "cached".write(to: cacheFile, atomically: true, encoding: .utf8)
            if TestSupport.hasPHP {
                let insert = try await TestSupport.run("DB::table('users')->insert(['name' => 'Reset', 'email' => 'reset@example.test', 'password' => 'x']); DB::table('users')->count()", target: SandboxFixture.localTarget(manager))
                #expect(insert.result?.value?.scalar == "1", "\(insert.errors) \(insert.stderr)")
            }

            // Data outside this install (state files, other sandbox versions) must survive.
            try fm.createDirectory(at: manager.paths.state, withIntermediateDirectories: true)
            try "{}".write(to: manager.paths.settings, atomically: true, encoding: .utf8)
            let otherVersion = manager.paths.sandboxes.appendingPathComponent("laravel-0.0.1", isDirectory: true)
            try fm.createDirectory(at: otherVersion, withIntermediateDirectories: true)

            try manager.reset()

            #expect(manager.isInstalled)
            #expect(!fm.fileExists(atPath: marker.path), "reset removes files written into the sandbox")
            #expect(!fm.fileExists(atPath: cacheFile.path))
            let keyAfter = try SandboxFixture.environment(at: url.appendingPathComponent(".env"))["APP_KEY"]
            #expect(keyAfter != nil && keyAfter != keyBefore, "reset writes a fresh .env")
            #expect(try Data(contentsOf: url.appendingPathComponent("database/database.sqlite")) == templateDatabaseBefore)
            #expect(fm.fileExists(atPath: manager.paths.settings.path), "reset never touches app state")
            #expect(fm.fileExists(atPath: otherVersion.path), "reset only removes this Laravel version's install")
            #expect(Set(try fm.contentsOfDirectory(atPath: manager.paths.sandboxes.path)) == [url.lastPathComponent, otherVersion.lastPathComponent])

            if TestSupport.hasPHP {
                let after = try await TestSupport.run("[DB::table('users')->count(), cache()->get('runlet-k')]", target: SandboxFixture.localTarget(manager))
                #expect(after.result?.value?.entries?.first?.value.scalar == "0", "\(after.errors)")
                #expect(after.result?.value?.entries?.last?.value.type == .null)
            }

            // The template is untouched: no marker, no install marker, same .env/database.
            let template = SandboxFixture.template
            #expect(!fm.fileExists(atPath: template.appendingPathComponent("runlet-reset-marker.txt").path))
            #expect(!fm.fileExists(atPath: template.appendingPathComponent(".runlet-installed").path))
            #expect((try? Data(contentsOf: template.appendingPathComponent(".env"))) == templateEnvBefore)
            #expect(try Data(contentsOf: template.appendingPathComponent("database/database.sqlite")) == templateDatabaseBefore)
            #expect(SandboxFixture.fingerprint(template) == templateBefore)
        }

        /// The app bundle ships the template without .env or bootstrap caches; installing from
        /// that shape must still produce a working sandbox and never write into the template.
        @Test(.enabled(if: TestSupport.hasPHP && SandboxFixture.hasVendor, "requires host PHP and scripts/build-sandbox.sh"))
        func installsAndRunsFromPackagedTemplateShape() async throws {
            let fm = FileManager.default
            let root = try SandboxFixture.makeRoot()
            defer { try? fm.removeItem(at: root) }
            let packaged = try SandboxFixture.packagedTemplateCopy(in: root)
            #expect(!fm.fileExists(atPath: packaged.appendingPathComponent(".env").path))
            #expect(!fm.fileExists(atPath: packaged.appendingPathComponent("bootstrap/cache/packages.php").path))
            let manager = try SandboxFixture.manager(root: root.appendingPathComponent("AppData"), template: packaged)

            let url = try manager.ensureInstalled()
            let events = try await TestSupport.run("[collect([1, 2, 3])->sum(), app()->version(), config('database.default'), config('mail.default')]", target: SandboxFixture.localTarget(manager))
            #expect(events.finished?.status == .completed, "\(events.errors) \(events.stderr)")
            #expect(SandboxFixture.scalars(events) == ["6", manager.manifest.laravelVersion, "sqlite", "log"])
            #expect(events.bootstrapped?.frameworkVersion == manager.manifest.laravelVersion)
            // Package discovery caches are regenerated in the writable copy.
            #expect(fm.fileExists(atPath: url.appendingPathComponent("bootstrap/cache/packages.php").path))

            try "marker".write(to: url.appendingPathComponent("runlet-reset-marker.txt"), atomically: true, encoding: .utf8)
            try manager.reset()
            #expect(!fm.fileExists(atPath: url.appendingPathComponent("runlet-reset-marker.txt").path))
            #expect(fm.fileExists(atPath: url.appendingPathComponent(".env").path))
            #expect(!fm.fileExists(atPath: packaged.appendingPathComponent(".env").path), "the template never gets a .env")
            #expect(!fm.fileExists(atPath: packaged.appendingPathComponent(".runlet-installed").path))
            #expect(!fm.fileExists(atPath: packaged.appendingPathComponent("runlet-reset-marker.txt").path))
            #expect(!fm.fileExists(atPath: packaged.appendingPathComponent("bootstrap/cache/packages.php").path))
        }

        @Test func chooseRuntimePrefersCompatibleLocalPHP() async throws {
            let root = try SandboxFixture.makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let manager = try SandboxFixture.manager(root: root)
            #expect(manager.manifest.minimumPHP == "8.3")

            let php74 = PHPInstallation(path: "/runlet-test/php74", version: "7.4.33", hasTokenizer: true, source: "Test")
            let php82 = PHPInstallation(path: "/runlet-test/php82", version: "8.2.29", hasTokenizer: true, source: "Test")
            let php84 = PHPInstallation(path: "/runlet-test/php84", version: "8.4.25", hasTokenizer: true, source: "Test")
            let php85NoTokenizer = PHPInstallation(path: "/runlet-test/php85", version: "8.5.1", hasTokenizer: false, source: "Test")
            let php86RC = PHPInstallation(path: "/runlet-test/php86", version: "8.6.0RC2", hasTokenizer: true, source: "Test")

            // Automatic: the first stable, compatible PHP with tokenizer.
            #expect(await manager.chooseRuntime(preferredPHP: nil, installations: [php74, php82, php85NoTokenizer, php86RC, php84], docker: nil) == .local(php84))
            // An explicit compatible preference wins, even a prerelease.
            #expect(await manager.chooseRuntime(preferredPHP: php86RC.path, installations: [php84, php86RC], docker: nil) == .local(php86RC))
            // An incompatible or tokenizer-less preference falls back to the automatic choice.
            #expect(await manager.chooseRuntime(preferredPHP: php82.path, installations: [php82, php84], docker: nil) == .local(php84))
            #expect(await manager.chooseRuntime(preferredPHP: php85NoTokenizer.path, installations: [php85NoTokenizer, php84], docker: nil) == .local(php84))
            // Only a prerelease fits: it is used rather than failing.
            #expect(await manager.chooseRuntime(preferredPHP: nil, installations: [php82, php86RC], docker: nil) == .local(php86RC))

            // No PHP and no Docker: unavailable, naming the requirement.
            guard case .unavailable(let reason) = await manager.chooseRuntime(preferredPHP: nil, installations: [], docker: nil) else {
                Issue.record("expected .unavailable without PHP or Docker")
                return
            }
            #expect(reason.contains(manager.manifest.minimumPHP))
            // Only incompatible PHP and no Docker: still unavailable.
            guard case .unavailable = await manager.chooseRuntime(preferredPHP: nil, installations: [php74, php82, php85NoTokenizer], docker: nil) else {
                Issue.record("expected .unavailable with only incompatible PHP")
                return
            }
            // A Docker CLI whose engine does not respond is also unavailable (not a Docker runtime).
            guard case .unavailable(let engineReason) = await manager.chooseRuntime(preferredPHP: nil, installations: [], docker: DockerCLI(executable: "/usr/bin/false")) else {
                Issue.record("expected .unavailable when the Docker engine does not respond")
                return
            }
            #expect(engineReason.contains("Docker"))
        }
    }

    // MARK: - Docker (serialized so sandbox container churn and Compose recreation never overlap)

    @Suite(.serialized, .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
    struct DockerIntegrationTests {
        // MARK: - Docker sandbox (scenario 12: no host PHP)

        @Suite(
            .serialized,
            .enabled(if: TestSupport.hasDocker && SandboxFixture.hasVendor, "requires a running Docker engine and scripts/build-sandbox.sh"),
            .enabled("requires the sandbox Docker image (already pulled)") {
                guard let docker = TestSupport.docker, SandboxFixture.hasManifest else { return false }
                let manager = try SandboxFixture.manager(root: FileManager.default.temporaryDirectory)
                return await docker.imageExists(manager.manifest.dockerImage)
            }
        )
        struct DockerSandboxTests {
            var docker: DockerCLI { TestSupport.docker! }

            func run(_ code: String, target: TargetSnapshot, engine: ExecutionEngine, tabId: UUID = UUID()) async throws -> (RunRequest, [RunEvent]) {
                let request = RunRequest(tabId: tabId, documentVersion: 1, target: target, code: code)
                var events: [RunEvent] = []
                for await event in try await engine.start(request) { events.append(event) }
                return (request, events)
            }

            /// Containers (running or not) with exactly this name.
            func containers(named name: String) async throws -> [String] {
                let data = try await docker.run(["ps", "-a", "--filter", "name=^\(name)$", "--format", "{{.Names}}"])
                return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            }

            /// Polls briefly: `docker run --rm` removal can trail the client's exit.
            func waitUntilRemoved(_ name: String, within duration: Duration = .seconds(5)) async throws -> [String] {
                let deadline = ContinuousClock.now + duration
                var remaining = try await containers(named: name)
                while !remaining.isEmpty, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(200))
                    remaining = try await containers(named: name)
                }
                return remaining
            }

            @Test func sandboxRunsInDockerWithoutHostPHP() async throws {
                let root = try SandboxFixture.makeRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let manager = try SandboxFixture.manager(root: root)
                try manager.ensureInstalled()

                // Without any host PHP the sandbox falls back to Docker, image already present.
                #expect(await manager.chooseRuntime(preferredPHP: nil, installations: [], docker: docker) == .docker(image: manager.manifest.dockerImage, imagePresent: true))

                let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: docker)
                let target = SandboxFixture.dockerTarget(manager)
                let (request, events) = try await run("collect([1, 2, 3])->sum()", target: target, engine: engine)
                #expect(events.finished?.status == .completed, "\(events.errors) \(events.stderr)")
                #expect(events.result?.value?.scalar == "6")
                #expect(events.started?.framework == "laravel")
                #expect(events.started?.workingDirectory == SandboxManager.containerDirectory)
                #expect(events.started?.phpVersion?.hasPrefix("8.4") == true, "\(String(describing: events.started?.phpVersion))")
                #expect(events.bootstrapped?.framework == "laravel")
                #expect(events.bootstrapped?.frameworkVersion == manager.manifest.laravelVersion)
                #expect(try await waitUntilRemoved(DockerSandboxAdapter.containerName(for: request.runId)) == [], "the disposable sandbox container is removed after the run")

                // Writes go to the app-owned install mounted from the host.
                let (_, write) = try await run("""
                DB::table('users')->insert(['name' => 'Docker', 'email' => 'docker@example.test', 'password' => 'x']);
                cache()->put('runlet-docker', 'from-docker', 60);
                [DB::table('users')->count(), config('database.default'), config('mail.default')]
                """, target: target, engine: engine)
                #expect(SandboxFixture.scalars(write) == ["1", "sqlite", "log"], "\(write.errors) \(write.stderr)")
                #expect(!SandboxFixture.dataFiles(in: manager.installURL.appendingPathComponent("storage/framework/cache/data")).isEmpty)

                // The same install keeps working with host PHP (switching runtimes keeps sandbox data).
                if TestSupport.hasPHP {
                    let local = try await TestSupport.run("[DB::table('users')->count(), cache()->get('runlet-docker')]", target: SandboxFixture.localTarget(manager))
                    #expect(SandboxFixture.scalars(local) == ["1", "from-docker"], "\(local.errors) \(local.stderr)")
                }
            }

            @Test func stopEndsDockerSandboxRunAndRemovesItsContainer() async throws {
                let root = try SandboxFixture.makeRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let manager = try SandboxFixture.manager(root: root)
                try manager.ensureInstalled()

                let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: docker)
                let tabId = UUID()
                let request = RunRequest(tabId: tabId, documentVersion: 1, target: SandboxFixture.dockerTarget(manager), code: "echo 'go';\nsleep(60);\necho 'not reached';")
                let name = DockerSandboxAdapter.containerName(for: request.runId)
                #expect(name == "runlet-sandbox-\(request.runId.uuidString.prefix(8).lowercased())")

                var events: [RunEvent] = []
                var outcome: CancelOutcome?
                var runningBeforeStop: [String] = []
                let clock = ContinuousClock()
                var stopAt: ContinuousClock.Instant?
                for await event in try await engine.start(request) {
                    events.append(event)
                    if case .stdout = event.kind, stopAt == nil {
                        runningBeforeStop = (try? await containers(named: name)) ?? []
                        stopAt = clock.now
                        outcome = await engine.cancel(runId: request.runId)
                    }
                }
                let stoppedAt = try #require(stopAt, "the run never produced output: \(events.errors) \(events.stderr)")
                let stopDuration = clock.now - stoppedAt
                #expect(runningBeforeStop == [name], "the sandbox container exists while the run is active")
                #expect(stopDuration < .seconds(6), "\(stopDuration)")
                #expect(outcome?.confirmed == true, "\(outcome?.message ?? "no outcome")")
                #expect(events.finished?.status == .cancelled)
                #expect(events.filter { if case .finished = $0.kind { return true } else { return false } }.count == 1)
                #expect(!events.stdout.contains("not reached"))
                #expect(try await waitUntilRemoved(name) == [], "no runlet-sandbox container may be left after Stop")

                // The tab is usable again after Stop.
                var busy = await engine.isTabRunning(tabId)
                let deadline = clock.now + .seconds(1)
                while busy, clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                    busy = await engine.isTabRunning(tabId)
                }
                #expect(!busy)
                let (_, again) = try await run("1 + 1", target: SandboxFixture.dockerTarget(manager), engine: engine, tabId: tabId)
                #expect(again.result?.value?.scalar == "2", "\(again.errors)")
            }

            /// Stop pressed while `docker run` is still creating the sandbox container (a user
            /// clicking Stop right after Run). Covers a snippet blocked in `sleep()` and a busy loop.
            @Test(arguments: [
                "echo 'go';\nsleep(30);\necho 'AFTER-STOP';",
                "echo 'go';\nwhile (true) { usleep(10000); }\necho 'AFTER-STOP';",
            ])
            func stopRightAfterLaunchStopsSandboxContainer(code: String) async throws {
                let root = try SandboxFixture.makeRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let manager = try SandboxFixture.manager(root: root)
                try manager.ensureInstalled()

                let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: docker)
                let request = RunRequest(tabId: UUID(), documentVersion: 1, target: SandboxFixture.dockerTarget(manager), code: code)
                let name = DockerSandboxAdapter.containerName(for: request.runId)
                let stream = try await engine.start(request)
                // Long enough for the docker client to launch, too short for the container to exist.
                try await Task.sleep(for: .milliseconds(20))
                let clock = ContinuousClock()
                let stopAt = clock.now
                let outcome = await engine.cancel(runId: request.runId)
                var events: [RunEvent] = []
                for await event in stream { events.append(event) }
                let stopDuration = clock.now - stopAt
                let leftover = try await waitUntilRemoved(name, within: .seconds(3))
                // Never leave a runaway container behind, whatever the outcome.
                _ = try? await docker.run(["rm", "-f", name])

                #expect(events.finished?.status == .cancelled)
                do {
                    #expect(outcome?.confirmed == true, "\(outcome?.message ?? "no outcome")")
                    #expect(stopDuration < .seconds(5), "\(stopDuration)")
                    #expect(!events.stdout.contains("AFTER-STOP"), "code after the stop point ran")
                    #expect(events.result == nil, "the snippet completed after Stop")
                    #expect(leftover == [], "sandbox container still running after Stop")
                }
            }
        }

        // MARK: - Real Compose recreation (scenario 6)

        /// Recreates the fixture's `laravel` service in a dedicated Compose project created from
        /// `Tests/Fixtures/docker/compose.yml`, so the shared `runlet-fixtures` containers used by
        /// `DockerRunTests` (which may run in parallel) are never stopped or replaced.
        @Suite(
            .serialized,
            .enabled(if: TestSupport.hasDocker && SandboxFixture.laravelFixtureReady, "requires a running Docker engine and scripts/setup-fixtures.sh"),
            .enabled("requires the php:8.4-cli image (already pulled)") {
                await TestSupport.docker?.imageExists("php:8.4-cli") ?? false
            }
        )
        struct ComposeRecreationTests {
            static let project = "runlet-fixtures-recreate"
            var docker: DockerCLI { TestSupport.docker! }
            var composeFile: String { TestSupport.fixtures.appendingPathComponent("docker/compose.yml").path }

            @discardableResult
            func compose(_ arguments: [String]) async throws -> String {
                let result = try await runCommand(docker.spec(["compose", "-f", composeFile, "-p", Self.project] + arguments), timeout: .seconds(120))
                let output = String(decoding: result.stderr + result.stdout, as: UTF8.self)
                guard result.exitCode == 0 else {
                    throw DockerError("docker compose \(arguments.joined(separator: " ")) failed (\(result.exitCode)): \(output)")
                }
                return output
            }

            func service(_ name: String, project: String = project) async throws -> ContainerInfo? {
                try await docker.runningContainers().first { $0.composeProject == project && $0.composeService == name }
            }

            func target(_ container: ContainerInfo) -> TargetSnapshot {
                TargetSnapshot(kind: .docker, label: container.name, targetId: container.id, workingDirectory: "/var/www/html", phpExecutable: "php", containerId: container.id, containerName: container.name, image: container.image, temporaryDirectory: "/tmp")
            }

            @Test func recreatedComposeServiceResolvesToReplacementAndNameOnlyNeedsConfirmation() async throws {
                let sharedBefore = try await service("laravel", project: "runlet-fixtures")
                try await compose(["up", "-d", "--pull", "never", "--timeout", "1", "laravel"])
                var failure: Error?
                do {
                    try await recreationScenario()
                } catch {
                    failure = error
                }
                _ = try? await compose(["down", "--timeout", "1"])
                #expect(try await docker.runningContainers().allSatisfy { $0.composeProject != Self.project })
                // The shared fixture project was left alone and is still running.
                if let sharedBefore {
                    #expect(try await service("laravel", project: "runlet-fixtures")?.id == sharedBefore.id)
                }
                if let failure { throw failure }
            }

            func recreationScenario() async throws {
                let old = try #require(try await service("laravel"), "compose up did not start the laravel service")
                let profile = DockerProfile(name: "Recreation fixture", identity: old.identity, workingDirectory: "/var/www/html")
                #expect(profile.validate().isEmpty)
                #expect(profile.identity.isCompose)
                #expect(profile.identity.composeProject == Self.project && profile.identity.composeService == "laravel")
                let nameOnly = ContainerIdentity(containerName: old.name, lastContainerId: old.id, lastImage: old.image)
                #expect(nameOnly.composeProject == nil && !nameOnly.isCompose)

                // Before recreation both identities resolve to the same container.
                #expect(try await DockerProfileResolver.resolve(profile, docker: docker) == .resolved(old, recreated: false))
                #expect(try await DockerProfileResolver.resolve(nameOnly, among: docker.runningContainers()) == .resolved(old, recreated: false))
                let staleSnapshot = target(old)

                try await compose(["up", "-d", "--force-recreate", "--no-deps", "--pull", "never", "--timeout", "1", "laravel"])

                let replacement = try #require(try await service("laravel"), "the recreated service is not running")
                #expect(replacement.id != old.id)
                #expect(replacement.name == old.name)
                #expect(await docker.inspect(old.id) == nil, "the old container was removed by recreation")

                // Stable Compose identity: resolves to the replacement and reports the recreation.
                let resolution = try await DockerProfileResolver.resolve(profile, docker: docker)
                guard case .resolved(let resolved, let recreated) = resolution else {
                    Issue.record("expected .resolved after recreation, got \(resolution)")
                    return
                }
                #expect(recreated)
                #expect(resolved.id == replacement.id)
                #expect(resolved.id != old.id)

                // A run snapshotted against the old container must not silently use the replacement.
                let stale = try await TestSupport.run("getenv('FIXTURE_SERVICE')", target: staleSnapshot)
                #expect(stale.errors.first?.stage == .launch)
                #expect(stale.finished?.reason == "launch-failed")
                #expect(stale.result == nil)

                // Running in the resolved replacement works, with its environment and data.
                let events = try await TestSupport.run("[getenv('FIXTURE_SERVICE'), App\\Models\\Widget::count()]", target: target(resolved))
                #expect(events.finished?.status == .completed, "\(events.errors) \(events.stderr)")
                #expect(events.started?.framework == "laravel")
                #expect(SandboxFixture.scalars(events) == ["laravel", "3"])

                // Name-only identity: same name, different container, no Compose proof -> confirm first.
                let nameResolution = try await DockerProfileResolver.resolve(nameOnly, among: docker.runningContainers())
                guard case .needsConfirmation(let candidate, let reason) = nameResolution else {
                    Issue.record("expected .needsConfirmation for a name-only identity, got \(nameResolution)")
                    return
                }
                #expect(candidate.id == replacement.id)
                #expect(reason.contains(old.name))
                #expect(reason.contains("same image \(old.image)"), "\(reason)")

                // After the user confirms (identity updated to the new ID) it resolves directly.
                var confirmed = nameOnly
                confirmed.lastContainerId = replacement.id
                confirmed.lastImage = replacement.image
                #expect(try await DockerProfileResolver.resolve(confirmed, among: docker.runningContainers()) == .resolved(replacement, recreated: false))
            }
        }

        // MARK: Container listing

        /// `docker ps` and `docker inspect` race with containers exiting in between, e.g. any
        /// other application's container or Runlet's own `--rm` sandbox containers.
        @Suite struct ContainerListingTests {
            var docker: DockerCLI { TestSupport.docker! }

            @Test func listingToleratesContainerRemovedBetweenPsAndInspect() async throws {
                let directory = try SandboxFixture.makeRoot()
                defer { try? FileManager.default.removeItem(at: directory) }
                let vanished = String(repeating: "deadbeef", count: 8)
                // Real Docker, except `ps` also reports a container that is gone by `inspect` time.
                let script = directory.appendingPathComponent("docker")
                try """
                #!/bin/sh
                if [ "$1" = "ps" ]; then
                    "\(docker.executable)" "$@" || exit $?
                    echo \(vanished)
                    exit 0
                fi
                exec "\(docker.executable)" "$@"
                """.write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                let racing = DockerCLI(executable: script.path)
                let fixture = try await docker.runningContainers().first { $0.composeProject == "runlet-fixtures" && $0.composeService == "laravel" }

                do {
                    let listed = try await racing.runningContainers()
                    #expect(!listed.contains { $0.id == vanished })
                    if let fixture {
                        #expect(listed.contains { $0.id == fixture.id })
                        let profile = DockerProfile(name: "Fixture", identity: fixture.identity, workingDirectory: "/var/www/html")
                        #expect(try await DockerProfileResolver.resolve(profile, docker: racing) == .resolved(fixture, recreated: false))
                    }
                }
            }
        }
    }

    // MARK: - PHP discovery

    @Suite struct PHPDiscoveryTests {
        @Test(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
        func discoverFindsHostPHP() async throws {
            let installations = await PHPDiscovery.discover()
            #expect(!installations.isEmpty)
            for installation in installations {
                #expect(!installation.version.isEmpty, "\(installation.path)")
                #expect(ExecutableLocator.isExecutable(installation.path), "\(installation.path)")
                #expect(installation.versionComponents.major >= 5, "\(installation.path): \(installation.version)")
            }
            #expect(Set(installations.map(\.id)).count == installations.count, "no duplicate installations")
            // The `php` on PATH (the user's default) comes first.
            let defaultPHP = try #require(TestSupport.php())
            #expect(installations.first?.path == defaultPHP)

            let inspected = try #require(await PHPDiscovery.inspect(path: defaultPHP, source: "PATH"))
            let reported = try await runCommand(ProcessSpec(executable: defaultPHP, arguments: ["-n", "-r", "echo PHP_VERSION;"], environment: ExecutableLocator.toolEnvironment()))
            #expect(inspected.version == String(decoding: reported.stdout, as: UTF8.self))
            #expect(inspected.source == "PATH")
            #expect(inspected.path == defaultPHP)
        }

        @Test func inspectRejectsNonPHPExecutables() async {
            #expect(await PHPDiscovery.inspect(path: "/bin/ls") == nil)
            #expect(await PHPDiscovery.inspect(path: "/usr/bin/true") == nil)
            #expect(await PHPDiscovery.inspect(path: "/nonexistent/runlet/php") == nil)
            #expect(await PHPDiscovery.inspect(path: "/bin") == nil)
        }

        @Test func preferredSkipsPrereleasesAndRespectsMinimum() {
            func php(_ version: String, tokenizer: Bool = true) -> PHPInstallation {
                PHPInstallation(path: "/runlet-test/php-\(version)", version: version, hasTokenizer: tokenizer, source: "Test")
            }
            let rc = php("8.6.0RC2")
            let stable = php("8.4.25")
            #expect(rc.isPrerelease)
            #expect(!stable.isPrerelease)
            #expect(php("8.5.0-dev").isPrerelease && php("8.5.0alpha1").isPrerelease && php("8.5.0beta3").isPrerelease)
            #expect(rc.versionComponents.major == 8 && rc.versionComponents.minor == 6)

            // Stable beats an earlier-listed prerelease.
            #expect(PHPDiscovery.preferred([rc, stable]) == stable)
            // A prerelease is used only when nothing stable fits.
            #expect(PHPDiscovery.preferred([rc]) == rc)
            #expect(PHPDiscovery.preferred([rc, stable], minimum: (8, 5)) == rc)
            // Minimum version and tokenizer are both required.
            #expect(PHPDiscovery.preferred([php("7.3.33"), php("8.0.30")]) == php("8.0.30"))
            #expect(PHPDiscovery.preferred([php("8.4.25"), php("8.3.1")], minimum: (8, 4)) == php("8.4.25"))
            #expect(PHPDiscovery.preferred([php("8.2.1"), php("8.3.1")], minimum: (8, 3)) == php("8.3.1"))
            #expect(PHPDiscovery.preferred([php("8.4.25", tokenizer: false), php("8.3.10")]) == php("8.3.10"))
            #expect(PHPDiscovery.preferred([php("7.3.33"), php("8.4.25", tokenizer: false)]) == nil)
            #expect(PHPDiscovery.preferred([]) == nil)
            // Discovery order is preserved among stable candidates (the PATH default first).
            #expect(PHPDiscovery.preferred([php("8.3.10"), php("8.4.25")]) == php("8.3.10"))
        }
    }
}
