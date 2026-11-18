import AppKit

/// Plus (an experiment, Settings › Plus marks): every window's corners marked with a thin +, as a print's
/// crop marks. A clear layer over the windows on each screen, which no click reaches, draws them; the
/// windows' frames are read from the window server, twenty times a second, so the marks follow a window
/// as it moves. A corner under another window has none.
enum PlusMarks {
    private static let key = "plus"
    /// each arm of a +, from its middle, and its line
    static let arm: CGFloat = 7
    static let line: CGFloat = 1

    static var on: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            apply()
        }
    }

    private static var layers: [NSWindow] = []
    private static var timer: Timer?
    private static var marked: [CGPoint] = []
    private static var watching = false

    /// on or off, as kept; again when the screens change
    static func apply() {
        layers.forEach { $0.orderOut(nil) }
        layers = []
        timer?.invalidate()
        timer = nil
        marked = []
        if !watching {
            watching = true
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                if on { apply() }
            }
        }
        guard on else { return }
        layers = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentView = PlusView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            return window
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { _ in refresh() }
        refresh()
    }

    /// the corners to mark now (the window server's coordinates: from the top left of the main screen)
    private static func corners() -> [CGPoint] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var above: [CGRect] = []
        var points: [CGPoint] = []
        // front to back: a corner is marked unless a window in front of its own covers it
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 80, rect.height >= 60
            else { continue }
            for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            where !above.contains(where: { $0.insetBy(dx: 1, dy: 1).contains(corner) })
                && !points.contains(where: { abs($0.x - corner.x) < 2 && abs($0.y - corner.y) < 2 }) {
                points.append(corner)
            }
            above.append(rect)
        }
        return points
    }

    private static func refresh() {
        let points = corners()
        guard points != marked else { return }
        marked = points
        // the window server counts down from the main screen's top; AppKit up from its bottom
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        for layer in layers {
            guard let view = layer.contentView as? PlusView else { continue }
            let origin = layer.frame.origin
            view.points = points.map { CGPoint(x: $0.x - origin.x, y: top - $0.y - origin.y) }
                .filter { view.bounds.insetBy(dx: -arm, dy: -arm).contains($0) }
        }
    }
}

/// The marks on one screen.
final class PlusView: NSView {
    var points: [CGPoint] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !points.isEmpty else { return }
        let path = NSBezierPath()
        let arm = PlusMarks.arm
        for p in points {
            // on the pixel grid, so a 1pt line is sharp
            let x = (p.x).rounded() + 0.5, y = (p.y).rounded() - 0.5
            path.move(to: NSPoint(x: x - arm, y: y))
            path.line(to: NSPoint(x: x + arm, y: y))
            path.move(to: NSPoint(x: x, y: y - arm))
            path.line(to: NSPoint(x: x, y: y + arm))
        }
        path.lineWidth = PlusMarks.line
        // quiet: a mid grey, half see-through, that reads on light and dark windows alike without standing out
        NSColor(white: 0.55, alpha: 0.45).setStroke()
        path.stroke()
    }
}
