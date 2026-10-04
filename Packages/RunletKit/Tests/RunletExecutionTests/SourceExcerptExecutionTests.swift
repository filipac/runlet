import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// #8: a real exception from a project (a copy of the Composer fixture with a class that throws
/// through vendor code) gives frames whose source excerpts resolve on this Mac.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SourceExcerptExecutionTests {
    static let invoice = """
    <?php

    namespace Acme\\Billing;

    class Invoice
    {
        public function total(array $lines): int
        {
            return \\Acme\\Pipeline\\run($lines, function (int $cents) {
                return $this->checked($cents);
            });
        }

        private function checked(int $cents): int
        {
            if ($cents < 0) {
                throw new \\DomainException("Negative line: $cents");
            }

            return $cents;
        }
    }

    """

    static let pipeline = """
    <?php

    namespace Acme\\Pipeline;

    function run(array $items, callable $step): int
    {
        $sum = 0;
        foreach ($items as $item) {
            $sum += $step($item);
        }

        return $sum;
    }

    """

    /// A copy of the Composer fixture under its real path (PHP reports real paths).
    private func project() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-excerpts-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: TestSupport.fixtures.appendingPathComponent("composer"), to: base)
        try DriverSupport.write(["src/Billing/Invoice.php": Self.invoice, "vendor/acme/pipeline/pipeline.php": Self.pipeline], into: base)
        let real = try #require(realpath(base.path, nil))
        defer { free(real) }
        return String(cString: real)
    }

    @Test func exceptionFramesResolveToExcerpts() async throws {
        let directory = try project()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let target = TestSupport.localTarget(directory, php: TestSupport.php()!)
        let code = "require 'vendor/acme/pipeline/pipeline.php';\n$invoice = new Acme\\Billing\\Invoice();\n$invoice->total([100, -5]);"
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: code)
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        let error = try #require(events.errors.first)
        #expect(error.className == "DomainException")
        let resolver = FrameSourceResolver.forSnapshot(target, localSource: nil)
        let store = SourceExcerptStore()

        // The card's own location: where it was thrown, in a project file.
        let errorFile = try #require(error.file)
        let errorLine = try #require(error.line)
        let thrownIn = try #require(resolver.locate(errorFile).file)
        #expect(thrownIn.origin == .project)
        #expect(thrownIn.displayPath == "src/Billing/Invoice.php")
        #expect(!thrownIn.isLocalCopy)
        let thrown = try await store.file(thrownIn.hostPath, line: errorLine, run: request.runId).get()
        #expect(thrown.lines.count == 5)
        #expect(thrown.lines.first { $0.number == thrown.focusLine }?.text.contains("throw new \\DomainException") == true)

        let trace = try #require(error.trace)
        // The first project frame: the closure's call of checked().
        let projectFrame = try #require(trace.first { $0.file.map { resolver.locate($0).file?.origin == .project } ?? false })
        let projectFile = try #require(projectFrame.file)
        let projectLine = try #require(projectFrame.line)
        let projectExcerpt = try await store.file(projectFile, line: projectLine, run: request.runId).get()
        #expect(projectExcerpt.lines.first { $0.number == projectExcerpt.focusLine }?.text.contains("$this->checked($cents)") == true)

        // The vendor frame that called the closure.
        let vendorFrame = try #require(trace.first { $0.file.map { resolver.locate($0).file?.origin == .vendor } ?? false })
        #expect(resolver.locate(vendorFrame.file!).file?.displayPath == "vendor/acme/pipeline/pipeline.php")
        let vendorLine = try #require(vendorFrame.line)
        let vendorExcerpt = try await store.file(vendorFrame.file!, line: vendorLine, run: request.runId).get()
        #expect(vendorExcerpt.lines.first { $0.number == vendorExcerpt.focusLine }?.text.contains("$step($item)") == true)

        // The snippet's own frame reads the code that ran.
        let snippetFrame = try #require(trace.first { $0.inSnippet == true })
        let snippetLine = try #require(snippetFrame.snippetLine)
        let snippetExcerpt = try await store.snippet(request, snippetLine: snippetLine).get()
        #expect(snippetExcerpt.focusLine == 3)
        #expect(snippetExcerpt.lines.map(\.text) == code.components(separatedBy: "\n"))

        // The same frame read again for this run comes from the store.
        let reads = await store.fileReads
        _ = await store.file(projectFile, line: projectLine, run: request.runId)
        #expect(await store.fileReads == reads)
    }
}
