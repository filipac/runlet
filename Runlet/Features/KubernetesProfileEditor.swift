import AppKit
import RunletCore
import RunletExecution
import SwiftUI

extension KubernetesProfile {
    static func newDraft() -> Self { Self(name: "", context: "", namespace: "", labelSelector: "", container: "") }
    var normalizedForSaving: Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.namespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.labelSelector = labelSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.container = container.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.kubeconfig?.isEmpty == true { copy.kubeconfig = nil }
        if copy.localSourcePath?.isEmpty == true { copy.localSourcePath = nil }
        return copy
    }
}

/// The same draft form in Profiles and New Kubernetes Profile (#33). Listing never execs.
struct KubernetesProfileForm: View {
    @Environment(AppModel.self) private var model
    @Binding var profile: KubernetesProfile
    @State private var contexts: [String] = []
    @State private var namespaces: [String] = []
    @State private var pods: [KubernetesPod] = []
    @State private var search = ""
    @State private var listing = false

    var body: some View {
        Form {
            TextField("Name", text: $profile.name).accessibilityIdentifier("kubernetes-name")
            HStack {
                TextField("Kubeconfig", text: optional($profile.kubeconfig), prompt: Text("kubectl default")).accessibilityIdentifier("kubernetes-kubeconfig")
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK { profile.kubeconfig = panel.url?.path }
                }.accessibilityIdentifier("kubernetes-browse-config")
            }
            HStack {
                TextField("Context", text: $profile.context).accessibilityIdentifier("kubernetes-context")
                Menu("Choose Context") {
                    ForEach(contexts, id: \.self) { context in Button(context) { profile.context = context } }
                }.accessibilityIdentifier("kubernetes-context-list")
                Button("Load Contexts") { load { cli in contexts = try await cli.contexts() } }.accessibilityIdentifier("kubernetes-load-contexts")
            }
            HStack {
                TextField("Namespace", text: $profile.namespace).accessibilityIdentifier("kubernetes-namespace")
                Menu("Choose Namespace") {
                    ForEach(namespaces, id: \.self) { namespace in Button(namespace) { profile.namespace = namespace } }
                }.accessibilityIdentifier("kubernetes-namespace-list")
                Button("Load Namespaces") { load { cli in namespaces = try await cli.namespaces() } }
                    .disabled(profile.context.isEmpty).accessibilityIdentifier("kubernetes-load-namespaces")
            }
            HStack {
                TextField("Label selector", text: $profile.labelSelector, prompt: Text("app=shop")).accessibilityIdentifier("kubernetes-selector")
                Button("List Pods") { listPods() }.disabled(listing || profile.context.isEmpty || profile.namespace.isEmpty || profile.labelSelector.isEmpty).accessibilityIdentifier("kubernetes-list-pods")
            }
            TextField("Filter pods", text: $search).accessibilityIdentifier("kubernetes-pod-filter")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(pods.filter { matchesSearch(search, in: $0.name, $0.node) }) { pod in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pod.name).font(.callout).textSelection(.enabled)
                            Text("\(pod.phase) · \(pod.node) · \(pod.readyContainers.count)/\(pod.containers.count) ready · \(pod.restarts) restarts · \(pod.ageDescription)").font(.caption).foregroundStyle(.secondary)
                        }.accessibilityIdentifier("kubernetes-pod-\(pod.name)")
                    }
                    if pods.isEmpty { Text("List Pods to See Matches").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 100)
            HStack {
                TextField("Container", text: $profile.container).accessibilityIdentifier("kubernetes-container")
                Menu("Choose Container") {
                    ForEach(Array(Set(pods.flatMap(\.containers))).sorted(), id: \.self) { name in
                        Button(name) { profile.container = name }
                    }
                }.accessibilityIdentifier("kubernetes-container-list")
            }
            TextField("Working directory", text: $profile.workingDirectory).accessibilityIdentifier("kubernetes-directory")
            TextField("PHP executable", text: $profile.phpExecutable).accessibilityIdentifier("kubernetes-php")
            TextField("Temporary directory", text: $profile.temporaryDirectory).accessibilityIdentifier("kubernetes-temp")
            TextField("Local source", text: optional($profile.localSourcePath)).accessibilityIdentifier("kubernetes-local-source")
            TextField("Language PHP version", text: optional($profile.languagePHPVersion), prompt: Text("Automatic")).accessibilityIdentifier("kubernetes-language-php")
            Picker("Environment", selection: Binding(get: { profile.environment ?? .development }, set: { profile.environment = $0 })) {
                ForEach(TargetEnvironment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.accessibilityIdentifier("kubernetes-environment")
            Picker("Color", selection: $profile.color) {
                Text("Default").tag(nil as TargetColor?)
                ForEach(TargetColor.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
            }.accessibilityIdentifier("kubernetes-color")
            Picker("Strict types", selection: $profile.strictTypes) {
                Text("Default").tag(nil as Bool?); Text("On").tag(Optional(true)); Text("Off").tag(Optional(false))
            }.accessibilityIdentifier("kubernetes-strict-types")
            Picker("Mail", selection: $profile.interceptMail) {
                Text("Default").tag(nil as Bool?); Text("Intercept").tag(Optional(true)); Text("Send").tag(Optional(false))
            }.accessibilityIdentifier("kubernetes-mail")
            Toggle("Resolve when opened", isOn: $profile.autoResolve).accessibilityIdentifier("kubernetes-auto-resolve")
            Toggle("Replicas are interchangeable", isOn: $profile.interchangeableReplicas).accessibilityIdentifier("kubernetes-interchangeable")
            if let pin = profile.pinnedPod {
                HStack {
                    Text("Pinned to \(pin.name)").font(.caption)
                    Button("Unpin Pod") { profile.pinnedPod = nil }.accessibilityIdentifier("kubernetes-unpin")
                }
            }
            Text("The pod spec sets the execution user. Runs need PHP and env in the container. Opening this profile never runs code.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugKubernetesList)) { _ in listPods() }
        #endif
        .task(id: [profile.kubeconfig ?? "", profile.context, profile.namespace, profile.labelSelector]) {
            guard !profile.context.isEmpty, !profile.namespace.isEmpty, !profile.labelSelector.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation() } catch { return }
            listPods()
        }
        .onChange(of: profile.labelSelector) { _, _ in pods = []; profile.pinnedPod = nil }
        .onChange(of: profile.context) { _, _ in pods = []; namespaces = []; profile.pinnedPod = nil }
        .onChange(of: profile.namespace) { _, _ in pods = []; profile.pinnedPod = nil }
        .onChange(of: profile.kubeconfig) { _, _ in pods = []; contexts = []; namespaces = []; profile.pinnedPod = nil }
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
    private func load(_ operation: @escaping @MainActor (KubernetesCLI) async throws -> Void) {
        Task {
            do { try await operation(model.kubernetesCLI(profile)) }
            catch { model.alert = AppAlert(title: "Couldn't read Kubernetes configuration", message: "\(error)") }
        }
    }
    private func listPods() {
        let requested = profile
        listing = true
        Task {
            defer { listing = false }
            do {
                let found = try await model.kubernetesCLI(requested).pods(selector: requested.labelSelector)
                if profile.context == requested.context, profile.namespace == requested.namespace, profile.labelSelector == requested.labelSelector, profile.kubeconfig == requested.kubeconfig { pods = found }
            } catch { model.alert = AppAlert(title: "Couldn't list pods", message: "\(error)") }
        }
    }
}

struct KubernetesProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: KubernetesProfile
    var onSave: (KubernetesProfile) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kubernetes Profile").font(.headline)
            KubernetesProfileForm(profile: $profile)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("kubernetes-cancel")
                Button("Save") { onSave(profile.normalizedForSaving); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(!profile.normalizedForSaving.validate().isEmpty).accessibilityIdentifier("kubernetes-save")
            }
        }.padding(20).frame(width: 640, height: 760)
        .accessibilityElement(children: .contain).accessibilityIdentifier("kubernetes-profile-sheet")
    }
}

