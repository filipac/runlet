import Foundation
import Testing

/// What a test shares with other tests, so that the package tests can run in parallel (#242).
///
/// Most live suites already keep to themselves: each uses its own tables (`p144_…`), Redis keys
/// (`p190:…`), MongoDB databases and collections, temporary folders, and SSH control sockets, so
/// they run side by side with every other test. A test that uses a fixture says so with a trait:
///
/// - `.live(.sql)`, `.live(.redis)`, `.live(.docker, .ssh)`: the test needs a live fixture (the
///   fixture database servers, Docker, or the SSH fixture). A fast run (`scripts/test.sh fast`,
///   `RUNLET_TEST_SKIP_LIVE=1`) cancels it. It shares the fixture with the other live tests.
/// - `.live(.ssh, exclusive: true)`: the test changes the fixture for everyone (it pauses the SSH
///   server, or replaces its `docker`), or reads state that other tests change (the sizes of
///   every table on the server). It waits until no other test uses the fixture, and holds it alone.
/// - `.fixture(.wordpress)`: a fixture folder that tests change (must-use plugins, its SQLite
///   database). Tests that hold it never overlap. It is not live, so fast runs keep these tests.
///
/// The fixtures' accessors (`TestSupport.docker`, `SQLLiveDatabaseTests.servers`, `LiveServers`,
/// `SSHFixture`, `TestSupport.wordpressFixture`) call `Fixtures.use`, which fails a test that
/// reaches a fixture without its trait. `FixtureMarkingTests` checks that the fixture servers'
/// variables are read only here.
enum Fixture: String, CaseIterable, Comparable, Sendable {
    /// MariaDB and PostgreSQL from `scripts/setup-fixtures.sh databases` (`RUNLET_TEST_MYSQL`,
    /// `RUNLET_TEST_PGSQL`).
    case sql
    /// Redis (`RUNLET_TEST_REDIS`, `RUNLET_TEST_REDIS_TLS`).
    case redis
    /// MongoDB: plain, TLS, and the replica set (`RUNLET_TEST_MONGODB*`).
    case mongo
    /// A running Docker engine, the `runlet-fixtures` containers, and Runlet's sandbox containers.
    case docker
    /// The disposable SSH server (`SSHFixture`), a `runlet-fixtures` container.
    case ssh
    /// `Tests/Fixtures/wordpress`: tests add must-use plugins to it, and runs write to its SQLite
    /// database.
    case wordpress

    /// Needs a service that `scripts/setup-fixtures.sh databases` or Docker provides.
    var isLive: Bool { self != .wordpress }

    /// Holding `self` also covers `other`: the SSH fixture is a Docker container.
    func covers(_ other: Fixture) -> Bool { self == other || (self == .ssh && other == .docker) }

    static func < (lhs: Fixture, rhs: Fixture) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    var trait: String { isLive ? ".live(.\(rawValue))" : ".fixture(.\(rawValue))" }
}

/// Declares the fixtures a suite or test uses (see `Fixture`). Recursive: a suite's trait covers
/// its tests and nested suites.
struct FixtureTrait: SuiteTrait, TestTrait, TestScoping {
    var fixtures: [Fixture]
    var exclusive: Bool

    var isRecursive: Bool { true }

    func prepare(for test: Test) async throws {
        if !exclusive, let local = fixtures.first(where: { !$0.isLive }) {
            throw FixtureTraitError("\(test.name): .live(.\(local.rawValue)) isn't live; use .fixture(.\(local.rawValue))")
        }
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        // A suite's trait and a test's own both scope the test: the outer one takes every
        // fixture the test needs at once, the inner one runs inside it.
        if FixtureLocks.held {
            try await function()
            return
        }
        let traits = test.traits.compactMap { $0 as? FixtureTrait }
        if Fixtures.skipLive, traits.contains(where: { $0.fixtures.contains(where: \.isLive) }) {
            try Test.cancel("uses live fixtures, which this run skips (RUNLET_TEST_SKIP_LIVE=1)")
        }
        var access: [Fixture: Bool] = [:]
        for trait in traits {
            for fixture in trait.fixtures { access[fixture] = (access[fixture] ?? false) || trait.exclusive }
        }
        try await FixtureLocks.holding(access) {
            try await FixtureLocks.$held.withValue(true) { try await function() }
        }
    }
}

struct FixtureTraitError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

extension Trait where Self == FixtureTrait {
    /// Uses live fixtures, shared with other live tests; `exclusive` holds them alone. A fast run
    /// skips the test.
    static func live(_ fixtures: Fixture..., exclusive: Bool = false) -> Self {
        FixtureTrait(fixtures: fixtures, exclusive: exclusive)
    }

    /// Uses fixture folders that tests change: one test at a time.
    static func fixture(_ fixtures: Fixture...) -> Self {
        FixtureTrait(fixtures: fixtures, exclusive: true)
    }
}

