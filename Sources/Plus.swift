import AppKit

/// Plus (an experiment, Settings › Plus marks): every window's corners marked with a thin +, as a print's
/// crop marks. A clear layer over the windows on each screen, which no click reaches, draws them; the
/// windows' frames are read from the window server, twenty times a second, so the marks follow a window
/// as it moves. A corner under another window has none.
enum PlusMarks {
    private static let key = "plus"
    /// each arm of a +, from its middle, and its line
    static let arm: CGFloat = 7
    static let line: CGFloat = 1.5

    static var on: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            apply()
        }
    }

    private static var layers: [NSWindow] = []
    private static var timer: Timer?
    private static var marked: [PlusMark] = []
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

    /// the corners to mark now, each with the arms it keeps (the window server's coordinates: from the
    /// top left of the main screen)
    private static func corners() -> [PlusMark] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        // front to back
        let windows: [CGRect] = list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 80, rect.height >= 60
            else { return nil }
            return rect
        }
        /// which window is seen at a point: the front one there, or none (-1)
        func seen(_ p: CGPoint) -> Int { windows.firstIndex { $0.contains(p) } ?? -1 }

        var marks: [PlusMark] = []
        for rect in windows {
            for p in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
            where !marks.contains(where: { abs($0.point.x - p.x) < 3 && abs($0.point.y - p.y) < 3 }) {
                // what is seen in the four quarters round it (up is towards the top of the screen)
                let e: CGFloat = 3
                let upRight = seen(CGPoint(x: p.x + e, y: p.y - e)), upLeft = seen(CGPoint(x: p.x - e, y: p.y - e))
                let downLeft = seen(CGPoint(x: p.x - e, y: p.y + e)), downRight = seen(CGPoint(x: p.x + e, y: p.y + e))
                let quarters = [upRight, upLeft, downLeft, downRight]
                let empty = quarters.filter { $0 < 0 }.count
                var arms: PlusMark.Arms = []
                if empty >= 3 {
                    // a window's corner standing free: the whole +
                    arms = .all
                } else if empty == 2 && upRight < 0 && upLeft < 0 {
                    // on the joined windows' top edge, where two meet: only the line between them
                    if downLeft != downRight { arms = [.up, .down] }
                } else if empty == 2 && downLeft < 0 && downRight < 0 {
                    // their bottom edge
                    if upLeft != upRight { arms = [.up, .down] }
                } else if empty == 2 && upLeft < 0 && downLeft < 0 {
                    // their left edge
                    if upRight != downRight { arms = [.left, .right] }
                } else if empty == 2 && upRight < 0 && downRight < 0 {
                    // their right edge
                    if upLeft != downLeft { arms = [.left, .right] }
                } else {
                    // among them: each arm along where two windows (or a window and the desk) meet, none into one
                    if upRight != upLeft { arms.insert(.up) }
                    if upRight != downRight { arms.insert(.right) }
                    if downLeft != downRight { arms.insert(.down) }
                    if upLeft != downLeft { arms.insert(.left) }
                }
                if !arms.isEmpty { marks.append(PlusMark(point: p, arms: arms)) }
            }
        }
        return marks
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
            view.marks = points.map { PlusMark(point: CGPoint(x: $0.point.x - origin.x, y: top - $0.point.y - origin.y), arms: $0.arms) }
                .filter { view.bounds.insetBy(dx: -arm, dy: -arm).contains($0.point) }
        }
    }
}

/// A +, with the arms it keeps.
struct PlusMark: Equatable {
    struct Arms: OptionSet, Equatable {
        let rawValue: Int
        static let up = Arms(rawValue: 1), right = Arms(rawValue: 2), down = Arms(rawValue: 4), left = Arms(rawValue: 8)
        static let all: Arms = [.up, .right, .down, .left]
    }
    var point: CGPoint
    var arms: Arms
}

/// The marks on one screen.
final class PlusView: NSView {
    var marks: [PlusMark] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !marks.isEmpty else { return }
        let path = NSBezierPath()
        let arm = PlusMarks.arm
        for mark in marks {
            // on the pixel grid (three of a Retina screen's), so the line is sharp
            let x = (mark.point.x).rounded() + 0.25, y = (mark.point.y).rounded() - 0.25
            let middle = NSPoint(x: x, y: y)
            // a line through the middle, whole, where both its arms are kept: no seam at the middle
            if mark.arms.contains([.left, .right]) {
                path.move(to: NSPoint(x: x - arm, y: y)); path.line(to: NSPoint(x: x + arm, y: y))
            } else if mark.arms.contains(.left) {
                path.move(to: NSPoint(x: x - arm, y: y)); path.line(to: middle)
            } else if mark.arms.contains(.right) {
                path.move(to: middle); path.line(to: NSPoint(x: x + arm, y: y))
            }
            if mark.arms.contains([.up, .down]) {
                path.move(to: NSPoint(x: x, y: y - arm)); path.line(to: NSPoint(x: x, y: y + arm))
            } else if mark.arms.contains(.up) {
                path.move(to: middle); path.line(to: NSPoint(x: x, y: y + arm))
            } else if mark.arms.contains(.down) {
                path.move(to: NSPoint(x: x, y: y - arm)); path.line(to: middle)
            }
        }
        path.lineWidth = PlusMarks.line
        // in the ink of the desk's words (FILE, SURF…) at rest
        ink(0.45).setStroke()
        path.stroke()
    }
}
