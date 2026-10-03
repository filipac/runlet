import AppKit
import ImageIO
import RunletCore
import SwiftUI

/// A bounded string, with literal search, navigation, wrapping, and selectable text (#7).
struct StringTextViewer: View {
    let text: String
    var omittedBytes: Int?
    @State private var query = ""
    @State private var wraps = true
    @State private var matchIndex = 0

    var body: some View {
        let matches = StringSearch.matches(in: text, query: query)
        let index = matches.isEmpty ? 0 : matchIndex % matches.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Find in string", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("string-search")
                    .onChange(of: query) { matchIndex = 0 }
                Text(query.isEmpty ? "\(text.utf8.count) bytes" : matches.isEmpty ? "No matches" : "\(index + 1) of \(matches.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("string-match-count")
                Button { matchIndex = (index + matches.count - 1) % max(1, matches.count) } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous match").accessibilityIdentifier("string-previous-match").disabled(matches.isEmpty)
                Button { matchIndex = (index + 1) % max(1, matches.count) } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next match").accessibilityIdentifier("string-next-match").disabled(matches.isEmpty)
                Spacer(minLength: 0)
                Toggle("Wrap", isOn: $wraps).toggleStyle(.checkbox).accessibilityIdentifier("string-wrap")
            }
            .controlSize(.small)
            SearchableStringText(text: text, wraps: wraps, selection: matches.isEmpty ? nil : matches[index])
                .frame(height: 300)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.25)))
            if let omittedBytes, omittedBytes != 0 {
                Text(omittedBytes > 0 ? "\(omittedBytes) bytes not shown by the runner" : "String truncated by the runner")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

private struct SearchableStringText: NSViewRepresentable {
    let text: String
    let wraps: Bool
    let selection: NSRange?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isRichText = false
            view.isSelectable = true
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.textContainerInset = NSSize(width: 6, height: 6)
            view.setAccessibilityIdentifier("string-text")
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        scroll.hasHorizontalScroller = !wraps
        view.isHorizontallyResizable = !wraps
        view.isVerticallyResizable = true
        view.autoresizingMask = wraps ? [.width] : []
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = wraps
        view.textContainer?.containerSize = NSSize(width: wraps ? max(1, scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if wraps { view.setFrameSize(NSSize(width: scroll.contentSize.width, height: view.frame.height)) }
        if let selection, view.selectedRange() != selection {
            view.setSelectedRange(selection)
            view.scrollRangeToVisible(selection)
        }
    }
}

struct StringImageViewer: View {
    let payload: StringViewers.ImagePayload

    var body: some View {
        if payload.kind == .svg {
            // SVG is an image document: never inline active markup or allow remote loads.
            LockedWebView(html: "<img alt=\"SVG image\" style=\"max-width:100%;max-height:280px\" src=\"data:image/svg+xml;base64,\(payload.data.base64EncodedString())\">", remoteImages: false)
                .frame(height: 300)
                .accessibilityIdentifier("string-svg-preview")
        } else if let image = thumbnail {
            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 280)
                .accessibilityLabel("\(payload.kind.rawValue.uppercased()) image preview")
                .accessibilityIdentifier("string-image-preview")
        } else {
            Text("Image cannot be previewed (invalid data or dimensions above 4096×4096). Use Tree or Text to inspect the string.")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("string-image-unavailable")
        }
    }

    private var thumbnail: NSImage? {
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
