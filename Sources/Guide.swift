import AppKit
import AVFoundation

/// The guide: a popup over the whole screen (opening as the apps' windows do), one thing ReDesk does a slide,
/// its words on the left and on the right a few seconds of the film showing it (Resources/guide/*.mp4, looped,
/// silent; a picture for the popups). ← → or BACK / NEXT step through the slides. It opens by itself the first
/// time ReDesk starts, and with ⌘G (DeskKey.guide) whenever one likes.
final class GuidePopup: Popup {
    static let shared = GuidePopup(width: 1600)

    /// one slide: its title, its words, the keys it is about, and what it shows (a film in guide/, or a picture)
    struct Slide {
        let title: String
        let words: String
        let keys: () -> String
        let media: String?
    }

    private static func key(_ k: DeskKey) -> String { k.shortcut.text }

    static let slides: [Slide] = [
        Slide(title: "Welcome to re: desk",
              words: "re: desk is the desk your Re apps live on: four words in the corners, your windows tiled in the middle, the wallpaper behind them. This guide shows what it does, one thing a slide.",
              keys: { "→  the next slide" }, media: "welcome.mp4"),
        Slide(title: "Open an app",
              words: "Click a word in a corner: FILE, SURF, TERM or NOTE opens ReFile, ReSurf, ReTerm or ReNote. With nothing but the desk in front, its letter alone does it too.",
              keys: { [DeskKey.openFile, .openSurf, .openTerm, .openNote].map(key).joined(separator: "   ") }, media: "open.mp4"),
        Slide(title: "Windows, tiled",
              words: "The Re apps' windows share the middle of the desk by themselves: open four and they stand side by side on one screen. Turn tiling off and they float where you leave them; turn it on and each glides back to its place.",
              keys: { "\(key(.tiling))  tiling on / off" }, media: "tiling.mp4"),
        Slide(title: "Six arrangements",
              words: "Choose how they stand: Main and Stack, Main on Top, Main in the Middle, Grid, One at a Time or Fibonacci. Step to the next one, or make the window in front the main one.",
              keys: { "\(key(.arrange1)) … \(key(.arrange6))   \(key(.nextArrangement))  the next   \(key(.promote))  the main one" }, media: "arrange.mp4"),
        Slide(title: "Move and resize",
              words: "Move the focus to the nearest window, trade places with it, or make it wider and narrower, all from the keyboard. You can drag a window onto another to swap them, or pull the edge between two.",
              keys: { "\(key(.focusLeft)) \(key(.focusRight)) \(key(.focusUp)) \(key(.focusDown))  focus\n\(key(.tradeLeft)) \(key(.tradeRight)) \(key(.tradeUp)) \(key(.tradeDown))  trade places\n\(key(.resizeLeft)) \(key(.resizeRight)) \(key(.resizeUp)) \(key(.resizeDown))  resize" },
              media: "resize.mp4"),
        Slide(title: "Flush and almost full",
              words: "Flush joins the windows into one glass, with no gaps between them. Almost Full lets them take the whole screen, just under the menu bar.",
              keys: { "\(key(.flush))  flush   \(key(.almostFull))  almost full" }, media: "flush.mp4"),
        Slide(title: "Wallpapers and desktops",
              words: "Step through your wallpapers, pictures and videos, or add one from YouTube in Settings. Each desktop keeps its own windows: move between them, or take the window in front with you.",
              keys: { "\(key(.wallpaperBack)) \(key(.wallpaperNext))  wallpaper\n\(key(.desktopUp)) \(key(.desktopDown))  desktop\n\(key(.carryUp)) \(key(.carryDown))  take the window there" },
              media: "wallpaper.mp4"),
        Slide(title: "Your spacing",
              words: "Move the edges nearer or further: the desk's when the desk is in front, the app's when an app is. Hold A with fn to set every app at once.",
              keys: { "\(key(.sidesIn)) \(key(.sidesOut))  across   \(key(.wordsIn)) \(key(.wordsOut))  down   fn A  every app" }, media: "spacing.mp4"),
        Slide(title: "The dashboard",
              words: "Your Mac, now: processors, memory, disk, battery and Wi-Fi at a glance. Click a network to join it.",
              keys: { key(.dashboard) }, media: "dashboard.mp4"),
        Slide(title: "Settings",
              words: "Everything here can be switched in Settings: tiling and its arrangement, Flush, the language, the wallpapers, the lock screen, opening at login. A right click anywhere on the desk opens them too.",
              keys: { "\(key(.settings))  or a right click" }, media: "settings.jpg"),
        Slide(title: "Every key, your own",
              words: "All the keys of ReDesk and of every Re app, on one sheet. Click a key and press new ones to make it yours; ⌫ gives it back as it came.",
              keys: { key(.keys) }, media: "keys.jpg"),
        Slide(title: "The lock screen",
              words: "Lock the Mac behind your wallpaper. UNLOCK, then your Mac's own password, brings you back.",
              keys: { key(.lock) }, media: "lock.mp4"),
        Slide(title: "Come back any time",
              words: "Forgot a key, or something isn't clear? This guide opens again whenever you like, from the desk or any Re app.",
              keys: { "\(key(.guide))  this guide" }, media: nil),
    ]