/// Readers-writer locks, one per fixture, first come first served (so a test that needs a fixture
/// alone isn't starved by a stream of sharing ones). Waiting suspends the test's task; it never
/// blocks a thread.
actor FixtureLocks {
    static let shared = FixtureLocks()

    /// True inside a test that already holds its fixtures.
    @TaskLocal static var held = false

    private struct Waiter {
        var exclusive: Bool
        var continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var sharing = 0
        var exclusive = false
        var queue: [Waiter] = []

        func admits(exclusive wantsExclusive: Bool) -> Bool {
            wantsExclusive ? sharing == 0 && !exclusive : !exclusive
        }
    }

    private var states: [Fixture: State] = [:]

    func acquire(_ fixture: Fixture, exclusive: Bool) async {
        var state = states[fixture, default: State()]
        if state.queue.isEmpty && state.admits(exclusive: exclusive) {
            if exclusive { state.exclusive = true } else { state.sharing += 1 }
            states[fixture] = state
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            states[fixture, default: State()].queue.append(Waiter(exclusive: exclusive, continuation: continuation))
        }
    }

    func release(_ fixture: Fixture, exclusive: Bool) {
        guard var state = states[fixture] else { return }
        if exclusive { state.exclusive = false } else { state.sharing -= 1 }
        while let next = state.queue.first, state.admits(exclusive: next.exclusive) {
            state.queue.removeFirst()
            if next.exclusive { state.exclusive = true } else { state.sharing += 1 }
            next.continuation.resume()
        }
        states[fixture] = state
    }

    /// Whether `fixture` is held now, and how (for the lock's own tests).
    func holders(_ fixture: Fixture) -> (sharing: Int, exclusive: Bool, waiting: Int) {
        let state = states[fixture, default: State()]
        return (state.sharing, state.exclusive, state.queue.count)
    }

    /// Runs `body` holding every fixture in `access` (true: alone). They are taken in one order,
    /// so two tests can't each hold what the other waits for.
    static func holding<T: Sendable>(_ access: [Fixture: Bool], in locks: FixtureLocks = .shared, _ body: () async throws -> T) async throws -> T {
        let order = access.keys.sorted()
        for fixture in order { await locks.acquire(fixture, exclusive: access[fixture]!) }
        do {
            let value = try await body()
            for fixture in order.reversed() { await locks.release(fixture, exclusive: access[fixture]!) }
            return value
        } catch {
            for fixture in order.reversed() { await locks.release(fixture, exclusive: access[fixture]!) }
            throw error
        }
    }
}

enum Fixtures {
    /// A fast run: tests that need live fixtures are cancelled.
    static var skipLive: Bool { ProcessInfo.processInfo.environment["RUNLET_TEST_SKIP_LIVE"] == "1" }

    private static let reported = Reported()

    /// Called where a test reaches `fixture`. A test without the fixture's trait fails, once per
    /// fixture: without it, it could overlap with a test that holds the fixture alone, and a
    /// fast run wouldn't skip it. Nothing happens outside a running test (a detached task, a
    /// condition evaluated while Swift Testing plans the run).
    /// `exclusive`: the test changes the fixture for everyone, so it must hold it alone.
    static func use(_ fixture: Fixture, exclusive: Bool = false) {
        // Only while a test case runs: Swift Testing evaluates `.enabled(if:)` with `Test.current`
        // set but no case, and drops issues recorded there.
        guard let test = Test.current, Test.Case.current != nil else { return }
        let declared = test.traits.contains { trait in
            guard let trait = trait as? FixtureTrait, !exclusive || trait.exclusive else { return false }
            return trait.fixtures.contains { $0.covers(fixture) }
        }
        guard !declared, reported.first("\(test.id)|\(fixture)|\(exclusive)") else { return }
        let needed = exclusive && fixture.isLive ? ".live(.\(fixture.rawValue), exclusive: true)" : fixture.trait
        // At the test, which is what needs the trait.
        Issue.record("\(test.name) uses the \(fixture.rawValue) fixture but has no \(needed) trait (see LiveFixtures.swift and docs/validation.md)", sourceLocation: test.sourceLocation)
    }

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: Set<String> = []
        func first(_ key: String) -> Bool { lock.withLock { keys.insert(key).inserted } }
    }
}

/// The fixture servers from `scripts/setup-fixtures.sh databases`, read only here
/// (`FixtureMarkingTests`). Each read counts as using the fixture.
enum LiveServers {
    static func value(_ variable: String, _ fixture: Fixture) -> String? {
        Fixtures.use(fixture)
        guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else { return nil }
        return value
    }

    /// `<PDO DSN>|<user>|<password>`.
    static var mysql: String? { value("RUNLET_TEST_MYSQL", .sql) }
    static var pgsql: String? { value("RUNLET_TEST_PGSQL", .sql) }
    /// `redis://:<password>@127.0.0.1:<port>/0`.
    static var redis: String? { value("RUNLET_TEST_REDIS", .redis) }
    static var redisTLS: String? { value("RUNLET_TEST_REDIS_TLS", .redis) }
    /// `mongodb://127.0.0.1:<port>|<user>|<password>`.
    static var mongo: String? { value("RUNLET_TEST_MONGODB", .mongo) }
    static var mongoTLS: String? { value("RUNLET_TEST_MONGODB_TLS", .mongo) }
    static var mongoReplicaSet: String? { value("RUNLET_TEST_MONGODB_RS", .mongo) }
    /// A scratch Laravel app with mongodb/laravel-mongodb whose connection reaches the fixture.
    static var laravelMongo: String? { value("RUNLET_TEST_LARAVEL_MONGODB", .mongo) }
}

extension SQLLiveDatabaseTests {
    private static let storedMySQL = Server(LiveServers.mysql)
    private static let storedPgSQL = Server(LiveServers.pgsql)

    static var mysql: Server? {
        Fixtures.use(.sql)
        return storedMySQL
    }

    static var pgsql: Server? {
        Fixtures.use(.sql)
        return storedPgSQL
    }

    static var servers: [Server] { [mysql, pgsql].compactMap { $0 } }
}
