import CoreGraphics
import Foundation

/// Export as SVG (#153): the relations diagram drawn from its layout model, not from the window,
/// so the file matches what the window shows and needs no rendering. Light colours, with a dark
/// variant for viewers that follow `prefers-color-scheme`.
public enum SQLRelationsSVG {
    public static func render(_ layout: SQLRelationsLayout, title: String? = nil) -> String {
        typealias Metrics = SQLRelationsLayout.Metrics
        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(n(layout.size.width))" height="\(n(layout.size.height))" viewBox="0 0 \(n(layout.size.width)) \(n(layout.size.height))" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace">

        """
        svg += "<title>\(escape(title ?? "Relations of \(layout.focus)"))</title>\n"
        svg += """
        <style>
        .bg { fill: #ffffff; }
        .box { fill: #ffffff; stroke: #c7c7cc; stroke-width: 1; }
        .box.focus { stroke: #0f9b8e; stroke-width: 2.5; }
        .box.missing { fill: #f7f7f7; stroke-dasharray: 5 4; }
        .header { fill: #f2f2f7; }
        .focus .header, .header.focus { fill: #dff3f1; }
        .title { font-size: \(n(Metrics.titleFontSize))px; font-weight: 600; fill: #1c1c1e; }
        .column { font-size: \(n(Metrics.columnFontSize))px; fill: #1c1c1e; }
        .type, .note { font-size: \(n(Metrics.typeFontSize))px; fill: #8e8e93; }
        .note { font-style: italic; }
        .pk { fill: #c99700; }
        .fk { fill: #2f6fdb; }
        .edge { fill: none; stroke: #8e8e93; stroke-width: 1.4; }
        .edge.collapsed { stroke-dasharray: 4 4; }
        .arrow { fill: #8e8e93; }
        .label rect { fill: #ffffff; stroke: #d1d1d6; stroke-width: 0.8; }
        .label text { font-size: \(n(Metrics.labelFontSize))px; fill: #3a3a3c; }
        .group { fill: #f2f2f7; stroke: #aeaeb2; stroke-dasharray: 5 4; }
        .group-title { font-size: 12px; font-weight: 600; fill: #3a3a3c; }
        @media (prefers-color-scheme: dark) {
          .bg, .box, .label rect { fill: #1e1e1e; }
          .box { stroke: #48484a; }
          .box.missing { fill: #262626; }
          .header, .group { fill: #2c2c2e; }
          .focus .header, .header.focus { fill: #12332f; }
          .title, .column { fill: #f2f2f7; }
          .label text, .group-title { fill: #d1d1d6; }
          .label rect { stroke: #48484a; }
        }
        </style>
        <rect class="bg" x="0" y="0" width="\(n(layout.size.width))" height="\(n(layout.size.height))"/>

        """
        // Lines first, under the tables.
        for edge in layout.edges {
            let d = "M \(p(edge.start)) C \(p(edge.control1)) \(p(edge.control2)) \(p(edge.end))"
            svg += "<path class=\"edge\(edge.relation == nil ? " collapsed" : "")\" d=\"\(d)\"><title>\(escape(edge.relation?.summary ?? "\(edge.count) foreign key\(edge.count == 1 ? "" : "s")"))</title></path>\n"
            svg += "<polygon class=\"arrow\" points=\"\(edge.arrowhead.map(p).joined(separator: " "))\"/>\n"
        }
        for box in layout.boxes {
            let f = box.frame
            let classes = ["box"] + (box.node.isFocus ? ["focus"] : []) + (box.node.isMissing ? ["missing"] : [])
            svg += "<g class=\"table\(box.node.isFocus ? " focus" : "")\">\n"
            svg += "<rect class=\"\(classes.joined(separator: " "))\" x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(f.height))\" rx=\"6\"/>\n"
            svg += "<rect class=\"header\(box.node.isFocus ? " focus" : "")\" x=\"\(n(f.minX + 1))\" y=\"\(n(f.minY + 1))\" width=\"\(n(f.width - 2))\" height=\"\(n(Metrics.headerHeight - 1))\" rx=\"5\"/>\n"
            let kind = box.node.table?.isView == true ? " (view)" : ""
            svg += "<text class=\"title\" x=\"\(n(f.minX + 10))\" y=\"\(n(f.minY + Metrics.headerHeight / 2 + 4))\">\(escape(box.node.name + kind))</text>\n"
            for (index, row) in box.rows.enumerated() {
                let y = n(box.rowCenter(index) + 4)
                if let note = row.note {
                    svg += "<text class=\"note\" x=\"\(n(f.minX + 10))\" y=\"\(y)\">\(escape(note))</text>\n"
                    continue
                }
                let marker = row.isPrimaryKey ? "<tspan class=\"pk\">PK </tspan>" : row.isForeignKey ? "<tspan class=\"fk\">FK </tspan>" : "<tspan class=\"type\">· </tspan>"
                svg += "<text class=\"column\" x=\"\(n(f.minX + 10))\" y=\"\(y)\">\(marker)\(escape(row.name))\(row.type.map { "<tspan class=\"type\" dx=\"8\">\(escape($0))</tspan>" } ?? "")</text>\n"
            }
            svg += "</g>\n"
        }
        for group in layout.groups {
            let f = group.frame
            svg += "<g class=\"collapsed-group\"><rect class=\"group\" x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(f.height))\" rx=\"8\"/>"
            svg += "<text class=\"group-title\" x=\"\(n(f.midX))\" y=\"\(n(f.minY + 19))\" text-anchor=\"middle\">\(escape(group.title))</text>"
            svg += "<text class=\"note\" x=\"\(n(f.midX))\" y=\"\(n(f.minY + 35))\" text-anchor=\"middle\">\(escape(group.subtitle))</text></g>\n"
        }
        // Labels last, over everything.
        for edge in layout.edges {
            guard let label = edge.label else { continue }
            let f = edge.labelFrame
            svg += "<g class=\"label\"><rect x=\"\(n(f.minX))\" y=\"\(n(f.minY))\" width=\"\(n(f.width))\" height=\"\(n(f.height))\" rx=\"4\"/><text>"
            for (index, line) in label.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                svg += "<tspan x=\"\(n(f.minX + 6))\" y=\"\(n(f.minY + 3 + Metrics.labelLineHeight * CGFloat(index + 1) - 3))\">\(escape(String(line)))</tspan>"
            }
            svg += "</text></g>\n"
        }
        svg += "</svg>\n"
        return svg
    }

    /// Text and attribute values with XML's five special characters escaped.
    static func escape(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default:
                // Control characters aren't allowed in XML 1.0.
                if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.value < 0x20, scalar != "\t", scalar != "\n" {
                    escaped += "\u{FFFD}"
                } else {
                    escaped.append(character)
                }
            }
        }
        return escaped
    }

    /// A number with at most one decimal, never in the Mac's locale.
    static func n(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    static func p(_ point: CGPoint) -> String { "\(n(point.x)) \(n(point.y))" }
}