    private var index = 0
    private weak var page: GuidePage?

    override var closesWhenLeft: Bool { false }

    override func width(on screen: NSRect) -> CGFloat { screen.width - 120 }

    override func build() -> NSView {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let page = GuidePage(popup: self, index: index, height: screen.height - 160)
        self.page = page
        return page
    }

    /// from the first slide each time
    override func show() {
        index = 0
        super.show()
    }

    override func close() {
        page?.stop()
        super.close()
    }

    func step(_ by: Int) {
        let next = index + by
        if next >= Self.slides.count { return close() }
        guard next >= 0, next != index else { return }
        index = next
        page?.stop()
        refresh()
        // the new slide fades in
        page?.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            page?.animator().alphaValue = 1
        }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 123: step(-1)  // ←
        case 124, 49: step(1)  // → and Space
        case 36: step(1)  // ↩
        default: super.keyDown(with: event)
        }
    }

    /// the first time ReDesk starts: the guide, once the desk has come up
    static func firstTime() {
        guard !UserDefaults.standard.bool(forKey: "guideSeen") else { return }
        UserDefaults.standard.set(true, forKey: "guideSeen")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { shared.show() }
    }

    /// --render-popups: each slide as a picture
    func render(_ each: (Int) -> Void) {
        for i in Self.slides.indices {
            index = i
            each(i)
        }
        index = 0
    }
}

/// One slide, the whole of the popup: GUIDE and where one is at the top; the words left, the film right; at the
/// foot the keys to go on, a diamond for each slide, BACK and NEXT.
final class GuidePage: NSView {
    private weak var popup: GuidePopup?
    private let media: GuideMedia

