import Foundation
import Testing

/// PHPantom sessions in the parallel package tests (#242). Each session indexes its whole
/// workspace (for most, the Laravel fixture's vendor/) on every core it gets. With all the
/// language suites running at once, ten sessions indexed together, and a request sent right after
/// opening a document sometimes came back empty (a hover without its docblock). So a test that
/// starts PHPantom holds a slot, and at most `limit` such tests run at once. Waiting suspends the
/// test; it doesn't block a thread. `LanguageTestSupport.session` fails a test without `.phpantom`.
struct PHPantomSlot: SuiteTrait, TestTrait, TestScoping {
    static let limit = 2

    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        // A suite's trait and a test's own both scope the test: only the outer one takes a slot.
        if PHPantomSlots.held {
            try await function()
            return
        }
        await PHPantomSlots.shared.acquire()
        do {
            try await PHPantomSlots.$held.withValue(true) { try await function() }
        } catch {
            await PHPantomSlots.shared.release()
            throw error
        }
        await PHPantomSlots.shared.release()
    }

    /// Called where a test starts PHPantom: a test without `.phpantom` fails, once.
    static func check() {
        guard let test = Test.current, Test.Case.current != nil, !test.traits.contains(where: { $0 is PHPantomSlot }) else { return }
        guard reported.first("\(test.id)") else { return }
        Issue.record("\(test.name) starts PHPantom but has no .phpantom trait (see PHPantomSessions.swift)", sourceLocation: test.sourceLocation)
    }

    private static let reported = Reported()

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: Set<String> = []
        func first(_ key: String) -> Bool { lock.withLock { keys.insert(key).inserted } }
    }
}

extension Trait where Self == PHPantomSlot {
    /// Starts PHPantom: waits for one of `PHPantomSlot.limit` slots.
    static var phpantom: Self { PHPantomSlot() }
}

/// A counting semaphore, first come first served.
actor PHPantomSlots {
    static let shared = PHPantomSlots()

    /// True inside a test that already holds a slot.
    @TaskLocal static var held = false

    private var inUse = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if inUse < PHPantomSlot.limit && waiting.isEmpty {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            inUse -= 1
        } else {
            // The slot passes straight to the next test.
            waiting.removeFirst().resume()
        }
    }
}
