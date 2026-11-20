import AppKit
import QuartzCore

/// The dial (Settings › Clock face): the screen's edge as a clock's face. Sixty short ticks go round it, spread
/// evenly along the edge from the top's middle, clockwise: so twelve is at the top's middle, three at the
/// right's, six at the bottom's, nine at the left's; every fifth tick (the hours') longer. On it the time: the
/// second a dot stepping from tick to tick, the minute a long line, the hour the desk's ◆, gone on between
/// its ticks as far as the hour has. Under every window, over the wallpaper; no click stops on it.
enum Dial {
    private static let key = "dial"

    static var on: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            apply()
        }
    }

    private static var faces: [NSWindow] = []
    private static var timer: Timer?
    private static var watching = false

    /// on or off, as kept; again when the screens change
    static func apply() {
        faces.forEach { $0.orderOut(nil) }
        faces = []
        timer?.invalidate()
        timer = nil
        if !watching {
            watching = true
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                if on { apply() }
            }
        }
        guard on else { return }
        faces = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            // as the desk's other pieces: just above the desktop icons, under every window
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.isReleasedWhenClosed = false
            // the face round what the menu bar and the Dock leave of the screen
            let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            window.contentView = DialView(frame: NSRect(origin: .zero, size: screen.frame.size), face: visible, scale: screen.backingScaleFactor)
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            return window
        }
        tick(animated: false)
        // on each whole second
        let next = Date(timeIntervalSince1970: (Date().timeIntervalSince1970).rounded(.down) + 1)
        let t = Timer(fire: next, interval: 1, repeats: true) { _ in tick(animated: true) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func tick(animated: Bool) {
        let now = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let s = Double(now.second ?? 0), m = Double(now.minute ?? 0), h = Double(now.hour ?? 0)
        for face in faces {
            (face.contentView as? DialView)?.show(second: s / 60, minute: (m + s / 60) / 60,
                                                  hour: (h.truncatingRemainder(dividingBy: 12) + m / 60) / 12, animated: animated)
        }
    }
}

/// One screen's face: the ticks drawn once, the hands as layers moved on each second.
final class DialView: NSView {
    /// where the face is (the screen but the menu bar and the Dock), its edge a little in from it
    private let edge: NSRect
    private let ticks = CAShapeLayer()
    private let second = CAShapeLayer()
    private let minute = CAShapeLayer()
    private let hour = CAShapeLayer()

    /// how far in from the edge each piece reaches
    static let inset: CGFloat = 3
    static let tick: CGFloat = 4, hourTick: CGFloat = 9
    static let minuteHand: CGFloat = 20
    static let secondAt: CGFloat = 14, hourAt: CGFloat = 30

    init(frame: NSRect, face: NSRect, scale: CGFloat) {
        edge = face.insetBy(dx: Self.inset, dy: Self.inset)
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        for l in [ticks, second, minute, hour] {
            l.contentsScale = scale
            l.fillColor = nil
            l.strokeColor = nil
            root.addSublayer(l)
        }

        // the sixty ticks, across the edge (straight in from it), on the pixel grid
        let path = CGMutablePath()
        for i in 0..<60 {
            let (p, n) = place(Double(i) / 60)
            let length = i % 5 == 0 ? Self.hourTick : Self.tick
            path.move(to: CGPoint(x: p.x.rounded() + 0.25, y: p.y.rounded() + 0.25))
            path.addLine(to: CGPoint(x: p.x.rounded() + 0.25 + n.dx * length, y: p.y.rounded() + 0.25 + n.dy * length))
        }
        ticks.path = path
        ticks.strokeColor = ink(0.3).cgColor
        ticks.lineWidth = 1

        // the second: a dot
        second.path = CGPath(ellipseIn: CGRect(x: -2, y: -2, width: 4, height: 4), transform: nil)
        second.fillColor = ink(0.6).cgColor

        // the minute: a line in from the edge (drawn upward; turned to point in)
        let line = CGMutablePath()
        line.move(to: .zero)
        line.addLine(to: CGPoint(x: 0, y: Self.minuteHand))
        minute.path = line
        minute.strokeColor = ink(0.6).cgColor
        minute.lineWidth = 2
        minute.lineCap = .round

        // the hour: ◆
        let d: CGFloat = 5
        let diamond = CGMutablePath()
        diamond.addLines(between: [CGPoint(x: 0, y: d), CGPoint(x: d, y: 0), CGPoint(x: 0, y: -d), CGPoint(x: -d, y: 0)])
        diamond.closeSubpath()
        hour.path = diamond
        hour.fillColor = ink(0.6).cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A point `f` of the way round the edge (0 the top's middle, clockwise), and the way in from there.
    private func place(_ f: Double) -> (CGPoint, CGVector) {
        let w = edge.width, h = edge.height
        var s = CGFloat(f - f.rounded(.down)) * 2 * (w + h)
        if s < w / 2 { return (CGPoint(x: edge.midX + s, y: edge.maxY), CGVector(dx: 0, dy: -1)) }
        s -= w / 2
        if s < h { return (CGPoint(x: edge.maxX, y: edge.maxY - s), CGVector(dx: -1, dy: 0)) }
        s -= h
        if s < w { return (CGPoint(x: edge.maxX - s, y: edge.minY), CGVector(dx: 0, dy: 1)) }
        s -= w
        if s < h { return (CGPoint(x: edge.minX, y: edge.minY + s), CGVector(dx: 1, dy: 0)) }
        s -= h
        return (CGPoint(x: edge.minX + s, y: edge.maxY), CGVector(dx: 0, dy: -1))
    }

    /// the hands where `second`, `minute` and `hour` (each a share of its round) put them
    func show(second s: Double, minute m: Double, hour h: Double, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        let (sp, sn) = place(s)
        second.position = CGPoint(x: sp.x + sn.dx * Self.secondAt, y: sp.y + sn.dy * Self.secondAt)
        let (mp, mn) = place(m)
        minute.position = mp
        minute.setAffineTransform(CGAffineTransform(rotationAngle: atan2(mn.dy, mn.dx) - .pi / 2))
        let (hp, hn) = place(h)
        hour.position = CGPoint(x: hp.x + hn.dx * Self.hourAt, y: hp.y + hn.dy * Self.hourAt)
        CATransaction.commit()
    }
}
