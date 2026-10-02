import AppKit
import RunletCore
import SwiftUI
import WebKit

/// What a preview shows: rendered HTML, its source, and an optional plain-text body.
struct PreviewContent: Equatable {
    var title: String
    var subject: String?
    var html: String?
    var text: String?
    var omittedBytes: Int?
    var error: String?

    init(title: String, subject: String? = nil, html: String?, text: String? = nil, omittedBytes: Int? = nil, error: String? = nil) {
        self.title = title
        self.subject = subject
        self.html = html
        self.text = text
        self.omittedBytes = omittedBytes
        self.error = error
    }

    init(_ preview: HTMLPreview) {
        self.init(title: preview.title ?? "Preview", subject: preview.subject, html: preview.html, text: preview.text, omittedBytes: preview.htmlOmittedBytes, error: preview.error)
    }

    init(_ mail: MailRecord) {
        self.init(title: mail.subject ?? mail.mailable ?? "Message", subject: mail.subject, html: mail.html, text: mail.text, omittedBytes: mail.htmlOmittedBytes)
    }
}

/// A rendered preview with HTML, Text, and Source views. The web view runs no JavaScript,
/// loads nothing but `data:` URLs (remote images only when allowed for this preview), and
/// never navigates; clicked links open in the default browser.
struct HTMLPreviewView: View {
    enum Mode: String, CaseIterable { case html = "HTML", text = "Text", source = "Source" }

    let content: PreviewContent
    /// Height of the rendered area; nil fills the available space (preview windows).
    var height: CGFloat? = 380
    var showsOpenInWindow = true
    @State private var mode: Mode = .html
    @State private var remoteImages = false

    private var modes: [Mode] {
        Mode.allCases.filter { $0 != .text || content.text?.isEmpty == false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = content.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if content.html != nil || content.text != nil {
                HStack(spacing: 8) {
                    Picker("View", selection: $mode) {
                        ForEach(modes, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .accessibilityIdentifier("preview-mode-picker")
                    if mode == .html {
                        Toggle("Load Remote Images", isOn: $remoteImages)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .help("Emails often contain tracking pixels. Remote images stay blocked unless you allow them for this preview. Scripts never run.")
                    }
                    Spacer()
                    Menu {
                        if let html = content.html { Button("Copy HTML") { Pasteboard.copy(html) } }
                        if let text = content.text, !text.isEmpty { Button("Copy Text") { Pasteboard.copy(text) } }
                        if showsOpenInWindow { Button("Open in Window") { PreviewWindows.show(content) } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Copy or open this preview")
                }
                Group {
                    switch mode {
                    case .html:
                        if let html = content.html {
                            LockedWebView(html: html, remoteImages: remoteImages)
                                .accessibilityIdentifier("html-preview")
                        } else {
                            Text("No HTML body.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .text:
                        ReadOnlyTextView(text: content.text ?? "")
                    case .source:
                        ReadOnlyTextView(text: content.html ?? "")
                    }
                }
                .frame(height: height)
                .frame(maxHeight: height == nil ? .infinity : nil)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.25)))
                if let omitted = content.omittedBytes, omitted > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(omitted), countStyle: .file)) of HTML not shown (2 MiB limit)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

/// Content rules for previews, compiled once: block every load except `about:` and `data:`
/// URLs, optionally allowing remote images.
@MainActor
enum PreviewRules {
    private static var compiled: [Bool: WKContentRuleList] = [:]

    private static func source(remoteImages: Bool) -> String {
        var rules = [#"{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}"#]
        if remoteImages {
            rules.append(#"{"trigger": {"url-filter": "^https?://", "resource-type": ["image"]}, "action": {"type": "ignore-previous-rules"}}"#)
        }
        rules.append(#"{"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}}"#)
        rules.append(#"{"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}}"#)
        return "[" + rules.joined(separator: ",") + "]"
    }

    static func list(remoteImages: Bool) async throws -> WKContentRuleList {
        if let list = compiled[remoteImages] { return list }
        guard let store = WKContentRuleListStore.default() else { throw PreviewError.noRuleStore }
        guard let list = try await store.compileContentRuleList(forIdentifier: remoteImages ? "RunletPreviewImages" : "RunletPreviewStrict", encodedContentRuleList: source(remoteImages: remoteImages)) else {
            throw PreviewError.noRuleStore
        }
        compiled[remoteImages] = list
        return list
    }

    /// The document with a Content Security Policy in its head: nothing loads but `data:`
    /// URLs (and remote images when allowed), and no script runs. A second guard next to the
    /// content rules; a page's own policy can only restrict it further.
    static func document(_ html: String, remoteImages: Bool) -> String {
        let images = remoteImages ? "data: https: http:" : "data:"
        let meta = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \#(images); style-src 'unsafe-inline' data:; font-src data:; media-src data:">"#
        for pattern in ["<head(\\s[^>]*)?>", "<html(\\s[^>]*)?>"] {
            if let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let insertion = pattern.hasPrefix("<head") ? meta : "<head>\(meta)</head>"
                return html.replacingCharacters(in: range, with: html[range] + insertion)
            }
        }
        return meta + html
    }

    enum PreviewError: Error, CustomStringConvertible {
        case noRuleStore
        var description: String { "Runlet could not set up the blocking rules, so the preview stays off. Use Source to read the HTML." }
    }
}

/// WKWebView with JavaScript off, a non-persistent data store, content rules that block
/// every remote load, and no navigation. The HTML loads only after the rules are in place.
struct LockedWebView: NSViewRepresentable {
    let html: String
    let remoteImages: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        context.coordinator.load(html, remoteImages: remoteImages, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(html, remoteImages: remoteImages, into: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var loaded: (html: String, remoteImages: Bool)?
        var task: Task<Void, Never>?

        func load(_ html: String, remoteImages: Bool, into webView: WKWebView) {
            if let loaded, loaded.html == html, loaded.remoteImages == remoteImages { return }
            loaded = (html, remoteImages)
            task?.cancel()
            task = Task { @MainActor [weak webView] in
                do {
                    let rules = try await PreviewRules.list(remoteImages: remoteImages)
                    guard !Task.isCancelled, let webView else { return }
                    let controller = webView.configuration.userContentController
                    controller.removeAllContentRuleLists()
                    controller.add(rules)
                    webView.loadHTMLString(PreviewRules.document(html, remoteImages: remoteImages), baseURL: nil)
                } catch {
                    guard let webView else { return }
                    // Fail closed: show the reason, never the unprotected page.
                    webView.loadHTMLString("<p style=\"font: 13px -apple-system\">\(error)</p>", baseURL: nil)
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
            if navigationAction.navigationType == .linkActivated {
                // A click on a link: the user's browser or mail app, never this view.
                if ["http", "https", "mailto"].contains(scheme) { NSWorkspace.shared.open(url) }
                return .cancel
            }
            // Only the document Runlet loaded (about:blank) and inline frames.
            return scheme == "about" || scheme == "data" ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }
    }
}

/// Selectable monospaced text that handles large strings (HTML source, mail text bodies).
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }
}

/// Previews opened in their own resizable window (Open in Window).
@MainActor
enum PreviewWindows {
    private static var open: [ObjectIdentifier: NSWindow] = [:]

    static func show(_ content: PreviewContent) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = content.subject ?? content.title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HTMLPreviewView(content: content, height: nil, showsOpenInWindow: false).padding(10))
        window.center()
        let key = ObjectIdentifier(window)
        open[key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = open.removeValue(forKey: key) }
        }
        window.makeKeyAndOrderFront(nil)
    }
}
