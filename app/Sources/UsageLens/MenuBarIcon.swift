import AppKit

/// 状态栏专用的单色模板图标：透镜代表“查看”，柱条代表“用量”。
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.black.setStroke()

        let lens = NSBezierPath(ovalIn: NSRect(x: 2, y: 5, width: 9, height: 9))
        lens.lineWidth = 1.5
        lens.stroke()

        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 9.5, y: 6.5))
        handle.line(to: NSPoint(x: 15, y: 1.5))
        handle.lineWidth = 1.8
        handle.lineCapStyle = .round
        handle.stroke()

        // 透镜内的三根柱条，保持 1px 级别，适合 macOS 菜单栏的紧凑尺寸。
        for (x, height) in [(4.5, 2.0), (6.5, 4.0), (8.5, 6.0)] {
            let bar = NSBezierPath()
            bar.move(to: NSPoint(x: x, y: 6.5))
            bar.line(to: NSPoint(x: x, y: 6.5 + height))
            bar.lineWidth = 1.2
            bar.lineCapStyle = .round
            bar.stroke()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
