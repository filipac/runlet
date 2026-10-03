import AppKit

/// The editor's scroll view. It keeps the scroll position measured from the text's leading
/// and top edges when the clip view's content insets change (#78).
///
/// macOS 26 scroll views extend the clip view under the line-number ruler and set the clip
/// view's left inset to the ruler's thickness while tiling, so the leading edge is at
/// `bounds.origin.x == -contentInsets.left`. AppKit changes that inset without moving the
/// clip view: a new editor's first tile (installing a restored tab, or any tab created with
/// its code) left the origin at 0, and the ruler widening past 99 lines left it at the old
/// thickness. With soft wrap off and a line wider than the editor, the clip view could stay
/// there, so the first columns sat under the gutter.
final class EditorScrollView: NSScrollView {
    override func tile() {
        let clip = contentView
        let before = clip.contentInsets
        // How far the text is scrolled from its leading and top edges.
        let offset = NSPoint(x: clip.bounds.origin.x + before.left, y: clip.bounds.origin.y + before.top)
        super.tile()
        let after = clip.contentInsets
        guard after.left != before.left || after.top != before.top else { return }
        let target = NSPoint(x: offset.x - after.left, y: offset.y - after.top)
        let origin = clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        reflectScrolledClipView(clip)
    }
}