    init(popup: GuidePopup, index: Int, height: CGFloat) {
        self.popup = popup
        let slide = GuidePopup.slides[index]
        media = GuideMedia(name: slide.media, keys: slide.keys())
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true

        let count = GuidePopup.slides.count
        // the top: GUIDE, and the slide's number
        let where_ = popup.caption(String(format: "%02d / %02d", index + 1, count))
        let top = NSStackView(views: [popup.heading("Re:Desk  ·  Guide"), NSView(), where_])
        top.orientation = .horizontal
        top.alignment = .firstBaseline

        // the words
        let number = popup.caption(String(format: "%02d", index + 1))
        let title = NSTextField(wrappingLabelWithString: tr(slide.title))
        title.font = Popup.kurale(38)
        title.textColor = Popup.text
        title.isSelectable = false
        let words = popup.words(slide.words, size: 18, alpha: 0.85)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        words.attributedStringValue = NSAttributedString(string: tr(slide.words), attributes: [
            .font: Popup.kurale(20), .foregroundColor: Popup.text.withAlphaComponent(0.85), .paragraphStyle: paragraph,
        ])
        let keys = NSTextField(wrappingLabelWithString: slide.keys())
        keys.attributedStringValue = NSAttributedString(string: tr(slide.keys()), attributes: [
            .font: Popup.noto(14), .foregroundColor: Popup.text.withAlphaComponent(0.7), .kern: 1.4, .paragraphStyle: paragraph,
        ])
        keys.isSelectable = false
        let text = NSStackView(views: [number, title, words, keys])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 22
        text.setCustomSpacing(12, after: number)
        text.setCustomSpacing(34, after: words)
        for view in [title, words, keys] { view.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }

        let middle = NSView()
        middle.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        media.translatesAutoresizingMaskIntoConstraints = false
        middle.addSubview(text)
        middle.addSubview(media)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
            text.widthAnchor.constraint(equalTo: middle.widthAnchor, multiplier: 0.3),
            text.centerYAnchor.constraint(equalTo: middle.centerYAnchor),
            media.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 64),
            media.trailingAnchor.constraint(lessThanOrEqualTo: middle.trailingAnchor),
            media.topAnchor.constraint(greaterThanOrEqualTo: middle.topAnchor),
            media.bottomAnchor.constraint(lessThanOrEqualTo: middle.bottomAnchor),
            media.centerYAnchor.constraint(equalTo: middle.centerYAnchor),
            media.widthAnchor.constraint(equalTo: media.heightAnchor, multiplier: 16.0 / 9.0),
        ])
        // as big as it goes
        let wide = media.trailingAnchor.constraint(equalTo: middle.trailingAnchor)
        wide.priority = .defaultHigh
        wide.isActive = true

        // the foot: the keys to go on; a diamond for each slide; BACK and NEXT
        let hint = popup.keys("←  →  the slides   ·   Esc  closes   ·   \(DeskKey.guide.shortcut.text)  this guide, any time")
        let dots = GuideDots(count: count, at: index)
        let back = button(popup, "Back", alpha: index == 0 ? 0.25 : 0.9) { [weak popup] in popup?.step(-1) }
        let next = button(popup, index == count - 1 ? "Begin" : "Next", alpha: 1) { [weak popup] in popup?.step(1) }
        let buttons = NSStackView(views: [back, next])
        buttons.spacing = 36
        let foot = NSView()
        for view in [hint, dots, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            foot.addSubview(view)
        }
        NSLayoutConstraint.activate([
            foot.heightAnchor.constraint(equalToConstant: 30),
            hint.leadingAnchor.constraint(equalTo: foot.leadingAnchor), hint.centerYAnchor.constraint(equalTo: foot.centerYAnchor),
            dots.centerXAnchor.constraint(equalTo: foot.centerXAnchor), dots.centerYAnchor.constraint(equalTo: foot.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: foot.trailingAnchor), buttons.centerYAnchor.constraint(equalTo: foot.centerYAnchor),
        ])

        let lineTop = popup.divider(), lineFoot = popup.divider()
        let all = NSStackView(views: [top, lineTop, middle, lineFoot, foot])
        all.orientation = .vertical
        all.alignment = .leading
        all.spacing = 24
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: leadingAnchor), all.trailingAnchor.constraint(equalTo: trailingAnchor),
            all.topAnchor.constraint(equalTo: topAnchor), all.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in [top, lineTop, middle, lineFoot, foot] { view.widthAnchor.constraint(equalTo: all.widthAnchor).isActive = true }
        middle.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    func stop() { media.stop() }

    /// a control as the apps write theirs: spaced capitals
    private func button(_ popup: Popup, _ title: String, alpha: CGFloat, _ run: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: tr(title).uppercased(), attributes: [
            .font: Popup.noto(13), .kern: 3.2, .foregroundColor: Popup.text.withAlphaComponent(alpha),
        ])
        let action = popup.act { _ in run() }
        button.target = action
        button.action = #selector(Do.fire(_:))
        return button
    }
}

