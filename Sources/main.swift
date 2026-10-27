// ReDesk: the Re apps as words in the corners of the desktop.
// Each word is a small borderless window just above the desktop icons;
// a click opens its app; a right click can open it at login or quit.
import AppKit
import ServiceManagement

struct Corner {
    let word: String
    let app: String
    let bundle: String
    let left: Bool
    let top: Bool
}

let corners = [
    Corner(word: "FILE", app: "ReFile", bundle: "com.artursavytskyi.refile", left: true, top: true),
    Corner(word: "SURF", app: "ReSurf", bundle: "com.artursavytskyi.resurf", left: false, top: true),
    Corner(word: "HEAR", app: "ReSound", bundle: "com.artursavytskyi.resound", left: true, top: false),
    Corner(word: "NOTE", app: "ReNote", bundle: "com.artursavytskyi.renote", left: false, top: false),
]

/// Same rhythm as the apps' side buttons: 20pt letters, one every 32pt, upright.
let letterSize: CGFloat = 20
let letterStep: CGFloat = 32
let columnWidth: CGFloat = 42

/// The apps' side-button font, shipped inside ReDesk; the system font if it can't be loaded.
let letterFont: NSFont = {
    if let url = Bundle.main.url(forResource: "NotoSansJP", withExtension: "woff") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
    return NSFont(name: "NotoSansJP-Regular", size: letterSize) ?? .systemFont(ofSize: letterSize, weight: .light)
}()

func open(_ corner: Corner) {
    let places = ["/Applications/ReSpace/\(corner.app).app", "/Applications/\(corner.app).app"]
    let url = places.map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: corner.bundle)
    guard let url else { return NSSound.beep() }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

final class WordView: NSView {
    let corner: Corner
    private var hovered = false { didSet { needsDisplay = true } }

    init(corner: Corner) {
        self.corner = corner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { open(corner) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open \(corner.app)", action: #selector(openApp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit ReDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openApp() { open(corner) }

    /// Starting with the Mac is up to the user; macOS may ask to approve it in Login Items.
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: letterFont,
            .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 0.95 : 0.6),
        ]
        for (i, letter) in corner.word.enumerated() {
            let text = NSAttributedString(string: String(letter), attributes: attributes)
            let size = text.size()
            let y = bounds.maxY - CGFloat(i + 1) * letterStep + (letterStep - size.height) / 2
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y))
        }
    }
}

final class WordWindow: NSWindow {
    let corner: Corner

    init(corner: Corner) {
        self.corner = corner
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // a clear window lets clicks fall through wherever nothing is drawn, i.e. between
        // the thin strokes of the letters; saying so explicitly makes the whole word clickable
        ignoresMouseEvents = false
        // just above the desktop icons, below every other window
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        contentView = WordView(corner: corner)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Insets as in the apps: 5% of the width from the side, 6.25% of the height from the top or bottom.
    func place(on screen: NSScreen) {
        let area = screen.visibleFrame
        let height = CGFloat(corner.word.count) * letterStep
        let centre = corner.left ? area.minX + area.width * 0.05 : area.maxX - area.width * 0.05
        let y = corner.top ? area.maxY - area.height * 0.0625 - height : area.minY + area.height * 0.0625
        setFrame(NSRect(x: (centre - columnWidth / 2).rounded(), y: y.rounded(), width: columnWidth, height: height), display: true)
        orderFront(nil)
    }
}

final class Desk: NSObject, NSApplicationDelegate {
    private let windows = corners.map(WordWindow.init)

    func applicationDidFinishLaunching(_ notification: Notification) {
        layout()
        NotificationCenter.default.addObserver(
            self, selector: #selector(layout), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func layout() {
        guard let screen = NSScreen.screens.first else { return }
        windows.forEach { $0.place(on: screen) }
    }
}

let app = NSApplication.shared
let desk = Desk()
app.delegate = desk
app.setActivationPolicy(.accessory)
app.run()
