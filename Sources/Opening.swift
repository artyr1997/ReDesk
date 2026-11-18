import AppKit

/// A Re app's window opening and closing, drawn by the desk under it. Opening: the corners' + come first,
/// round the window's whole width but a quarter of its height, in its middle; then the glass (or the paper)
/// fills them; then it grows to the window's height, and the window's interface fades in over it (the app
/// is told "show-window", as for a desktop coming back). Closing: the same, backwards.
/// The apps ask by a distributed notification, "open <pid> <window number>" or "close …" (their tell_desk).
enum Opening {
    static func listen() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.artursavytskyi.re.opening"), object: nil, queue: .main
        ) { note in
            guard let words = (note.object as? String)?.split(separator: " "), words.count == 3,
                  let pid = Int32(words[1]), let number = Int(words[2]) else { return }
            let closing = words[0] == "close"
            guard closing || words[0] == "open" else { return }
            begin(pid: pid, number: number, closing: closing, tries: 12)
        }
    }

    /// The app asks the moment it shows its window, which the window server may not have yet: asked again
    /// a little later, a few times
    private static func begin(pid: Int32, number: Int, closing: Bool, tries: Int) {
        if let stage = WindowStage(pid: pid, number: number, closing: closing) { return stage.start() }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { begin(pid: pid, number: number, closing: closing, tries: tries - 1) }
    }
}

/// One opening or closing.
final class WindowStage {
    private static var running: [WindowStage] = []

    let pid: Int32
    let number: Int
    let closing: Bool
    private let window: NSWindow
    private let view: StageView
    private var timer: Timer?
    private let begun = Date()
    private var told = false
    /// the app's window, where it is now (AppKit's coordinates)
    private var frame: NSRect

    // the times, in seconds: opening …
    private static let open = (plus: 0.10, fill: (0.06, 0.20), grow: (0.20, 0.44), show: 0.40, out: (0.55, 0.80))
    // … and closing
    private static let close = (shrink: (0.20, 0.42), fill: (0.40, 0.54), plus: (0.52, 0.66))
    private static let margin: CGFloat = 12

    init?(pid: Int32, number: Int, closing: Bool) {
        guard let frame = WindowStage.frame(of: number) else { return nil }
        self.pid = pid
        self.number = number
        self.closing = closing
        self.frame = frame
        window = NSWindow(contentRect: frame.insetBy(dx: -Self.margin, dy: -Self.margin), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        view = StageView(frame: NSRect(origin: .zero, size: window.frame.size), margin: Self.margin)
        window.contentView = view
    }

    /// a window's frame, from the window server (which counts down from the main screen's top)
    static func frame(of number: Int) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    func start() {
        // under the app's own window
        window.order(.below, relativeTo: number)
        Self.running.append(self)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func finish() {
        timer?.invalidate()
        window.orderOut(nil)
        Self.running.removeAll { $0 === self }
    }

    private static func ease(_ t: Double) -> CGFloat {
        let t = min(1, max(0, t))
        return CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
    }

    private static func part(_ t: Double, _ span: (Double, Double)) -> Double { (t - span.0) / (span.1 - span.0) }

    private func tick() {
        let t = Date().timeIntervalSince(begun)
        // the window may be moving (tiled into its place): the stage follows it
        if let now = Self.frame(of: number), now != frame {
            frame = now
            window.setFrame(frame.insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
            view.frame = NSRect(origin: .zero, size: window.frame.size)
        }
        var height: CGFloat, fill: CGFloat, plus: CGFloat
        if !closing {
            let o = Self.open
            plus = Self.ease(t / o.plus)
            fill = Self.ease(Self.part(t, o.fill))
            height = 0.25 + 0.75 * Self.ease(Self.part(t, o.grow))
            if t >= o.show && !told {
                told = true
                // the interface comes, over the glass
                DistributedNotificationCenter.default().postNotificationName(
                    .init("com.artursavytskyi.re.windows"), object: "show-window \(pid) \(number)", userInfo: nil, deliverImmediately: true)
            }
            // the window's own over it now: the stage goes
            let out = 1 - Self.ease(Self.part(t, o.out))
            window.alphaValue = out
            if t >= o.out.1 { return finish() }
        } else {
            let c = Self.close
            height = 1 - 0.75 * Self.ease(Self.part(t, c.shrink))
            fill = 1 - Self.ease(Self.part(t, c.fill))
            plus = 1 - Self.ease(Self.part(t, c.plus))
            if t >= c.plus.1 { return finish() }
        }
        view.set(height: height, fill: fill, plus: plus)
    }
}

/// The stage: the glass (or paper) of the window, as tall as it has grown, and the + at its corners.
final class StageView: NSView {
    private let margin: CGFloat
    private var height: CGFloat = 0.25
    private var fill: CGFloat = 0
    private var plus: CGFloat = 0
    private let glass = NSVisualEffectView()

    init(frame: NSRect, margin: CGFloat) {
        self.margin = margin
        super.init(frame: frame)
        wantsLayer = true
        if Glass.on {
            // as the apps' glass (their set_glass): the dark HUD blur, square corners
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.alphaValue = 0
            addSubview(glass)
        }
    }

    required init?(coder: NSCoder) { nil }

    func set(height: CGFloat, fill: CGFloat, plus: CGFloat) {
        self.height = height
        self.fill = fill
        self.plus = plus
        if Glass.on {
            glass.frame = box()
            glass.alphaValue = fill
        }
        needsDisplay = true
    }

    /// the window's whole width, `height` of its height, in its middle
    private func box() -> NSRect {
        let whole = bounds.insetBy(dx: margin, dy: margin)
        let h = (whole.height * height).rounded()
        return NSRect(x: whole.minX, y: (whole.midY - h / 2).rounded(), width: whole.width, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = box()
        if !Glass.on && fill > 0 {
            // the apps' paper, light or dark, its corners round as theirs
            let paper = Appearance.dark ? NSColor(white: 0.114, alpha: 1) : NSColor(white: 0.957, alpha: 1)
            paper.withAlphaComponent(fill).setFill()
            NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        }
        guard plus > 0 else { return }
        let path = NSBezierPath()
        let arm = PlusMarks.arm
        for corner in [NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY),
                       NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.maxX, y: box.maxY)] {
            let x = corner.x.rounded() + 0.25, y = corner.y.rounded() - 0.25
            path.move(to: NSPoint(x: x - arm, y: y)); path.line(to: NSPoint(x: x + arm, y: y))
            path.move(to: NSPoint(x: x, y: y - arm)); path.line(to: NSPoint(x: x, y: y + arm))
        }
        path.lineWidth = PlusMarks.line
        ink(0.45 * plus).setStroke()
        path.stroke()
    }
}
