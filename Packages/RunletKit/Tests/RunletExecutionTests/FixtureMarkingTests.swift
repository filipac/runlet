import Foundation
import Testing

/// #242: what keeps the parallel package tests apart (LiveFixtures.swift).
struct FixtureMarkingTests {
    /// The fixture servers' variables are read only through `LiveServers`, whose accessors fail a
    /// test that isn't marked `.live(…)`. A test that read one directly would escape that check.
    @Test func fixtureServerVariablesAreReadOnlyInLiveFixtures() throws {
        // Spelled in pieces, so this file doesn't match itself.
        let variables = ["MYSQL", "PGSQL", "REDIS", "REDIS_TLS", "MONGODB", "MONGODB_TLS", "MONGODB_RS", "LARAVEL_MONGODB"].map { "RUNLET_TEST_" + $0 }
        let tests = TestSupport.repoRoot.appendingPathComponent("Packages/RunletKit/Tests")
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        var sources = 0
        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            sources += 1
            guard file.lastPathComponent != "LiveFixtures.swift" else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                for variable in variables where line.contains("\"\(variable)\"") {
                    offenders.append("\(file.deletingLastPathComponent().lastPathComponent)/\(file.lastPathComponent):\(number + 1): \(variable)")
                }
            }
        }
        #expect(sources > 100, "found the test sources in \(tests.path)")
        #expect(offenders.isEmpty, "read these through LiveServers (LiveFixtures.swift):\n\(offenders.joined(separator: "\n"))")
    }

    /// A test that reaches a fixture without its trait fails, once per fixture.
    @Test func aTestWithoutTheTraitFails() {
        withKnownIssue("no .live(.redis)") {
            Fixtures.use(.redis)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("has no .live(.redis) trait") }
        }
        Fixtures.use(.redis)
        withKnownIssue("a fixture folder needs .fixture") {
            _ = TestSupport.wordpressFixture
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("has no .fixture(.wordpress) trait") }
        }
    }

    /// The SSH fixture is a Docker container; changing it for everyone needs it alone.
    @Test(.live(.ssh)) func sshCoversDockerButNotExclusiveUse() {
        Fixtures.use(.ssh)
        Fixtures.use(.docker)
        withKnownIssue("installing the fake docker needs .live(.ssh, exclusive: true)") {
            Fixtures.use(.ssh, exclusive: true)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("has no .live(.ssh, exclusive: true) trait") }
        }
    }

    @Test func sharingHoldersRunTogether() async {
        let locks = FixtureLocks()
        await locks.acquire(.sql, exclusive: false)
        await locks.acquire(.sql, exclusive: false)
        let both = await locks.holders(.sql)
        #expect(both.sharing == 2 && !both.exclusive && both.waiting == 0)
        await locks.release(.sql, exclusive: false)
        await locks.release(.sql, exclusive: false)
        let none = await locks.holders(.sql)
        #expect(none.sharing == 0 && !none.exclusive)
    }

    /// An exclusive holder waits for the sharing ones, and a later sharing test waits behind it
    /// (first come, first served), so it isn't starved.
    @Test func exclusiveUseWaitsAndIsNotOvertaken() async throws {
        let locks = FixtureLocks()
        await locks.acquire(.ssh, exclusive: false)
        let alone = Task { await locks.acquire(.ssh, exclusive: true) }
        try await Self.waitUntil { await locks.holders(.ssh).waiting == 1 }
        let later = Task { await locks.acquire(.ssh, exclusive: false) }
        try await Self.waitUntil { await locks.holders(.ssh).waiting == 2 }
        let queued = await locks.holders(.ssh)
        #expect(queued.sharing == 1 && !queued.exclusive)

        await locks.release(.ssh, exclusive: false)
        await alone.value
        let exclusive = await locks.holders(.ssh)
        #expect(exclusive.sharing == 0 && exclusive.exclusive && exclusive.waiting == 1, "the later sharing test still waits")

        await locks.release(.ssh, exclusive: true)
        await later.value
        let shared = await locks.holders(.ssh)
        #expect(shared.sharing == 1 && !shared.exclusive && shared.waiting == 0)
        await locks.release(.ssh, exclusive: false)
    }

    @Test func holdingReleasesWhenTheBodyThrows() async {
        struct Failure: Error {}
        let locks = FixtureLocks()
        await #expect(throws: Failure.self) {
            try await FixtureLocks.holding([.redis: false, .wordpress: true], in: locks) { throw Failure() }
        }
        let redis = await locks.holders(.redis)
        let wordpress = await locks.holders(.wordpress)
        #expect(redis.sharing == 0 && !wordpress.exclusive)
    }

    /// #347: a copy of the WordPress fixture (`TestSupport.cloneWordPressFixture`) waits while a
    /// test holds the fixture alone, and holds it shared while it copies.
    @Test func aCopyWaitsForTheTestThatHoldsTheFixture() async throws {
        #expect(!FixtureLocks.heldByCurrentTest(.wordpress))
        let locks = FixtureLocks()
        await locks.acquire(.wordpress, exclusive: true)
        let copy = Task { try await FixtureLocks.sharing(.wordpress, in: locks) { await locks.holders(.wordpress) } }
        try await Self.waitUntil { await locks.holders(.wordpress).waiting == 1 }

        await locks.release(.wordpress, exclusive: true)
        let during = try await copy.value
        #expect(during.sharing == 1 && !during.exclusive)
        let after = await locks.holders(.wordpress)
        #expect(after.sharing == 0 && !after.exclusive && after.waiting == 0)
    }

    /// A test that holds the fixture through its trait copies it without waiting for itself.
    @Test(.fixture(.wordpress)) func aTestWithTheTraitCopiesWithoutWaitingForItself() {
        #expect(FixtureLocks.heldByCurrentTest(.wordpress))
        #expect(!FixtureLocks.heldByCurrentTest(.sql))
    }

    private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !condition() {
            guard ContinuousClock.now < deadline else { throw FixtureTraitError("the lock never queued the waiter") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// #242: a fresh worktree needs `scripts/build-sandbox.sh` and `scripts/setup-fixtures.sh`
/// (Composer autoloaders for `Tests/Fixtures/*`). Without them, dozens of driver tests fail
/// with "Failed opening required …/vendor/autoload.php"; this test says why, once.
struct FixtureSetupTests {
    @Test func fixturesAreSetUp() {
        let required = [
            "Resources/Sandbox/laravel/vendor/autoload.php",
            "Tests/Fixtures/composer/vendor/autoload.php",
            "Tests/Fixtures/custom-driver/vendor/autoload.php",
            "Tests/Fixtures/laravel-app/vendor/autoload.php",
        ]
        let missing = required.filter { !FileManager.default.fileExists(atPath: TestSupport.repoRoot.appendingPathComponent($0).path) }
        #expect(missing.isEmpty, "Missing \(missing.joined(separator: ", ")). From the repository root, run scripts/build-sandbox.sh, then scripts/setup-fixtures.sh.")
    }
}
