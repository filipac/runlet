import Foundation
import Testing
@testable import RunletCore

/// #271: the Logs window finds a driver's log files from its last declared `logPaths()`.
struct DriverLogPathMemoryTests {
    private func catalog(_ paths: [String]?, declared: Bool) -> ProjectCommandCatalog {
        var catalog = ProjectCommandCatalog()
        catalog.logPaths = paths ?? []
        catalog.logPathsDeclared = declared
        return catalog
    }

    @Test func aListingThatDeclaredPathsIsRemembered() {
        var memory = DriverLogPathMemory()
        #expect(!memory.knows("local:a", loaded: nil))
        let changed1 = memory.remember(catalog(["logs"], declared: true), for: "local:a")
        #expect(changed1)
        #expect(memory.paths(for: "local:a", loaded: nil) == ["logs"])
        #expect(memory.knows("local:a", loaded: nil))
        // The same again changes nothing (no save).
        let changed2 = memory.remember(catalog(["logs"], declared: true), for: "local:a")
        #expect(!changed2)
        // A new declaration replaces it.
        let changed3 = memory.remember(catalog(["logs", "var/app.log"], declared: true), for: "local:a")
        #expect(changed3)
        #expect(memory.paths(for: "local:a", loaded: nil) == ["logs", "var/app.log"])
    }

    @Test func aDriverWithNoLogPathsIsKnownToHaveNone() {
        var memory = DriverLogPathMemory()
        let changed4 = memory.remember(catalog([], declared: true), for: "docker:b")
        #expect(changed4)
        #expect(memory.knows("docker:b", loaded: nil))
        #expect(memory.paths(for: "docker:b", loaded: nil).isEmpty)
    }

    @Test func aListingThatDidntReachTheDriverChangesNothing() {
        var memory = DriverLogPathMemory(paths: ["local:a": ["logs"]])
        // A failed boot, or a target without a driver: logPathsDeclared stays false.
        let changed5 = memory.remember(catalog([], declared: false), for: "local:a")
        #expect(!changed5)
        #expect(memory.paths(for: "local:a", loaded: catalog([], declared: false)) == ["logs"])
        #expect(!memory.knows("local:c", loaded: catalog([], declared: false)))
    }

    @Test func aLoadedListingWinsOverTheRememberedOne() {
        let memory = DriverLogPathMemory(paths: ["local:a": ["old"]])
        #expect(memory.paths(for: "local:a", loaded: catalog(["new"], declared: true)) == ["new"])
        #expect(memory.knows("local:z", loaded: catalog([], declared: true)))
    }

    @Test func itRoundTripsAndForgets() throws {
        var memory = DriverLogPathMemory(paths: ["local:a": ["logs"], "ssh:b": []])
        let decoded = try JSONDecoder().decode(DriverLogPathMemory.self, from: JSONEncoder().encode(memory))
        #expect(decoded == memory)
        memory.forget("local:a")
        #expect(!memory.knows("local:a", loaded: nil))
    }
}
