import RunletCore
import RunletExecution
import SwiftUI

// STUB — to be implemented (see agent task). Contract:
// DockerProfileEditor(profile: DockerProfile, isNew: Bool, onSave: (DockerProfile) -> Void)
struct DockerProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: DockerProfile
    var isNew: Bool
    var onSave: (DockerProfile) -> Void

    var body: some View {
        VStack {
            Text("Docker profile editor (stub)")
            Button("Close") { dismiss() }
        }
        .padding()
    }
}
