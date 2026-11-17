import AppKit

/// 選單列用的單色樣板圖示：依 Vibe Meter App icon 的「量規弧線＋脈搏線」重繪成小尺寸線條，
/// `isTemplate = true` 讓系統依淺色／深色選單列自動上色。
public enum MenuBarIcon {
    public static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width / 18
            NSColor.black.setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9 * s, y: 7.4 * s), radius: 6.9 * s, startAngle: 192, endAngle: -12, clockwise: true)
            arc.lineWidth = 1.7 * s
            arc.lineCapStyle = .round
            arc.stroke()
            let pulse = NSBezierPath()
            let points: [(CGFloat, CGFloat)] = [(4.6, 6.4), (7.0, 6.4), (7.6, 5.7), (8.7, 9.7), (10.0, 3.7), (10.9, 5.4), (13.4, 5.4)]
            pulse.move(to: NSPoint(x: points[0].0 * s, y: points[0].1 * s))
            for p in points.dropFirst() { pulse.line(to: NSPoint(x: p.0 * s, y: p.1 * s)) }
            pulse.lineWidth = 1.5 * s
            pulse.lineCapStyle = .round
            pulse.lineJoinStyle = .round
            pulse.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Vibe Meter"
        return image
    }
}
