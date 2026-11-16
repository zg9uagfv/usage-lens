import AppKit

/// 两只简洁的菜单栏眼睛；眨眼时将眼睛画成短弧线。
enum MenuBarIcon {
    static func make(blinking: Bool = false, alert: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 20))
        image.lockFocus()
        let color: NSColor = alert ? .systemRed : .black
        color.setStroke()
        color.setFill()

        for centerX in [7.0, 17.0] {
            if blinking {
                let lid = NSBezierPath()
                lid.move(to: NSPoint(x: centerX - 3.7, y: 10))
                lid.curve(to: NSPoint(x: centerX + 3.7, y: 10), controlPoint1: NSPoint(x: centerX - 1.8, y: 13), controlPoint2: NSPoint(x: centerX + 1.8, y: 13))
                lid.lineWidth = 1.9
                lid.lineCapStyle = .round
                lid.stroke()
            } else {
                let eye = NSBezierPath(ovalIn: NSRect(x: centerX - 3.7, y: 5, width: 7.4, height: 10))
                eye.lineWidth = 1.7
                eye.stroke()
                NSBezierPath(ovalIn: NSRect(x: centerX - 1.1, y: 8.1, width: 2.2, height: 2.5)).fill()
            }
        }

        image.unlockFocus()
        // 普通状态交给系统自动适配浅色/深色菜单栏；告警状态必须保留红色。
        image.isTemplate = !alert
        return image
    }
}