struct KubernetesPodChoiceSheet: View {
    @Environment(AppModel.self) private var model
    var choice: KubernetesChoice
    @State private var selected: String?
    @State private var pin = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Pod").font(.headline)
            Text("\(choice.profile.context) / \(choice.profile.namespace) · \(choice.profile.container)").foregroundStyle(.secondary)
            Text("This choice applies to the next run. Nothing runs until you press Run again.")
            List(choice.pods, selection: $selected) { pod in
                VStack(alignment: .leading, spacing: 4) {
                    Text(pod.name)
                    Text("Ready · \(pod.node) · \(pod.restarts) restarts · \(pod.ageDescription)").font(.caption).foregroundStyle(.secondary)
                }.tag(pod.id)
            }.frame(height: 200).accessibilityIdentifier("kubernetes-pod-choice-list")
            Toggle("Pin this pod until I choose again", isOn: $pin).accessibilityIdentifier("kubernetes-pin")
            HStack {
                Spacer()
                Button("Cancel") { model.kubernetesChoice = nil }.keyboardShortcut(.cancelAction).accessibilityIdentifier("kubernetes-choice-cancel")
                Button("Choose Pod") {
                    if let pod = choice.pods.first(where: { $0.id == selected }) { model.confirmKubernetesPod(pod, choice: choice, pin: pin) }
                }.keyboardShortcut(.defaultAction).disabled(selected == nil).accessibilityIdentifier("kubernetes-choice-confirm")
            }
        }.padding(20).frame(width: 640).accessibilityElement(children: .contain).accessibilityIdentifier("kubernetes-choice-sheet")
    }
}

/// Window-owned sheet requests (#33), held on the model so multiple windows cannot present one request.
struct KubernetesEditorRequest: Identifiable {
    let id = UUID()
    var windowId: UUID
    var profile: KubernetesProfile
}

struct KubernetesSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    private var choice: Binding<KubernetesChoice?> {
        Binding(get: {
            guard let choice = model.kubernetesChoice, window.tabs.contains(where: { $0.id == choice.tabId }) else { return nil }
            return choice
        }, set: { if $0 == nil { model.kubernetesChoice = nil } })
    }
    private var editor: Binding<KubernetesEditorRequest?> {
        Binding(get: { model.kubernetesEditor?.windowId == window.id ? model.kubernetesEditor : nil },
                set: { if $0 == nil { model.kubernetesEditor = nil } })
    }
    func body(content: Content) -> some View {
        content.sheet(item: choice) { KubernetesPodChoiceSheet(choice: $0) }
            .sheet(item: editor) { request in
                KubernetesProfileEditor(profile: request.profile) { saved in
                    model.saveKubernetesProfile(saved)
                    if let tab = window.selectedTab { model.setTarget(.kubernetes(saved.id), for: tab) }
                }
            }
    }
}

private extension KubernetesPod {
    var ageDescription: String {
        guard let date = ISO8601DateFormatter().date(from: created) else { return "Unknown age" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
