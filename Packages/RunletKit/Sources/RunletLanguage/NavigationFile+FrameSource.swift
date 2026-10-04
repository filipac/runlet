import Foundation
import RunletCore

extension NavigationFile {
    /// A read-only peek (#22) at a line of a stack frame's file (#8): vendor code, a file outside
    /// the project, or a project file when no external editor is set. A local copy of a Docker
    /// or SSH file also says where the target sees it.
    public init(frameSource file: FrameSourceFile, line: Int) {
        let origin: Origin = switch file.origin {
        case .project: .project
        case .vendor: .vendor
        case .outsideProject: .outsideProject
        }
        let position = LSPPosition(line: max(0, line - 1), character: 0)
        self.init(uri: URL(fileURLWithPath: file.hostPath).absoluteString, path: file.hostPath, range: LSPRange(start: position, end: position),
                  origin: origin, displayPath: file.displayPath, runtimePath: file.isLocalCopy ? file.runtimePath : nil,
                  runtimeLocation: file.isLocalCopy ? file.runtimeLocation : nil)
    }
}