/// What a slide shows: a few seconds of the film, looped and silent (its first frame under it, so nothing
/// flashes black), or a picture; a + at each corner round it. No film or picture: the slide's keys, large.
final class GuideMedia: NSView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let inset: CGFloat = 16

    init(name: String?, keys: String) {
        super.init(frame: .zero)
        let inner = NSView()
        inner.wantsLayer = true
        inner.layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset), inner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            inner.topAnchor.constraint(equalTo: topAnchor, constant: inset), inner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        let found = name.flatMap { Bundle.main.resourceURL?.appendingPathComponent("guide/" + $0) }
        guard let url = found, FileManager.default.fileExists(atPath: url.path) else {
            // the last slide: its keys, large, in the middle
            let big = NSTextField(labelWithAttributedString: NSAttributedString(string: keys.components(separatedBy: "  ").first ?? keys, attributes: [
                .font: Popup.noto(96), .foregroundColor: Popup.text, .kern: 8,
            ]))
            big.translatesAutoresizingMaskIntoConstraints = false
            inner.addSubview(big)
            NSLayoutConstraint.activate([big.centerXAnchor.constraint(equalTo: inner.centerXAnchor), big.centerYAnchor.constraint(equalTo: inner.centerYAnchor)])
            return
        }
        let still = NSImageView()
        still.imageScaling = .scaleProportionallyUpOrDown
        still.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(still)
        NSLayoutConstraint.activate([
            still.leadingAnchor.constraint(equalTo: inner.leadingAnchor), still.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            still.topAnchor.constraint(equalTo: inner.topAnchor), still.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
        ])
        if url.pathExtension == "mp4" {
            let asset = AVURLAsset(url: url)
            let frames = AVAssetImageGenerator(asset: asset)
            frames.appliesPreferredTrackTransform = true
            if let first = try? frames.copyCGImage(at: .zero, actualTime: nil) {
                still.image = NSImage(cgImage: first, size: NSSize(width: first.width, height: first.height))
            }
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
            let film = NSView()
            film.wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            film.layer = layer
            film.translatesAutoresizingMaskIntoConstraints = false
            inner.addSubview(film)
            NSLayoutConstraint.activate([
                film.leadingAnchor.constraint(equalTo: inner.leadingAnchor), film.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
                film.topAnchor.constraint(equalTo: inner.topAnchor), film.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
            ])
            player.play()
            self.player = player
        } else {
            still.image = NSImage(contentsOf: url)
        }
    }

    required init?(coder: NSCoder) { nil }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        player = nil
        looper = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: inset - 6, dy: inset - 6)
        let path = NSBezierPath()
        let arm = PlusMarks.arm
        for corner in [NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY),
                       NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.maxX, y: box.maxY)] {
            path.move(to: NSPoint(x: corner.x - arm, y: corner.y)); path.line(to: NSPoint(x: corner.x + arm, y: corner.y))
            path.move(to: NSPoint(x: corner.x, y: corner.y - arm)); path.line(to: NSPoint(x: corner.x, y: corner.y + arm))
        }
        path.lineWidth = PlusMarks.line
        ink(0.55).setStroke()
        path.stroke()
    }
}

/// A diamond for each slide: the one shown filled, the others drawn.
final class GuideDots: NSView {
    private let count: Int
    private let at: Int
    private let step: CGFloat = 22, size: CGFloat = 8

    init(count: Int, at: Int) {
        self.count = count
        self.at = at
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: CGFloat(count - 1) * step + size + 4).isActive = true
        heightAnchor.constraint(equalToConstant: size + 4).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<count {
            let c = NSPoint(x: 2 + size / 2 + CGFloat(i) * step, y: bounds.midY)
            let d = NSBezierPath()
            d.move(to: NSPoint(x: c.x, y: c.y + size / 2)); d.line(to: NSPoint(x: c.x + size / 2, y: c.y))
            d.line(to: NSPoint(x: c.x, y: c.y - size / 2)); d.line(to: NSPoint(x: c.x - size / 2, y: c.y)); d.close()
            if i == at {
                ink(0.95).setFill(); d.fill()
            } else {
                d.lineWidth = 1
                ink(0.45).setStroke(); d.stroke()
            }
        }
    }
}
