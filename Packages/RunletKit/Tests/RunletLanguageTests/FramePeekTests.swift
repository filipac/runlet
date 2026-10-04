import Foundation
import RunletCore
import Testing
@testable import RunletLanguage

/// #8: a stack frame's line opens in the #22 read-only peek.
struct FramePeekTests {
    @Test func peekAtAFrameLine() {
        let vendor = FrameSourceFile(hostPath: "/Users/dev/shop/vendor/acme/pkg/Client.php", runtimePath: "/var/www/html/vendor/acme/pkg/Client.php",
                                     origin: .vendor, isLocalCopy: true, displayPath: "vendor/acme/pkg/Client.php", runtimeLocation: "the container")
        let file = NavigationFile(frameSource: vendor, line: 42)
        #expect(file.line == 42)
        #expect(file.range.start == LSPPosition(line: 41, character: 0))
        #expect(file.origin == .vendor)
        #expect(file.path == vendor.hostPath)
        #expect(file.uri == "file:///Users/dev/shop/vendor/acme/pkg/Client.php")
        #expect(file.fileName == "Client.php")
        // A local copy says where the container sees the file.
        #expect(file.runtimePath == "/var/www/html/vendor/acme/pkg/Client.php")
        #expect(file.runtimeLocation == "the container")
        let local = FrameSourceFile(hostPath: "/Users/dev/app/app/A.php", runtimePath: "/Users/dev/app/app/A.php", origin: .project, isLocalCopy: false, displayPath: "app/A.php")
        let project = NavigationFile(frameSource: local, line: 1)
        #expect(project.origin == .project)
        #expect(project.runtimePath == nil)
        #expect(project.runtimeLocation == nil)
    }
}
