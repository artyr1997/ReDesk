// ReDesk: the Re apps and a few quiet gauges on the desktop.
// Corners: the apps as words (a click opens one). Top: the wallpapers, pictures and videos, as dots in a row
// (wallpapers/Light or wallpapers/Dark, as the Mac's appearance is). Left edge: ReDesk's own desktops.
// Bottom: a wave while sound plays. (The day's line is out for now.)
// Tiling (optional): the Re apps' windows share the middle of the desk, between the gauges.
// Keys: on the desk and in the Re apps ⌘ arrows move the focus between windows, ⌥← / ⌥→ step the
// wallpapers, ⌥↑ / ⌥↓ the desktops, ⌘1…⌘6 pick an arrangement (CommandKeys); ⌘⇧T switches the Mac
// between light and dark (anywhere: HotKeys).
// Each piece is a small borderless window just above the desktop icons;
// a right click on any of them can open ReDesk at login or quit it.
import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import ImageIO
import IOKit.hid
import IOKit.ps
import IOKit.pwr_mgt
import OpenDirectory
import ServiceManagement

struct Corner {
    /// its word in English: FILE, SURF…
    let name: String
    /// its word on the desk, in the desk's language
    var word: String { Flap.text(tr(name), seed: name) }
    let app: String
    let bundle: String
    let left: Bool
    let top: Bool
}

let corners = [
    Corner(name: "FILE", app: "ReFile", bundle: "com.artursavytskyi.refile", left: true, top: true),
    Corner(name: "SURF", app: "ReSurf", bundle: "com.artursavytskyi.resurf", left: false, top: true),
    Corner(name: "TERM", app: "ReTerm", bundle: "com.artursavytskyi.reterm", left: true, top: false),
    Corner(name: "NOTE", app: "ReNote", bundle: "com.artursavytskyi.renote", left: false, top: false),
]


/// Same rhythm as the apps' side buttons: 20pt letters, one every 32pt, upright.
let letterSize: CGFloat = 20
let letterStep: CGFloat = 32
let columnWidth: CGFloat = 42

/// The desk's ink: always white, as in the dark, see-through by `alpha`, whatever the Mac or the wallpaper.
func ink(_ alpha: CGFloat) -> NSColor { NSColor.white.withAlphaComponent(alpha) }

/// Gauges: the empty part at 25%, the filled part (and the chosen wallpaper) at 50%.
let faint = ink(0.25)
let strong = ink(0.5)
let barWidth: CGFloat = 4

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

// ── the desk's layout: the apps' insets, 5% of the width from the sides, 6.25% of the height ──

/// How far the desk's words stand from a screen's edges, as a share of it: across (the side columns, the
/// corner words and the dashes, from the left and right edges: ⌃⌥- nearer, ⌃⌥= further) and down (the corner
/// words from the top and bottom edges: ⌃⌥[ nearer, ⌃⌥] further). Each screen its own, kept by the display (a
/// monitor plugged in again finds its own), set on the screen the mouse is on. The tiled windows keep as far
/// again from the side columns, and reach from the top words to the bottom ones.
struct SideMargin {
    static let changed = Notification.Name("ReDeskSideMarginChanged")
    static let least: CGFloat = 0.02, most: CGFloat = 0.15, step: CGFloat = 0.005

    /// across, from the left and right edges; down, from the top and bottom
    static let across = SideMargin(name: "sideMargin", start: 0.05)
    static let down = SideMargin(name: "topMargin", start: 0.0625)

    let name: String
    let start: CGFloat

    /// a screen not set yet: as all were set before each had its own, else as it began
    private var usual: CGFloat { (UserDefaults.standard.object(forKey: name) as? Double).map { CGFloat($0) } ?? start }

    /// a screen's own key: its display's UUID (the same each time it is plugged in)
    private func key(_ screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let uuid = CGDisplayCreateUUIDFromDisplayID(number).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(number)"
        return name + "." + uuid
    }

    func share(of screen: NSScreen) -> CGFloat {
        (UserDefaults.standard.object(forKey: key(screen)) as? Double).map { CGFloat($0) } ?? usual
    }

    /// the share for a place laid out on a screen (the screen holding its middle)
    func share(for area: NSRect) -> CGFloat {
        let middle = NSPoint(x: area.midX, y: area.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(middle) }) ?? NSScreen.screens.first else { return usual }
        return share(of: screen)
    }

    /// a step nearer the edges (-1) or further from them (1), on the screen the mouse is on
    func move(_ way: CGFloat) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first else { return }
        let now = share(of: screen)
        let next = min(Self.most, max(Self.least, now + way * Self.step))
        guard next != now else { return NSSound.beep() }
        UserDefaults.standard.set(Double(next), forKey: key(screen))
        NotificationCenter.default.post(name: Self.changed, object: nil)
        // the lines it sets, across the whole screen for a moment
        Guides.shared.show(on: screen)
    }
}

/// While the distances are set by keys: thin lines across the whole screen, down through the side columns
/// and the windows' sides, across at the windows' top and foot (where the corner words begin); they fade a
/// moment after the last key.
final class Guides {
    static let shared = Guides()

    private final class Lines: NSView {
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath()
            for x in xs { path.move(to: NSPoint(x: x.rounded() + 0.5, y: bounds.minY)); path.line(to: NSPoint(x: x.rounded() + 0.5, y: bounds.maxY)) }
            for y in ys { path.move(to: NSPoint(x: bounds.minX, y: y.rounded() + 0.5)); path.line(to: NSPoint(x: bounds.maxX, y: y.rounded() + 0.5)) }
            path.lineWidth = 1
            ink(0.35).setStroke()
            path.stroke()
        }
    }

    private let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private let lines = Lines()
    private var hiding: DispatchWorkItem?

    init() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = lines
        window.alphaValue = 0
    }

    func show(on screen: NSScreen) {
        let f = screen.frame
        let l = Layout(area: f)
        let tiles = l.tiles
        // in the window's own points (from the screen's bottom left)
        lines.xs = [l.leftX, l.rightX, tiles.minX, tiles.maxX].map { $0 - f.minX }
        lines.ys = [l.topWord, l.bottomWord].map { $0 - f.minY }
        window.setFrame(f, display: true)
        lines.needsDisplay = true
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; window.animator().alphaValue = 1 }
        hiding?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; self.window.animator().alphaValue = 0 },
                                                 completionHandler: { if self.window.alphaValue == 0 { self.window.orderOut(nil) } })
        }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

struct Layout {
    let area: NSRect

    var leftX: CGFloat { area.minX + area.width * SideMargin.across.share(for: area) }
    var rightX: CGFloat { area.maxX - area.width * SideMargin.across.share(for: area) }
    var topWord: CGFloat { area.maxY - area.height * SideMargin.down.share(for: area) }
    var bottomWord: CGFloat { area.minY + area.height * SideMargin.down.share(for: area) }
    /// the dots on the left and the battery on the right share this length, around the middle
    var sideLength: CGFloat { area.height * 0.22 }
    /// the day line: halfway between the top of the screen and the tops of FILE and SURF (the windows' top)
    var dayLine: CGFloat { (topWord + area.maxY) / 2 }
    /// the wave: halfway between the bottom of the screen and the feet of TERM and NOTE (the windows' foot)
    var waveLine: CGFloat { (bottomWord + area.minY) / 2 }
    /// where tiled windows go: from the tops of FILE and SURF down to the feet of TERM and NOTE, and across
    /// as far from the side columns as those are from the screen's edges (the columns stand at 5%, the
    /// windows begin at 10%) (a Layout of the whole screen, as the words are placed by it)
    var tiles: NSRect {
        let side = (leftX - area.minX) * 2
        return NSRect(x: area.minX + side, y: bottomWord, width: area.width - side * 2, height: topWord - bottomWord)
    }
}

// ── wallpapers ──

enum Wallpapers {
    static let pictures = ["jpg", "jpeg", "png", "heic"]
    static let videos = ["mp4", "mov", "m4v"]

    /// wallpapers/Light and wallpapers/Dark: for the Mac's light and dark appearance
    private static func folder(_ name: String) -> [URL] {
        guard let root = Bundle.main.url(forResource: "wallpapers", withExtension: nil) else { return [] }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { (pictures + videos).contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static let light = folder("Light")
    private static let dark = folder("Dark")

    /// Pictures and videos added from ReFile (Edit › Add to wallpapers), copied into Application
    /// Support/ReDesk/Added: in both appearances, after the folder's own, oldest first.
    static let addedFolder: URL = {
        let folder = stills.appendingPathComponent("Added", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    private(set) static var added = addedFiles()
    private static func addedFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: addedFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func made(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return files.filter { (pictures + videos).contains($0.pathExtension.lowercased()) }.sorted { made($0) < made($1) }
    }

    /// one of these can go again (Settings › This wallpaper › Remove); the folder's own can't
    static func removable(_ url: URL) -> Bool { added.contains(url) }
    /// This wallpaper gone (Settings › This wallpaper › Remove): one added from ReFile; the one before shows instead.
    static func removeCurrent() {
        guard let index = current else { return }
        let url = all[index]
        guard removable(url) else { return }
        if all.count > 1 { show(index > 0 ? index - 1 : 1) }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: still(of: url))
        reload()
    }

    /// Looks at the Added folder again (a picture or video came or went), and lays the dots out again.
    static func reload() {
        added = addedFiles()
        NotificationCenter.default.post(name: .wallpapersListed, object: nil)
    }

    /// The wallpapers of the appearance the Mac is in (the other folder's while this one is empty),
    /// then those added.
    static var all: [URL] {
        let (mine, other) = Appearance.dark ? (dark, light) : (light, dark)
        return (mine.isEmpty ? other : mine) + added
    }

    /// the wallpaper last chosen in each appearance
    private static var chosenKey: String { Appearance.dark ? "wallpaper.dark" : "wallpaper.light" }

    static func isVideo(_ url: URL) -> Bool { videos.contains(url.pathExtension.lowercased()) }

    /// A still of each video becomes the macOS wallpaper underneath it, so the desktop looks
    /// right in Mission Control and after ReDesk quits, and so the choice survives a restart.
    static let stills: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static func still(of video: URL) -> URL {
        stills.appendingPathComponent(video.lastPathComponent + ".jpg")
    }

    static var current: Int? {
        guard let screen = NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        // by name: the same picture may have been set from the repo's folder rather than the app's
        let name = url.lastPathComponent
        return all.firstIndex { $0.lastPathComponent == name || still(of: $0).lastPathComponent == name }
    }

    static func show(_ index: Int, fading duration: Double = Crossfade.duration) {
        guard all.indices.contains(index) else { return }
        let url = all[index]
        UserDefaults.standard.set(url.lastPathComponent, forKey: chosenKey)
        // what is on the desktop now stays over the new wallpaper a moment, then fades away
        let old = LiveWallpaper.shared.url != nil ? LiveWallpaper.shared.handOver() : (windows: Crossfade.cover(), video: [])
        defer { Crossfade.lift(old.windows, keeping: old.video, over: duration) }
        if isVideo(url) {
            LiveWallpaper.shared.play(url)
            let still = still(of: url)
            if FileManager.default.fileExists(atPath: still.path) {
                setDesktop(still)
            } else {
                makeStill(of: url, at: still) { setDesktop(still) }
            }
        } else {
            LiveWallpaper.shared.stop()
            setDesktop(url)
        }
        NotificationCenter.default.post(name: .wallpaperChanged, object: nil)
    }

    private static func setDesktop(_ url: URL) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
        NotificationCenter.default.post(name: .wallpaperChanged, object: nil)
    }

    private static func makeStill(of video: URL, at still: URL, then done: @escaping () -> Void) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            guard let image,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
                  (try? data.write(to: still)) != nil else { return }
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Plays the video if the desktop shows one of ours, stops it if the wallpaper was changed elsewhere.
    static func sync() {
        if let index = current, isVideo(all[index]) {
            LiveWallpaper.shared.play(all[index])
        } else {
            LiveWallpaper.shared.stop()
        }
    }

    /// The Mac went light or dark (or ReDesk just started): this appearance's wallpaper, the one
    /// last chosen in it, or its first. One of its own already on the desktop stays.
    static func appearanceChanged() {
        if current != nil { return sync() }
        let remembered = UserDefaults.standard.string(forKey: chosenKey)
        // as fast as the apps' own change of look (their app.css), so the desk turns with them
        show(all.firstIndex { $0.lastPathComponent == remembered } ?? 0, fading: Crossfade.themeDuration)
    }

    /// One step up or down the list, round and round.
    static func step(_ delta: Int) {
        guard !all.isEmpty else { return }
        let from = current ?? (delta > 0 ? -1 : 0)
        show((from + delta + all.count) % all.count)
    }
}

/// A video wallpaper: a muted, looping video in a window under the desktop icons, on every screen.
/// It pauses while the displays sleep, and stands still while frozen (⌘⇧M), kept between launches.
final class LiveWallpaper {
    static let shared = LiveWallpaper()

    /// ⌘⇧M: the video stands still (no decoding, so no work for the Mac) or moves again.
    var frozen = UserDefaults.standard.bool(forKey: "wallpaperFrozen") {
        didSet {
            UserDefaults.standard.set(frozen, forKey: "wallpaperFrozen")
            if frozen { player?.pause() } else { player?.play() }
        }
    }

    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var windows: [NSWindow] = []
    private(set) var url: URL?

    func play(_ url: URL) {
        guard url != self.url else { return }
        stop()
        self.url = url
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        layout()
        if !frozen { player.play() }
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
        url = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    /// The video's windows, taken out of its hands and raised for a crossfade. Its player and looper
    /// come along and are kept until the windows are gone: let go, the video would stop and leave
    /// them black halfway through the fade.
    func handOver() -> (windows: [NSWindow], video: [AnyObject]) {
        let old = (windows, [player, looper].compactMap { $0 as AnyObject? })
        windows = []
        looper = nil
        player = nil
        url = nil
        old.0.forEach { $0.level = Crossfade.level }
        return old
    }

    private func videoLayer(of window: NSWindow) -> AVPlayerLayer? {
        window.contentView?.layer?.sublayers?.first?.sublayers?.lazy.compactMap { $0 as? AVPlayerLayer }.first
    }

    /// the new video has its first frame on every screen
    var ready: Bool {
        windows.allSatisfy { videoLayer(of: $0)?.isReadyForDisplay ?? true }
    }

    /// the video's still lies under it on every screen: the new wallpaper shows before the video plays
    var stillShown: Bool {
        !windows.isEmpty && windows.allSatisfy { $0.contentView?.layer?.sublayers?.first?.contents != nil }
    }

    /// the displays asleep
    private var resting = false
    func pause() { resting = true; player?.pause() }
    func resume() { resting = false; if !frozen { player?.play() } }

    func layout() {
        // the windows before fade away over the new (another screen, the blur turned on or off)
        let before = windows
        windows = []
        defer { WallpaperBlur.fadeOut(before) }
        guard let player else { return }
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            // clear where nothing is drawn yet: never black
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            // over the macOS wallpaper, under the desktop icons
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            // the video over its still (its first frame), which shows at once, while the video loads.
            // The view has the screen's size from the start: the video layer grows with it
            // (autoresizing), and a view growing from nothing would make it twice the screen.
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            let base = CALayer()
            base.frame = view.bounds
            base.masksToBounds = true
            // the still and the video; blurred, a little over the screen on each side, so the blur's
            // soft edges are off it
            let art = CALayer()
            let over = WallpaperBlur.on ? WallpaperBlur.radius * 2 : 0
            art.frame = base.bounds.insetBy(dx: -over, dy: -over)
            art.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            if let url, let still = Crossfade.picture(Wallpapers.still(of: url), for: screen) {
                art.contents = still
                art.contentsGravity = .resizeAspectFill
                art.masksToBounds = true
            }
            let video = AVPlayerLayer(player: player)
            video.videoGravity = .resizeAspectFill
            video.frame = art.bounds
            video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            art.addSublayer(video)
            if WallpaperBlur.on { art.filters = WallpaperBlur.filters() }
            base.addSublayer(art)
            view.layer = base
            view.wantsLayer = true
            view.layerUsesCoreImageFilters = true
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            return window
        }
    }
}

/// Blur wallpaper (Settings › Wallpaper): the wallpaper soft under the windows, kept between launches. A video
/// is blurred in its own windows (LiveWallpaper); a picture, set as the macOS wallpaper, is shown blurred in a
/// window over it, one per screen, where the video would be. Turned on or off, it fades.
enum WallpaperBlur {
    static let radius: CGFloat = 30

    static var on = UserDefaults.standard.bool(forKey: "wallpaperBlur") {
        didSet {
            UserDefaults.standard.set(on, forKey: "wallpaperBlur")
            LiveWallpaper.shared.layout()
            refresh(fadingIn: true)
        }
    }

    static func filters() -> [CIFilter] {
        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]) else { return [] }
        return [blur]
    }

    private static let context = CIContext()

    /// the picture blurred, its edges as solid as its middle
    static func blurred(_ image: CGImage, for screen: NSScreen) -> CGImage? {
        let picture = CIImage(cgImage: image)
        let soft = picture.clampedToExtent().applyingGaussianBlur(sigma: Double(radius * screen.backingScaleFactor) / 2)
            .cropped(to: picture.extent)
        return context.createCGImage(soft, from: picture.extent)
    }

    private static var windows: [NSWindow] = []
    private static var shown: [URL?] = []
    private static var watching = false

    /// The picture's blurred windows as things are now: none for a video, or with the blur off. Just turned
    /// on, they fade in; else they come at once (a new wallpaper's are under the old one's crossfade).
    static func refresh(fadingIn: Bool = false) {
        if !watching {
            watching = true
            NotificationCenter.default.addObserver(forName: .wallpaperChanged, object: nil, queue: .main) { _ in refresh() }
        }
        let screens = NSScreen.screens
        let urls: [URL?] = screens.map { NSWorkspace.shared.desktopImageURL(for: $0) }
        let wanted = on && LiveWallpaper.shared.url == nil
        // the same picture on the same screens: as it is
        if wanted && urls == shown && windows.count == screens.count
            && zip(windows, screens).allSatisfy({ $0.frame == $1.frame }) { return }
        let before = windows
        windows = []
        shown = []
        defer { fadeOut(before) }
        guard wanted else { return }
        shown = urls
        windows = zip(screens, urls).compactMap { screen, url in
            guard let url, let sharp = Crossfade.picture(url, for: screen), let image = blurred(sharp, for: screen) else { return nil }
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            // where a video wallpaper is: over the macOS one, under the old one's crossfade and the icons
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            let view = NSView()
            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resizeAspectFill
            layer.masksToBounds = true
            view.layer = layer
            view.wantsLayer = true
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.alphaValue = fadingIn ? 0 : 1
            window.orderFront(nil)
            if fadingIn {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.6
                    window.animator().alphaValue = 1
                }
            }
            return window
        }
    }

    /// windows going: they fade away, then are gone
    static func fadeOut(_ windows: [NSWindow]) {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.orderFront(nil) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            windows.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            windows.forEach { $0.orderOut(nil) }
        })
    }
}

/// A change of wallpaper is a crossfade: the old one, in windows over the new one, fades away
/// once the new one is on the screen.
enum Crossfade {
    /// over the video wallpaper (the desktop's level + 1), under the desktop icons
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 2)
    static let duration = 1.2
    static let themeDuration = 0.7

    /// windows showing the macOS wallpaper as it is now, one per screen
    static func cover() -> [NSWindow] {
        NSScreen.screens.compactMap { screen in
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  let sharp = picture(url, for: screen) else { return nil }
            // as it is on the screen: blurred, when the wallpaper is
            let image = LiveWallpaper.shared.url == nil && WallpaperBlur.on ? WallpaperBlur.blurred(sharp, for: screen) ?? sharp : sharp
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = level
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            let view = NSView()
            let layer = CALayer()
            layer.contents = image
            // as the wallpaper is set: filling the screen, the overflow cut off
            layer.contentsGravity = .resizeAspectFill
            layer.masksToBounds = true
            view.layer = layer
            view.wantsLayer = true
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            return window
        }
    }

    /// the picture at the screen's size (a wallpaper can be far bigger, and this is on the way to a click)
    static func picture(_ url: URL, for screen: NSScreen) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// While the new wallpaper loads, the old one blurs, draws a little nearer and darkens, then breathes
    /// (the shade slowly deeper and lighter) until the new one is there; it then fades away over it,
    /// so the new one comes into focus.
    static func soften(_ windows: [NSWindow]) {
        for window in windows {
            guard let view = window.contentView, let layer = view.layer else { continue }
            view.layerUsesCoreImageFilters = true
            let size = view.bounds.size
            let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 0])
            blur?.name = "blur"
            layer.filters = blur.map { [$0] }
            let soft = CABasicAnimation(keyPath: "filters.blur.inputRadius")
            soft.fromValue = 0
            soft.toValue = 28
            // nearer about the middle (the layer turns about its corner): the blur's soft edges off the screen
            let near: CGFloat = 1.06
            var closer = CATransform3DMakeScale(near, near, 1)
            closer = CATransform3DConcat(closer, CATransform3DMakeTranslation(-(near - 1) * size.width / 2, -(near - 1) * size.height / 2, 0))
            let zoom = CABasicAnimation(keyPath: "transform")
            zoom.fromValue = CATransform3DIdentity
            zoom.toValue = closer
            for animation in [soft, zoom] {
                animation.duration = 1.4
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animation.fillMode = .forwards
                animation.isRemovedOnCompletion = false
                layer.add(animation, forKey: animation.keyPath)
            }

            let shade = CALayer()
            shade.frame = CGRect(origin: CGPoint(x: -size.width, y: -size.height), size: CGSize(width: size.width * 3, height: size.height * 3))
            shade.backgroundColor = NSColor.black.cgColor
            shade.opacity = 0
            layer.addSublayer(shade)
            let dark = CABasicAnimation(keyPath: "opacity")
            dark.fromValue = 0
            dark.toValue = 0.22
            dark.duration = 1.4
            dark.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.22
            breathe.toValue = 0.08
            breathe.beginTime = 1.4
            breathe.duration = 1.6
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let group = CAAnimationGroup()
            group.animations = [dark, breathe]
            group.duration = .infinity
            shade.add(group, forKey: "breathe")
        }
    }

    /// Fades the old wallpaper away once the new one shows: at once over a video's still (its first
    /// frame, under the video until it plays), else once the video's first frame is there (or a second
    /// and a half has gone); a picture has a moment to be drawn by macOS.
    static func lift(_ windows: [NSWindow], keeping video: [AnyObject] = [], over duration: Double = duration, waited: Double = 0,
                     loading: Bool = false) {
        guard !windows.isEmpty else { return }
        let shown = LiveWallpaper.shared.url == nil ? waited >= 0.2 : (LiveWallpaper.shared.stillShown || LiveWallpaper.shared.ready)
        if waited < 1.5 && !shown {
            // still nothing after a moment: the old wallpaper goes soft while the new one comes
            let wait = waited >= 0.15
            if wait && !loading { soften(windows) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                lift(windows, keeping: video, over: duration, waited: waited + 0.05, loading: loading || wait)
            }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            windows.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            windows.forEach { $0.orderOut(nil) }
            withExtendedLifetime(video) {}
        })
    }
}

extension Notification.Name {
    static let wallpaperChanged = Notification.Name("ReDeskWallpaperChanged")
    /// one more wallpaper, or one fewer: the dots are laid out again
    static let wallpapersListed = Notification.Name("ReDeskWallpapersListed")
    /// tiling turned on or off, or another arrangement
    static let arrangementChanged = Notification.Name("ReDeskArrangementChanged")
    /// another desktop in sight, or one more or fewer
    static let desktopsChanged = Notification.Name("ReDeskDesktopsChanged")
}

/// From anywhere (Carbon hot keys need no permissions): ⌘⇧T the Mac between light and dark, ⌘⇧M the video
/// wallpaper still or moving, ⌘⇧B the wallpaper blurred or not; ⌃⌥Space the next arrangement, ⌃⌥↩ the
/// focused window the main one, ⌃⌥P it pinned to its place. The desk's other keys are ⌘ ones: CommandKeys.
/// The desk's keys that work whichever app is in front (the system's hot keys): those of DeskKey that are
/// `anywhere`, as they are kept; made again when one is changed, put away while one is being set.
enum HotKeys {
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    static func register() {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let all = DeskKey.allCases
                if id.id >= 100, Int(id.id) - 100 < all.count { all[Int(id.id) - 100].run() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        pause()
        for (i, key) in DeskKey.allCases.enumerated() where key.anywhere {
            let shortcut = key.shortcut
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(shortcut.key), shortcut.carbonModifiers,
                                EventHotKeyID(signature: OSType(0x5244_534B), id: UInt32(100 + i)),
                                GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
        }
    }

    /// none of them for now (a key being set: it must reach the popup)
    static func pause() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }
}

/// A key with its modifiers (⌘ ⇧ ⌃ ⌥), kept as "key:modifiers".
struct Shortcut: Equatable {
    var key: Int
    var flags: CGEventFlags

    static let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    init(key: Int, flags: CGEventFlags) {
        self.key = key
        self.flags = flags.intersection(Self.modifiers)
    }

    init?(kept: String) {
        let parts = kept.split(separator: ":").compactMap { UInt64($0) }
        guard parts.count == 2 else { return nil }
        self.init(key: Int(parts[0]), flags: CGEventFlags(rawValue: parts[1]))
    }

    var kept: String { "\(key):\(flags.rawValue)" }

    static func == (a: Shortcut, b: Shortcut) -> Bool { a.key == b.key && a.flags.rawValue == b.flags.rawValue }

    var carbonModifiers: UInt32 {
        var mods = 0
        if flags.contains(.maskCommand) { mods |= cmdKey }
        if flags.contains(.maskShift) { mods |= shiftKey }
        if flags.contains(.maskControl) { mods |= controlKey }
        if flags.contains(.maskAlternate) { mods |= optionKey }
        return UInt32(mods)
    }

    /// as the popup writes keys: ⌃⌥⌘⇧ and then the key
    var text: String {
        var out = ""
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskCommand) { out += "⌘" }
        if flags.contains(.maskShift) { out += "⇧" }
        return out + (Self.names[key] ?? "#\(key)")
    }

    /// the keys by where they are on the keyboard (as printed on a US one, whatever the layout)
    private static let names: [Int: String] = {
        var names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Minus: "-",
            kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
            kVK_Return: "↩", kVK_Space: "Space", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "Esc",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "fn←", kVK_End: "fn→", kVK_PageUp: "fn↑", kVK_PageDown: "fn↓",
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, key) in f.enumerated() { names[key] = "F\(i + 1)" }
        return names
    }()
}

/// One of a Re app's keys, set in the popup too: kept in Application Support/ReSpace/keys.json, which the app
/// reads (its OwnKeys) when told (com.artursavytskyi.re.keys).
struct AppKey: Equatable {
    let app: String
    let id: String
    let title: String
    let standard: Shortcut

    static func == (a: AppKey, b: AppKey) -> Bool { a.app == b.app && a.id == b.id }

    private static func key(_ app: String, _ id: String, _ title: String, _ key: Int, _ flags: CGEventFlags = .maskCommand) -> AppKey {
        AppKey(app: app, id: id, title: title, standard: Shortcut(key: key, flags: flags))
    }

    static let all: [AppKey] = [
        key("ReFile", "newWindow", "new window", 45, .maskCommand),
        key("ReFile", "allInside", "all inside", 36, .maskShift),
        key("ReFile", "up", "up", 126, []),
        key("ReFile", "down", "down", 125, []),
        key("ReFile", "left", "the folder above, the page before", 123, []),
        key("ReFile", "right", "open, the next page", 124, []),
        key("ReFile", "enter", "open, write in a cell", 36, []),
        key("ReFile", "search", "search", 44, []),
        key("ReFile", "columns", "columns", 8, []),
        key("ReFile", "list", "list", 37, []),
        key("ReFile", "sortName", "sort by name", 18, [.maskControl, .maskCommand]),
        key("ReFile", "sortKind", "sort by kind", 19, [.maskControl, .maskCommand]),
        key("ReFile", "sortDate", "sort by date", 20, [.maskControl, .maskCommand]),
        key("ReFile", "sortSize", "sort by size", 21, [.maskControl, .maskCommand]),
        key("ReFile", "newFolder", "new folder", 45, []),
        key("ReFile", "info", "info", 34, []),
        key("ReFile", "trash", "move to the Trash", 51, []),
        key("ReFile", "folder", "folder", 18, []),
        key("ReFile", "songs", "songs", 19, []),
        key("ReFile", "radio", "radio", 20, []),
        key("ReFile", "space", "play / pause, turn the page", 49, []),
        key("ReFile", "shuffle", "shuffle", 1, []),
        key("ReFile", "repeat", "repeat", 15, []),
        key("ReFile", "queue", "queue", 12, []),
        key("ReFile", "keep", "keep a station", 40, []),
        key("ReFile", "mini", "mini player, manga", 46, []),
        key("ReFile", "full", "full screen", 3, []),
        key("ReFile", "moreLeft", "more cells ←", 123, .maskShift),
        key("ReFile", "moreRight", "more cells →", 124, .maskShift),
        key("ReFile", "moreUp", "more cells ↑", 126, .maskShift),
        key("ReFile", "moreDown", "more cells ↓", 125, .maskShift),
        key("ReFile", "selectAll", "all cells", 0, .maskCommand),
        key("ReFile", "copy", "copy", 8, .maskCommand),
        key("ReFile", "cut", "cut", 7, .maskCommand),
        key("ReFile", "paste", "paste", 9, .maskCommand),
        key("ReFile", "addLeft", "a column ←", 123, [.maskShift, .maskCommand]),
        key("ReFile", "addRight", "a column →", 124, [.maskShift, .maskCommand]),
        key("ReFile", "addUp", "a row ↑", 126, [.maskShift, .maskCommand]),
        key("ReFile", "addDown", "a row ↓", 125, [.maskShift, .maskCommand]),
        key("ReFile", "deleteRow", "delete the row", 51, .maskCommand),
        key("ReFile", "deleteColumn", "delete the column", 51, [.maskShift, .maskCommand]),
        key("ReFile", "sortDown", "sort by the column, down", 125, [.maskControl, .maskShift]),
        key("ReFile", "sortUp", "sort by the column, up", 126, [.maskControl, .maskShift]),
        key("ReFile", "undo", "undo", 6, .maskCommand),
        key("ReFile", "redo", "redo", 6, [.maskShift, .maskCommand]),
        key("ReSurf", "newWindow", "new window", 45, .maskCommand),
        key("ReSurf", "newTab", "new tab", 17, .maskCommand),
        key("ReSurf", "address", "address", 37, .maskCommand),
        key("ReSurf", "closeTab", "close tab", 13, [.maskCommand, .maskShift]),
        key("ReSurf", "nextTab", "next tab", 48, .maskControl),
        key("ReSurf", "tabUp", "previous tab", 126, .maskShift),
        key("ReSurf", "tabDown", "next tab", 125, .maskShift),
        key("ReSurf", "back", "back", 33, .maskCommand),
        key("ReSurf", "forward", "forward", 30, .maskCommand),
        key("ReSurf", "reload", "reload", 15, .maskCommand),
        key("ReSurf", "favourite", "favourite", 2, .maskCommand),
        key("ReSurf", "video", "video fills the page", 3, .maskCommand),
        key("ReSurf", "pageFull", "page fills the window", 3, [.maskCommand, .maskShift]),
        key("ReSurf", "info", "info", 34, .maskCommand),
        key("ReSurf", "left", "previous page", 123, []),
        key("ReSurf", "right", "next page", 124, []),
        key("ReSurf", "up", "choose ↑", 126, []),
        key("ReSurf", "down", "choose ↓", 125, []),
        key("ReSurf", "enter", "open", 36, []),
        key("ReNote", "newWindow", "new window", 45, .maskCommand),
        key("ReNote", "up", "the note above", 126, []),
        key("ReNote", "down", "the note below", 125, []),
        key("ReNote", "left", "the space before", 123, []),
        key("ReNote", "right", "the next space", 124, []),
        key("ReNote", "newNote", "new note", 45, []),
        key("ReNote", "edit", "edit", 14, []),
        key("ReNote", "enter", "edit", 36, []),
        key("ReNote", "search", "search", 44, []),
        key("ReNote", "find", "search", 3, .maskCommand),
        key("ReNote", "delete", "delete", 51, []),
        key("ReNote", "esc", "home, back", 53, []),
        key("ReNote", "save", "save", 1, .maskCommand),
        key("ReNote", "highlight", "highlight", 11, .maskCommand),
        key("ReNote", "draw", "draw", 2, .maskCommand),
        key("ReNote", "undo", "undo", 6, .maskCommand),
        key("ReNote", "redo", "redo", 6, [.maskCommand, .maskShift]),
        key("ReNote", "redoY", "redo", 16, .maskControl),
        key("ReTerm", "newWindow", "new window", 45, .maskCommand),
        key("ReTerm", "term", "TERM", 17, [.maskCommand, .maskShift]),
        key("ReTerm", "chat", "CHAT", 8, [.maskCommand, .maskShift]),
        key("ReTerm", "wholeWindow", "the whole window", 3, [.maskCommand, .maskShift]),
        key("ReTerm", "newConversation", "new conversation", 40, .maskCommand),
        key("ReTerm", "conversationUp", "the conversation above", 126, .maskShift),
        key("ReTerm", "conversationDown", "the conversation below", 125, .maskShift),
        key("ReTerm", "deleteConversation", "delete the conversation", 51, [.maskCommand, .maskShift]),
        key("ReTerm", "up", "before", 126, []),
        key("ReTerm", "down", "after", 125, []),
        key("ReTerm", "tab", "complete, the next provider", 48, []),
        key("ReTerm", "stop", "stop / clear the line", 8, .maskControl),
        key("ReTerm", "end", "end of input", 2, .maskControl),
        key("ReTerm", "suspend", "suspend", 6, .maskControl),
        key("ReTerm", "bigger", "text bigger", 24, .maskCommand),
        key("ReTerm", "smaller", "text smaller", 27, .maskCommand),
        key("ReTerm", "actualSize", "text as it was", 29, .maskCommand),
        key("ReTerm", "send", "send", 36, []),
        key("ReTerm", "newLine", "new line", 36, .maskShift),
        key("ReTerm", "esc", "stop the answer", 53, []),
    ]

    /// "ReSurf.newTab"
    static func named(_ name: String) -> AppKey? {
        let parts = name.split(separator: ".").map(String.init)
        guard parts.count == 2 else { return nil }
        return all.first { $0.app == parts[0] && $0.id == parts[1] }
    }

    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ReSpace/keys.json")

    private static var kept: [String: [String: String]] {
        get { (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: String]] } ?? [:] }
        set {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: newValue, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: file, options: .atomic)
            }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.artursavytskyi.re.keys"), object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    var shortcut: Shortcut {
        get { Self.kept[app]?[id].flatMap(Shortcut.init(kept:)) ?? standard }
        nonmutating set {
            var all = Self.kept
            var mine = all[app] ?? [:]
            mine[id] = newValue == standard ? nil : newValue.kept
            all[app] = mine.isEmpty ? nil : mine
            Self.kept = all
        }
    }
}

/// A key the popup sets: one of the desk's, or one of an app's.
enum Settable: Equatable {
    case desk(DeskKey)
    case app(AppKey)

    init?(_ name: String) {
        if let desk = DeskKey(rawValue: name) { self = .desk(desk) } else if let app = AppKey.named(name) { self = .app(app) } else { return nil }
    }

    var title: String {
        switch self { case .desk(let k): k.title; case .app(let k): k.title }
    }

    var standard: Shortcut {
        switch self { case .desk(let k): k.standard; case .app(let k): k.standard }
    }

    var shortcut: Shortcut {
        get { switch self { case .desk(let k): k.shortcut; case .app(let k): k.shortcut } }
        nonmutating set { switch self { case .desk(let k): k.shortcut = newValue; case .app(let k): k.shortcut = newValue } }
    }

    var changed: Bool { shortcut != standard }

    /// the others its keys can't be shared with: the desk's all (they are taken before any app sees them), and
    /// an app's own
    var neighbours: [Settable] {
        switch self {
        case .desk: return DeskKey.allCases.map { .desk($0) }.filter { $0 != self }
        case .app(let k): return AppKey.all.filter { $0.app == k.app && $0 != k }.map { .app($0) }
        }
    }
}

/// The desk's own keys, each one a thing it does: as they come, or as set in the keys' popup (⌘/), kept.
enum DeskKey: String, CaseIterable {
    case settings, keys, guide, dashboard, lock, appearance, language, stillWallpaper, blurWallpaper
    case plusMarks, flush, almostFull, tiling, nextArrangement, promote, pin, otherScreen, focusDesk, sidesIn, sidesOut, wordsIn, wordsOut
    case focusLeft, focusRight, focusUp, focusDown, tradeLeft, tradeRight, tradeUp, tradeDown
    case resizeLeft, resizeRight, resizeUp, resizeDown
    case arrange1, arrange2, arrange3, arrange4, arrange5, arrange6
    case desktopUp, desktopDown, carryUp, carryDown, wallpaperBack, wallpaperNext
    case openFile, openSurf, openTerm, openNote

    /// its line in the popup
    var title: String {
        switch self {
        case .settings: "settings"
        case .keys: "these keys"
        case .guide: "the guide"
        case .dashboard: "the dashboard: the Mac now"
        case .lock: "lock screen"
        case .appearance: "light / dark"
        case .language: "English / 日本語"
        case .stillWallpaper: "video wallpaper still / moving"
        case .blurWallpaper: "blur the wallpaper on / off"
        case .plusMarks: "plus marks on / off"
        case .flush: "flush on / off"
        case .almostFull: "almost full on / off"
        case .tiling: "tiling on / off"
        case .nextArrangement: "next arrangement"
        case .promote: "the window becomes the main one"
        case .pin: "pin the window to its place"
        case .otherScreen: "the window to the other screen"
        case .focusDesk: "the focus: the window / the desk"
        case .sidesIn: "nearer the edges, across (the desk, or the app in front)"
        case .sidesOut: "further from the edges, across"
        case .wordsIn: "nearer the edges, down"
        case .wordsOut: "further from the edges, down"
        case .focusLeft, .focusRight, .focusUp, .focusDown: "focus the nearest window"
        case .tradeLeft, .tradeRight, .tradeUp, .tradeDown: "trade places with it"
        case .resizeLeft, .resizeRight, .resizeUp, .resizeDown: "resize the window"
        case .arrange1, .arrange2, .arrange3, .arrange4, .arrange5, .arrange6: "an arrangement"
        case .desktopUp: "the desktop above"
        case .desktopDown: "the desktop below"
        case .carryUp, .carryDown: "take the window there"
        case .wallpaperBack: "previous wallpaper"
        case .wallpaperNext: "next wallpaper"
        case .openFile: "ReFile"
        case .openSurf: "ReSurf"
        case .openTerm: "ReTerm"
        case .openNote: "ReNote"
        }
    }

    /// pressed again and again while held (the arrows); the others once a press
    var repeats: Bool {
        switch self {
        case .focusLeft, .focusRight, .focusUp, .focusDown, .tradeLeft, .tradeRight, .tradeUp, .tradeDown,
             .resizeLeft, .resizeRight, .resizeUp, .resizeDown, .desktopUp, .desktopDown, .wallpaperBack, .wallpaperNext: true
        default: false
        }
    }

    /// the text's while something is typed (but in ReTerm and ReNote)
    var textual: Bool {
        [.focusLeft, .focusRight, .focusUp, .focusDown, .desktopUp, .desktopDown, .wallpaperBack, .wallpaperNext].contains(self)
    }

    /// only with nothing but the desk in front (a letter alone: anywhere else it is typed)
    var deskOnly: Bool { [.openFile, .openSurf, .openTerm, .openNote].contains(self) }

    var standard: Shortcut {
        let cmd: CGEventFlags = .maskCommand, cmdShift: CGEventFlags = [.maskCommand, .maskShift]
        let ctrlAlt: CGEventFlags = [.maskControl, .maskAlternate]
        switch self {
        case .settings: return Shortcut(key: kVK_ANSI_Comma, flags: cmd)
        case .keys: return Shortcut(key: kVK_ANSI_Slash, flags: cmd)
        case .guide: return Shortcut(key: kVK_ANSI_G, flags: cmd)
        case .dashboard: return Shortcut(key: kVK_ANSI_D, flags: ctrlAlt)
        case .lock: return Shortcut(key: kVK_ANSI_L, flags: cmd)
        case .appearance: return Shortcut(key: kVK_ANSI_T, flags: cmdShift)
        case .language: return Shortcut(key: kVK_ANSI_J, flags: cmd)
        case .stillWallpaper: return Shortcut(key: kVK_ANSI_M, flags: cmdShift)
        case .blurWallpaper: return Shortcut(key: kVK_ANSI_B, flags: cmdShift)
        case .plusMarks: return Shortcut(key: kVK_ANSI_Equal, flags: cmd)
        case .flush: return Shortcut(key: kVK_ANSI_Minus, flags: cmd)
        case .almostFull: return Shortcut(key: kVK_ANSI_0, flags: cmd)
        case .tiling: return Shortcut(key: kVK_ANSI_Period, flags: cmd)
        case .nextArrangement: return Shortcut(key: kVK_Space, flags: ctrlAlt)
        case .promote: return Shortcut(key: kVK_Return, flags: ctrlAlt)
        case .pin: return Shortcut(key: kVK_ANSI_P, flags: ctrlAlt)
        case .otherScreen: return Shortcut(key: kVK_ANSI_O, flags: ctrlAlt)
        case .focusDesk: return Shortcut(key: kVK_ANSI_F, flags: ctrlAlt)
        // fn and an arrow (Home, End, Page Up, Page Down): ← → across, ↓ ↑ down
        case .sidesIn: return Shortcut(key: kVK_Home, flags: [])
        case .sidesOut: return Shortcut(key: kVK_End, flags: [])
        case .wordsIn: return Shortcut(key: kVK_PageDown, flags: [])
        case .wordsOut: return Shortcut(key: kVK_PageUp, flags: [])
        case .focusLeft: return Shortcut(key: kVK_LeftArrow, flags: cmd)
        case .focusRight: return Shortcut(key: kVK_RightArrow, flags: cmd)
        case .focusUp: return Shortcut(key: kVK_UpArrow, flags: cmd)
        case .focusDown: return Shortcut(key: kVK_DownArrow, flags: cmd)
        case .tradeLeft: return Shortcut(key: kVK_LeftArrow, flags: [.maskCommand, .maskAlternate])
        case .tradeRight: return Shortcut(key: kVK_RightArrow, flags: [.maskCommand, .maskAlternate])
        case .tradeUp: return Shortcut(key: kVK_UpArrow, flags: [.maskCommand, .maskAlternate])
        case .tradeDown: return Shortcut(key: kVK_DownArrow, flags: [.maskCommand, .maskAlternate])
        // ⌘fn and an arrow: ⌘ Home, End, Page Up, Page Down
        case .resizeLeft: return Shortcut(key: kVK_Home, flags: cmd)
        case .resizeRight: return Shortcut(key: kVK_End, flags: cmd)
        case .resizeUp: return Shortcut(key: kVK_PageUp, flags: cmd)
        case .resizeDown: return Shortcut(key: kVK_PageDown, flags: cmd)
        case .arrange1: return Shortcut(key: kVK_ANSI_1, flags: cmd)
        case .arrange2: return Shortcut(key: kVK_ANSI_2, flags: cmd)
        case .arrange3: return Shortcut(key: kVK_ANSI_3, flags: cmd)
        case .arrange4: return Shortcut(key: kVK_ANSI_4, flags: cmd)
        case .arrange5: return Shortcut(key: kVK_ANSI_5, flags: cmd)
        case .arrange6: return Shortcut(key: kVK_ANSI_6, flags: cmd)
        case .desktopUp: return Shortcut(key: kVK_UpArrow, flags: .maskAlternate)
        case .desktopDown: return Shortcut(key: kVK_DownArrow, flags: .maskAlternate)
        case .carryUp: return Shortcut(key: kVK_UpArrow, flags: [.maskCommand, .maskControl])
        case .carryDown: return Shortcut(key: kVK_DownArrow, flags: [.maskCommand, .maskControl])
        case .wallpaperBack: return Shortcut(key: kVK_LeftArrow, flags: .maskAlternate)
        case .wallpaperNext: return Shortcut(key: kVK_RightArrow, flags: .maskAlternate)
        case .openFile: return Shortcut(key: kVK_ANSI_F, flags: [])
        case .openSurf: return Shortcut(key: kVK_ANSI_S, flags: [])
        case .openTerm: return Shortcut(key: kVK_ANSI_T, flags: [])
        case .openNote: return Shortcut(key: kVK_ANSI_N, flags: [])
        }
    }

    /// pressed with any app in front (a hot key); the others only with the desk or a Re app in front
    var anywhere: Bool {
        [.dashboard, .appearance, .stillWallpaper, .blurWallpaper, .nextArrangement, .promote, .pin, .otherScreen, .focusDesk].contains(self)
    }

    var shortcut: Shortcut {
        get { UserDefaults.standard.string(forKey: "key." + rawValue).flatMap(Shortcut.init(kept:)) ?? standard }
        nonmutating set {
            if newValue == standard {
                UserDefaults.standard.removeObject(forKey: "key." + rawValue)
            } else {
                UserDefaults.standard.set(newValue.kept, forKey: "key." + rawValue)
            }
        }
    }

    var changed: Bool { shortcut != standard }

    /// The distances' keys: with a Re app in front, its windows' (it is told, and sets its own); with the desk
    /// in front, the desk's.
    private func spacing(_ axis: String, _ way: Int, desk: () -> Void) {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, tiledApps.contains(front) {
            // with A held (fn A and the arrows): the app in front sets its own, then gives the same to the others
            let all = CommandKeys.allHeld ? " all" : ""
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.artursavytskyi.re.spacing"), object: "\(front) \(axis) \(way)\(all)", userInfo: nil, deliverImmediately: true)
        } else {
            desk()
        }
    }

    func run() {
        switch self {
        case .settings: KeysPopup.shared.close(); DashboardPopup.shared.close(); GuidePopup.shared.close(); SettingsPopup.shared.toggle()
        case .keys: SettingsPopup.shared.close(); DashboardPopup.shared.close(); GuidePopup.shared.close(); KeysPopup.shared.toggle()
        case .guide: SettingsPopup.shared.close(); DashboardPopup.shared.close(); KeysPopup.shared.close(); GuidePopup.shared.toggle()
        case .dashboard: SettingsPopup.shared.close(); KeysPopup.shared.close(); GuidePopup.shared.close(); DashboardPopup.shared.toggle()
        case .lock: LockScreen.shared.show()
        case .appearance: Appearance.toggle()
        case .language: Language.toggle()
        case .stillWallpaper: LiveWallpaper.shared.frozen.toggle(); CommandKeys.refreshSettings()
        case .blurWallpaper: WallpaperBlur.on.toggle(); CommandKeys.refreshSettings()
        case .plusMarks: PlusMarks.on.toggle(); CommandKeys.refreshSettings()
        case .flush: Tiler.shared.flush.toggle(); CommandKeys.refreshSettings()
        case .almostFull: Tiler.shared.almostFull.toggle(); CommandKeys.refreshSettings()
        case .tiling: Tiler.shared.on.toggle(); CommandKeys.refreshSettings()
        case .nextArrangement: Tiler.shared.nextArrangement()
        case .promote: Tiler.shared.promote()
        case .pin: Tiler.shared.togglePin()
        case .otherScreen: Tiler.shared.toOtherScreen()
        case .focusDesk: Tiler.shared.toggleFocus()
        case .sidesIn: spacing("x", -1) { SideMargin.across.move(-1) }
        case .sidesOut: spacing("x", 1) { SideMargin.across.move(1) }
        case .wordsIn: spacing("y", -1) { SideMargin.down.move(-1) }
        case .wordsOut: spacing("y", 1) { SideMargin.down.move(1) }
        case .focusLeft: Tiler.shared.focus(.left)
        case .focusRight: Tiler.shared.focus(.right)
        case .focusUp: Tiler.shared.focus(.up)
        case .focusDown: Tiler.shared.focus(.down)
        case .tradeLeft: Tiler.shared.move(.left)
        case .tradeRight: Tiler.shared.move(.right)
        case .tradeUp: Tiler.shared.move(.up)
        case .tradeDown: Tiler.shared.move(.down)
        case .resizeLeft: Tiler.shared.resize(.left)
        case .resizeRight: Tiler.shared.resize(.right)
        case .resizeUp: Tiler.shared.resize(.up)
        case .resizeDown: Tiler.shared.resize(.down)
        case .arrange1, .arrange2, .arrange3, .arrange4, .arrange5, .arrange6:
            // in the order of the arrangements' list, tiling on
            let all: [DeskKey] = [.arrange1, .arrange2, .arrange3, .arrange4, .arrange5, .arrange6]
            if let n = all.firstIndex(of: self), n < Arrangement.allCases.count { Tiler.shared.choose(Arrangement.allCases[n]) }
        case .desktopUp: Desktops.shared.step(-1)
        case .desktopDown: Desktops.shared.step(1)
        case .carryUp: Desktops.shared.take(-1)
        case .carryDown: Desktops.shared.take(1)
        case .wallpaperBack: Wallpapers.step(-1)
        case .wallpaperNext: Wallpapers.step(1)
        case .openFile: ReDesk.open(corners[0])
        case .openSurf: ReDesk.open(corners[1])
        case .openTerm: ReDesk.open(corners[2])
        case .openNote: ReDesk.open(corners[3])
        }
    }
}

/// The desk's ⌘ keys, only while the desk or one of the Re apps is in front (elsewhere they keep their usual
/// meaning): ⌘, settings, ⌘/ the keys, ⌘L lock screen, ⌘J English / 日本語, ⌘= plus marks, ⌘- flush,
/// ⌘0 almost full, ⌘. tiling, ⌘1…⌘6 an arrangement; ⌘ arrows the focus to the nearest window, ⌘⌥ arrows
/// trade places with it, ⌘fn arrows resize it; ⌥↑ / ⌥↓ the desktop above / below, ⌘⌃↑ / ⌘⌃↓ the window
/// in front taken there; ⌥← / ⌥→ the previous / next wallpaper. While something is being typed, ⌘ and ⌥
/// arrows stay the text's (but in ReTerm and ReNote). Taking a key away from an app needs an event tap, which needs the Accessibility
/// permission.
enum CommandKeys {
    private static var tap: CFMachPort?
    /// a key being set in the popup: every key goes to it
    static var recording = false
    /// A held down with fn: the distances' keys set every app's at once
    static var allHeld = false

    /// the desk or a Re app in front (for the tap, before any key's action)
    static func oursInFrontNow() -> Bool { oursInFront() }

    /// Tries now and again later: the tap can only be made once the permission is given.
    static func install() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { install() }
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = CommandKeys.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            // fn with A held: the distances set by the arrows go to every app (A itself is kept, typing nothing)
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if key == kVK_ANSI_A {
                if type == .keyUp {
                    guard CommandKeys.allHeld else { return Unmanaged.passUnretained(event) }
                    CommandKeys.allHeld = false
                    return nil
                }
                let others = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
                if event.flags.contains(.maskSecondaryFn) && others.isEmpty && (CommandKeys.allHeld || CommandKeys.oursInFrontNow()) {
                    CommandKeys.allHeld = true
                    return nil
                }
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            guard let action = CommandKeys.action(for: event) else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async(execute: action)
            return nil
        }, userInfo: nil) else { return }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// a toggle in it changed by a key: the open settings show it
    static func refreshSettings() {
        if SettingsPopup.shared.isVisible { SettingsPopup.shared.refresh() }
    }


    /// Nothing but the desk in front: ReDesk, or Finder with no window of its own in front (its desktop)
    /// and nothing being typed (a name being changed). What was seen goes to Keys.log.
    private static func deskInFront() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { log("no app in front: yes"); return true }
        if front == NSRunningApplication.current { log("ReDesk in front: yes"); return true }
        guard front.bundleIdentifier == "com.apple.finder" else { log("\(front.bundleIdentifier ?? "?") in front: no"); return false }
        let finder = AXUIElementCreateApplication(front.processIdentifier)
        if let focused = attribute(finder, kAXFocusedUIElementAttribute),
           let role = attribute(focused as! AXUIElement, kAXRoleAttribute) as? String,
           role == kAXTextFieldRole || role == kAXTextAreaRole { log("Finder, typing in a \(role): no"); return false }
        guard let window = attribute(finder, kAXFocusedWindowAttribute) else { log("Finder, no window: yes"); return true }
        // the desktop is no standard window
        let subrole = attribute(window as! AXUIElement, kAXSubroleAttribute) as? String ?? "none"
        let role = attribute(window as! AXUIElement, kAXRoleAttribute) as? String ?? "none"
        let desk = subrole != kAXStandardWindowSubrole && subrole != kAXDialogSubrole
        log("Finder, window \(role) / \(subrole): \(desk ? "yes" : "no")")
        return desk
    }

    /// the desk or a Re app in front: the desk's ⌘ keys are taken
    private static func oursInFront() -> Bool {
        tiledApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") || deskInFront()
    }

    /// the apps where ⌘ and ⌥ arrows are the desk's even while typing: ReTerm (its line to type always has
    /// the focus) and ReNote
    private static let deskWhileTyping: Set<String> = ["com.artursavytskyi.reterm", "com.artursavytskyi.renote"]

    /// something being typed in the app in front (a text field or area has the focus); never in ReTerm and ReNote
    private static func typing() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              !deskWhileTyping.contains(front.bundleIdentifier ?? "") else { return false }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        guard let focused = attribute(app, kAXFocusedUIElementAttribute),
              let role = attribute(focused as! AXUIElement, kAXRoleAttribute) as? String else { return false }
        return role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
    }

    private static func log(_ line: String) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReDesk/Keys.log")
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func action(for event: CGEvent) -> (() -> Void)? {
        if recording { return nil }
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // the desk's own keys, as kept (set in the popup or as they came)
        let pressed = Shortcut(key: key, flags: flags)
        guard let own = DeskKey.allCases.first(where: { !$0.anywhere && $0.shortcut == pressed }) else { return nil }
        if !own.repeats && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
        if own.deskOnly { return deskInFront() ? { own.run() } : nil }
        guard oursInFront(), !(own.textual && typing()) else { return nil }
        return { own.run() }
    }
}

// ── tiling: the Re apps' windows share the middle of the desk ──
// The windows keep an order, newest first; the arrangement decides where each one goes.
// Changes glide; a window dragged onto another's place swaps with it. Pulling a window's edge moves the
// cut between it and its neighbour, which gives way as it goes; anything else snaps back.
// Moving other apps' windows takes the Accessibility permission, asked for when tiling is turned on.

let tiledApps: Set<String> = Set(corners.map(\.bundle))
/// between the windows: none while Flush (they make one window), else 10
var tileGap: CGFloat { Tiler.shared.flush ? 0 : edgeGap }
/// from the screen's edges in Almost Full
let edgeGap: CGFloat = 10

/// Flush: which of each window's corners are rounded (only the outer ones of the whole) and which of its
/// edges touch another window, told to its app (a distributed notification, as Hide / Show Windows), which
/// rounds only those corners and draws no rim along those edges. Bits: corners 1 top left, 2 top right,
/// 4 bottom left, 8 bottom right; edges 1 top, 2 right, 4 bottom, 8 left.
enum WindowJoins {
    static let name = Notification.Name("com.artursavytskyi.re.corners")

    /// `pinned`: the windows pinned to their places (⌃⌥P), which write P in their top left corner.
    /// `shared`: ReDesk lays one glass under them all (GlassBackdrop): each window drops its own.
    static func tell(_ windows: [(element: AXUIElement, frame: NSRect)], separate: Bool, pinned: [AXUIElement] = [], shared: Bool = false) {
        guard let top = NSScreen.screens.first?.frame.maxY else { return }
        for (i, (element, r)) in windows.enumerated() {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { continue }
            let others = windows.enumerated().filter { $0.offset != i }.map(\.element.frame)
            var corners = 15, edges = 0
            if !separate {
                let near: CGFloat = 2
                func touched(_ p: CGPoint) -> Bool {
                    others.contains { p.x >= $0.minX - near && p.x <= $0.maxX + near && p.y >= $0.minY - near && p.y <= $0.maxY + near }
                }
                corners = 0
                if !touched(CGPoint(x: r.minX, y: r.maxY)) { corners |= 1 }
                if !touched(CGPoint(x: r.maxX, y: r.maxY)) { corners |= 2 }
                if !touched(CGPoint(x: r.minX, y: r.minY)) { corners |= 4 }
                if !touched(CGPoint(x: r.maxX, y: r.minY)) { corners |= 8 }
                func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool { min(a1, b1) - max(a0, b0) > near }
                for o in others {
                    if abs(o.minY - r.maxY) <= near && overlap(r.minX, r.maxX, o.minX, o.maxX) { edges |= 1 }
                    if abs(o.minX - r.maxX) <= near && overlap(r.minY, r.maxY, o.minY, o.maxY) { edges |= 2 }
                    if abs(o.maxY - r.minY) <= near && overlap(r.minX, r.maxX, o.minX, o.maxX) { edges |= 4 }
                    if abs(o.maxX - r.minX) <= near && overlap(r.minY, r.maxY, o.minY, o.maxY) { edges |= 8 }
                }
            }
            // the window's place as the apps see it: from the top left of the main screen, in points
            let pin = pinned.contains { CFEqual($0, element) } ? 1 : 0
            let info: [String: Any] = ["pid": Int(pid), "corners": corners, "edges": edges, "pinned": pin, "shared": shared ? 1 : 0,
                                       "x": Double(r.minX), "y": Double(top - r.maxY), "w": Double(r.width), "h": Double(r.height)]
            DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
        }
    }
}

/// An Accessibility window, comparable so the order can be kept between looks. Known by its window
/// number: put away on another desktop and shown again, a window may come back as another Accessibility
/// element (taken for a new window, it lost its place in the turn and its pin); its number stays.
struct TiledWindow: Hashable {
    let element: AXUIElement
    let id: CGWindowID?

    init(element: AXUIElement) {
        self.element = element
        id = Desktops.number(of: element)
    }

    static func == (a: Self, b: Self) -> Bool {
        if let x = a.id, let y = b.id { return x == y }
        return CFEqual(a.element, b.element)
    }

    func hash(into hasher: inout Hasher) {
        if let id { hasher.combine(id) } else { hasher.combine(CFHash(element)) }
    }
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// `r` cut into pieces side by side (`across`) or one above another (the top one first), `tileGap` apart,
/// each as big as its share of the room.
func pieces(_ r: NSRect, across: Bool, _ shares: [CGFloat]) -> [NSRect] {
    let total = shares.reduce(0, +)
    let room = (across ? r.width : r.height) - tileGap * CGFloat(shares.count - 1)
    var before: CGFloat = 0
    return shares.enumerated().map { i, share in
        // from the start (the left, or the top) to each piece's start and end
        let start = room * before / total + CGFloat(i) * tileGap
        before += share
        let end = i == shares.count - 1 ? (across ? r.width : r.height) : room * before / total + CGFloat(i) * tileGap
        return across ? NSRect(x: r.minX + start, y: r.minY, width: end - start, height: r.height)
            : NSRect(x: r.minX, y: r.maxY - end, width: r.width, height: end - start)
    }
}

/// How an arrangement cuts the area: a window's place, or parts side by side (`across`) or one above
/// another, each with its share. A part's path ("", "/0", "/1/2" …) names it, so a share the user
/// gave it by resizing a window can be kept.
indirect enum Cut {
    case window(Int)
    case parts(across: Bool, [Cut], shares: [CGFloat])
}

/// Shares the user gave, by a part's path.
typealias Shares = [String: [CGFloat]]

/// Where the windows go; the first window is the main one.
enum Arrangement: String, CaseIterable {
    // ⌘1…⌘6, in this order
    case main, mainTop, centre, grid, single, fibonacci

    var title: String {
        switch self {
        case .main: "Main and Stack"
        case .mainTop: "Main on Top"
        case .centre: "Main in the Middle"
        case .grid: "Grid"
        case .single: "One at a Time"
        case .fibonacci: "Fibonacci"
        }
    }

    /// the golden ratio: Fibonacci's cuts
    static let golden: CGFloat = (1 + 5.0.squareRoot()) / 2

    /// One at a Time: each window fills the whole area (nearly all the screen with Almost Full), the focused one on top
    var stacks: Bool { self == .single }

    func cut(count: Int) -> Cut {
        let all = (0 ..< count).map(Cut.window)
        func even(_ parts: [Cut], across: Bool) -> Cut {
            parts.count == 1 ? parts[0] : .parts(across: across, parts, shares: Array(repeating: 1, count: parts.count))
        }
        guard count > 1, !stacks else { return .window(0) }
        let rest = Array(all.dropFirst())
        switch self {
        case .main:
            // the main one on the left half, the others one above another on the right
            return .parts(across: true, [all[0], even(rest, across: false)], shares: [1, 1])
        case .mainTop:
            // the main one across the top 60%, the others side by side under it
            return .parts(across: false, [all[0], even(rest, across: true)], shares: [0.6, 0.4])
        case .centre:
            // the main one in the middle half, the others shared out to the left and the right,
            // alternating, so a new window lands on the side with fewer
            guard count > 2 else { return even(all, across: true) }
            let left = rest.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            let right = rest.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            return .parts(across: true, [even(left, across: false), all[0], even(right, across: false)], shares: [1, 2, 1])
        case .fibonacci:
            // the golden spiral: the first window the larger part of the golden cut (61.8%), the rest cut again the
            // other way, and so on, turning round (left, top, right, bottom…): each window the next square of it
            func spiral(_ from: Int, _ turn: Int) -> Cut {
                if from == count - 1 { return all[from] }
                let across = turn % 2 == 0
                let first = turn % 4 < 2
                let rest = spiral(from + 1, turn + 1)
                return .parts(across: across, first ? [all[from], rest] : [rest, all[from]],
                              shares: first ? [Double(Self.golden), 1] : [1, Double(Self.golden)])
            }
            return spiral(0, 0)
        case .grid:
            // as square as it gets; a short last row is spread across the width
            let across = Int(Double(count).squareRoot().rounded(.up))
            let rows = stride(from: 0, to: count, by: across).map { even(Array(all[$0 ..< min($0 + across, count)]), across: true) }
            return even(rows, across: false)
        case .single:
            return .window(0)
        }
    }

    /// Every window's place. One at a Time and Full Screen: every window fills the area (Full Screen's is the
    /// whole screen under the menu bar, which then shows the apps: AppMenuBar); the focused one is on top.
    func frames(count: Int, in area: NSRect, shares: Shares = [:]) -> [NSRect] {
        guard count > 0 else { return [] }
        if stacks { return Array(repeating: area, count: count) }
        var out = Array(repeating: area, count: count)
        func lay(_ cut: Cut, _ r: NSRect, _ path: String) {
            switch cut {
            case .window(let i): out[i] = r
            case .parts(let across, let parts, let given):
                let rects = pieces(r, across: across, shares[path].flatMap { $0.count == given.count ? $0 : nil } ?? given)
                for i in parts.indices { lay(parts[i], rects[i], path + "/\(i)") }
            }
        }
        lay(cut(count: count), area, "")
        return out
    }
}

/// Where a window is, in AppKit coordinates (Accessibility counts from the top left of the main screen).
func frame(of window: AXUIElement) -> NSRect? {
    guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute),
          let top = NSScreen.screens.first?.frame.maxY else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return NSRect(x: point.x, y: top - point.y - size.height, width: size.width, height: size.height)
}

/// Moves a window; `exact` sets position, size and position again, as a window may refuse
/// a size that doesn't fit where it is.
func setFrame(of window: AXUIElement, to r: NSRect, size resize: Bool = true, exact: Bool = false) {
    guard let top = NSScreen.screens.first?.frame.maxY else { return }
    var origin = CGPoint(x: r.minX.rounded(), y: (top - r.maxY).rounded())
    var size = CGSize(width: r.width.rounded(), height: r.height.rounded())
    guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    if resize { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent) }
    if exact { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
}

/// The place a dragged window would go: a soft frame over it, above the windows.
/// Glass windows joined (Flush): one glass under them all, so they are one, with no seams where they meet
/// (each window's own blur ends at its edges). A window just under the others (the normal level less one),
/// the system's dark blur of what is behind, square as the windows on glass are; clicks go through.
final class GlassBackdrop {
    static let shared = GlassBackdrop()
    private let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private(set) var shown = false

    init() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        // square, as the windows on glass are
        window.contentView = glass
    }

    /// Under `r`, gliding there as the windows do (`duration`).
    func show(_ r: NSRect, duration: Double) {
        if !shown || duration == 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(r, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1, 0.5, 1)
                window.animator().setFrame(r, display: true)
            }
        }
        if !shown { window.orderFront(nil) }
        shown = true
    }

    func hide() {
        guard shown else { return }
        window.orderOut(nil)
        shown = false
    }
}

final class DropOverlay {
    private final class Outline: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 14, yRadius: 14)
            ink(0.14).setFill()
            path.fill()
            strong.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    private let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private(set) var shown = false

    init() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = Outline()
        window.alphaValue = 0
    }

    /// A moment over `r`, then gone: brighter for a pin, fainter for letting go.
    func flash(_ r: NSRect, strong: Bool) {
        window.contentView?.alphaValue = strong ? 1 : 0.45
        show(r)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.hide() }
    }

    func show(_ r: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            if shown { window.animator().setFrame(r, display: true) } else { window.setFrame(r, display: true) }
            window.animator().alphaValue = 1
        }
        window.orderFront(nil)
        shown = true
    }

    func hide() {
        guard shown else { return }
        shown = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; window.animator().alphaValue = 0 }
    }
}

final class Tiler {
    static let shared = Tiler()
    private static let key = "tiling"

    var on = UserDefaults.standard.bool(forKey: Tiler.key) {
        didSet {
            UserDefaults.standard.set(on, forKey: Tiler.key)
            if on { start() } else { stop() }
            NotificationCenter.default.post(name: .arrangementChanged, object: nil)
        }
    }

    var arrangement = Arrangement(rawValue: UserDefaults.standard.string(forKey: "arrangement") ?? "") ?? .main {
        didSet {
            UserDefaults.standard.set(arrangement.rawValue, forKey: "arrangement")
            retile()
            NotificationCenter.default.post(name: .arrangementChanged, object: nil)
        }
    }

    /// Almost Full: the windows share nearly the whole screen (under the menu bar, `tileGap` from the
    /// edges) instead of the desk's middle, in any arrangement, with the apps across the top as in Full Screen
    var almostFull = UserDefaults.standard.bool(forKey: "almostFull") {
        didSet {
            UserDefaults.standard.set(almostFull, forKey: "almostFull")
            retile()
            NotificationCenter.default.post(name: .arrangementChanged, object: nil)
        }
    }

    /// Flush (⌘-): no room between the windows, and only the outer corners of them all rounded, as one window
    var flush = UserDefaults.standard.bool(forKey: "flushTiles") {
        didSet {
            UserDefaults.standard.set(flush, forKey: "flushTiles")
            retile()
            NotificationCenter.default.post(name: .arrangementChanged, object: nil)
        }
    }

    /// whether the apps go across the top: Full Screen, or Almost Full
    var showsApps: Bool { on && almostFull }

    /// the windows, main first; `slots[i]` is where `order[i]` belongs
    private var order: [TiledWindow] = []
    /// every window still alive in its turn, also those out of sight for now (on another desktop, its app
    /// hidden), so one coming back takes its old place instead of the newest one's
    private var known: [TiledWindow] = []
    private var slots: [NSRect] = []
    /// pinned windows (⌃⌥P), each anchored to its place in the turn: windows coming and going, swaps and
    /// a new main one leave it where it is
    private var pinned: [TiledWindow: Int] = [:]
    /// where each window really ended up (a window may keep a size of its own), to tell when it is moved
    private var settled: [TiledWindow: NSRect] = [:]
    /// the windows going away to another desktop (sliding and fading out, then put away): not this desktop's
    /// any more, though still on the screen for a moment. Looked at with them, the turn got mixed with the
    /// other desktop's, and their slide taken for a drag: places swapped, and the pinned ones moved
    var leaving: Set<CGWindowID> = []

    private var timer: Timer?
    private var ticks = 0
    private var pressed = false
    private var dragged: Int?
    /// the window being resized with the mouse
    private var resizing: Int?
    /// the shares the user gave the parts by resizing, per arrangement and number of windows
    private var shares: [String: Shares] = [:]
    /// (each desktop its own: resizing on one leaves the others as they were)
    private var sharesKey: String { "\(arrangement.rawValue) \(order.count) \(Desktops.shared.current)" }
    /// a part never gets smaller than this
    private let smallest: CGFloat = 240
    private let overlay = DropOverlay()
    private let mark = DropOverlay()

    private struct Move { let window: TiledWindow; let from: NSRect; let to: NSRect }

    /// The windows on the other screens (an external display), each screen's in its own turn, newest first:
    /// tiled in that screen's middle in the same arrangement, without pins or resized shares (the main
    /// screen's turn is `order`).
    private var others: [Int: [TiledWindow]] = [:]
    /// the other screens' glass under their windows in Flush, one each
    private var otherGlass: [Int: GlassBackdrop] = [:]

    /// a window in another screen's turn
    private func isElsewhere(_ window: TiledWindow) -> Bool { others.values.contains { $0.contains(window) } }

    /// the Re apps' windows on each other screen now, by the screen's place among the screens
    private func otherOpen() -> [Int: [TiledWindow]] {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return [:] }
        let visible = Desktops.onScreen()
        var found: [Int: [TiledWindow]] = [:]
        for app in NSWorkspace.shared.runningApplications where tiledApps.contains(app.bundleIdentifier ?? "") && !app.isHidden {
            let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
            for w in windows {
                guard Desktops.number(of: w).map({ visible.contains($0) && !leaving.contains($0) }) ?? true,
                      attribute(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                      attribute(w, kAXMinimizedAttribute) as? Bool != true,
                      attribute(w, "AXFullScreen") as? Bool != true,
                      let f = frame(of: w) else { continue }
                let middle = NSPoint(x: f.midX, y: f.midY)
                guard let k = screens.indices.dropFirst().first(where: { screens[$0].frame.contains(middle) }) else { continue }
                found[k, default: []].append(TiledWindow(element: w))
            }
        }
        return found
    }

    /// the other screens' turns brought up to date; whether they changed
    @discardableResult
    private func refreshOthers() -> Bool {
        let open = otherOpen()
        var next: [Int: [TiledWindow]] = [:]
        for (k, list) in open {
            let kept = (others[k] ?? []).filter(list.contains)
            // a pinned one stays at its place in the turn
            next[k] = anchored(list.filter { !kept.contains($0) } + kept)
        }
        let changed = next != others
        others = next
        return changed
    }

    /// where the windows share on a screen: as on the main one (the middle, all of it in Full, nearly all in Almost Full)
    private func area(of screen: NSScreen) -> NSRect {
        // under the apps across the top, where they stand on the desk
        var visible = screen.visibleFrame
        visible.size.height -= appStripRoom(screen)
        let layout = Layout(area: visible)
        let almost = NSRect(x: layout.area.minX + edgeGap, y: layout.area.minY + edgeGap,
                            width: layout.area.width - edgeGap * 2, height: layout.area.height - edgeGap)
        return almostFull ? almost : Layout(area: screen.frame).tiles
    }

    /// each other screen's windows and their places there
    private func otherPlaces() -> [(TiledWindow, NSRect)] {
        let screens = NSScreen.screens
        return others.flatMap { k, list -> [(TiledWindow, NSRect)] in
            guard k < screens.count, !list.isEmpty else { return [] }
            let frames = arrangement.frames(count: list.count, in: area(of: screens[k]), shares: shares[otherKey(k, list.count)] ?? [:]).map(\.integral)
            return Array(zip(list, frames))
        }
    }

    /// each other screen's shares as resized, per arrangement, number of windows and desktop
    private func otherKey(_ screen: Int, _ count: Int) -> String { "\(arrangement.rawValue) \(count) \(Desktops.shared.current) screen \(screen)" }

    /// A window on another screen being resized with the mouse: the others there give way as it goes (its
    /// screen's shares follow it). True if one is.
    private func resizingElsewhere() -> Bool {
        let screens = NSScreen.screens
        for (k, list) in others where k < screens.count {
            for (i, window) in list.enumerated() {
                guard let now = frame(of: window.element), let was = settled[window],
                      abs(now.width - was.width) > 2 || abs(now.height - was.height) > 2 else { continue }
                let area = area(of: screens[k])
                let key = otherKey(k, list.count)
                let slots = arrangement.frames(count: list.count, in: area, shares: shares[key] ?? [:]).map(\.integral)
                guard pull(i, count: list.count, slots: slots, area: area, key: key, to: now) else { return true }
                let next = arrangement.frames(count: list.count, in: area, shares: shares[key] ?? [:]).map(\.integral)
                for (j, other) in list.enumerated() where j != i {
                    setFrame(of: other.element, to: next[j], exact: true)
                    settled[other] = frame(of: other.element) ?? next[j]
                }
                // its own edges where they now are: only further pulls count
                settled[window] = now
                return true
            }
        }
        return false
    }

    /// A window on another screen moved by hand: dropped on another's place there, they trade; brought to the
    /// main screen, it joins the turn there. True if one was.
    private func releasedElsewhere(at point: NSPoint?) -> Bool {
        let placed = otherPlaces()
        for (window, place) in placed {
            guard let now = frame(of: window.element), let was = settled[window] else { continue }
            let moved = (abs(now.minX - was.minX) > 4 || abs(now.maxY - was.maxY) > 4)
                && abs(now.width - was.width) <= 2 && abs(now.height - was.height) <= 2
            guard moved else { continue }
            let drop = point ?? NSPoint(x: now.midX, y: now.midY)
            if let (k, list) = others.first(where: { $0.value.contains(window) }), let i = list.firstIndex(of: window),
               let target = placed.first(where: { $0.1.contains(drop) && $0.0 != window }),
               let j = list.firstIndex(of: target.0), pinned[window] == nil, pinned[target.0] == nil {
                var swapped = list
                swapped.swapAt(i, j)
                others[k] = swapped
            }
            _ = place
            lookNow()
            retile()
            return true
        }
        return false
    }

    /// ~/Library/Application Support/ReDesk/Tiler.log: the turn and the pins as they change (to find why a pin goes)
    static func log(_ line: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReDesk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Tiler.log")
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private var lastSaid = ""
    /// the turn (window numbers, pinned ones with their place) and those known out of sight, when it changed
    private func say(_ why: String) {
        let turn = order.map { w in "\(w.id ?? 0)" + (pinned[w].map { "📌\($0)" } ?? "") }.joined(separator: " ")
        let away = known.filter { !order.contains($0) }.map { w in "\(w.id ?? 0)" + (pinned[w].map { "📌\($0)" } ?? "") }
        let pins = pinned.map { "\($0.key.id ?? 0)@\($0.value)" }.sorted().joined(separator: ",")
        let line = "[\(turn)] away [\(away.joined(separator: " "))] pins {\(pins)} desktop \(Desktops.shared.current)"
        guard line != lastSaid else { return }
        lastSaid = line
        Self.log("\(why): \(line)")
    }
    private var animation: Timer?

    /// ⌃⌥Space: turns tiling on, or moves to the next arrangement when it is on.
    func nextArrangement() {
        guard on else { return on = true }
        let all = Arrangement.allCases
        arrangement = all[(all.firstIndex(of: arrangement)! + 1) % all.count]
    }

    func start() {
        stop()
        // without the permission, macOS shows its prompt; tiling begins once it is given
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        // the prompt only comes once; after that (or after a rebuild drops the permission) go straight to the list
        if !trusted { Tiler.openAccessibilitySettings() }
        order = []
        // every 50ms: is a window being dragged? Every 0.5s: which windows are open
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        overlay.hide()
        GlassBackdrop.shared.hide()
        otherGlass.values.forEach { $0.hide() }
        // no longer tiled: every window round again, on every screen
        let all = order + others.values.flatMap { $0 }
        WindowJoins.tell(all.compactMap { w in frame(of: w.element).map { (w.element, $0) } }, separate: true)
    }

    private func tick() {
        guard AXIsProcessTrusted() else { return }
        ticks += 1
        if NSEvent.pressedMouseButtons & 1 != 0 {
            pressed = true
            dragging()
        } else if pressed {
            pressed = false
            // a moment for the window to take its last position
            let point = NSEvent.mouseLocation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.released(at: point) }
        } else if ticks % 10 == 0 {
            look()
        }
    }

    /// The windows now open, newest first; tiles again when that changed, or when one was moved or resized.
    private func look() {
        guard animation == nil else { return }
        let open = openWindows()
        let gone = known.filter { !open.contains($0) && !alive($0) }
        if !gone.isEmpty { Self.log("gone: \(gone.map { "\($0.id ?? 0)" + (pinned[$0] != nil ? "📌" : "") })") }
        known = known.filter { !gone.contains($0) }
        known = open.filter { !known.contains($0) } + known
        pinned = pinned.filter { known.contains($0.key) || isElsewhere($0.key) }
        fresh(open)
        let now = anchored(known.filter(open.contains))
        let elsewhere = refreshOthers()
        if now != order {
            order = now
            say("look")
            retile()
        } else if elsewhere {
            retile()
        } else {
            // moved without the mouse (the keyboard, the app itself): back to its place
            released(at: nil)
        }
    }

    /// Now (another desktop in sight): the windows looked at again and tiled into their places (the coming
    /// ones, put under their places to glide up, are not taken for dragged).
    func lookNow() {
        guard on, AXIsProcessTrusted() else { return }
        animation?.invalidate()
        animation = nil
        let open = openWindows()
        let gone = known.filter { !open.contains($0) && !alive($0) }
        if !gone.isEmpty { Self.log("gone: \(gone.map { "\($0.id ?? 0)" + (pinned[$0] != nil ? "📌" : "") })") }
        known = known.filter { !gone.contains($0) }
        known = open.filter { !known.contains($0) } + known
        pinned = pinned.filter { known.contains($0.key) || isElsewhere($0.key) }
        fresh(open)
        order = anchored(known.filter(open.contains))
        say("desktop")
        retile()
    }

    /// Whether a window out of sight still exists (a closed one, or one whose app quit, doesn't): its element
    /// answers, or the window server still has its number (put away, its element may not answer).
    private func alive(_ window: TiledWindow) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &value)
        if error != .invalidUIElement && error != .cannotComplete { return true }
        // put away on another desktop by ReDesk: its element doesn't answer and the window server doesn't
        // list it, but it is there, and comes back
        if let id = window.id, Desktops.shared.holds(id) { return true }
        guard let id = window.id,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
    }

    /// The windows in sight now with their elements as they are now (a window shown again may have a new one),
    /// in the turn, the pins and where they settled.
    private func fresh(_ open: [TiledWindow]) {
        let now = Dictionary(open.map { ($0, $0) }, uniquingKeysWith: { a, _ in a })
        known = known.map { now[$0] ?? $0 }
        pinned = Dictionary(pinned.map { (now[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        settled = Dictionary(settled.map { (now[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// The windows in their turn, each pinned one put back at its place (or last, when there are fewer now).
    private func anchored(_ windows: [TiledWindow]) -> [TiledWindow] {
        var out = windows.filter { pinned[$0] == nil }
        for (window, at) in pinned.filter({ windows.contains($0.key) }).sorted(by: { $0.value < $1.value }) {
            out.insert(window, at: min(at, out.count))
        }
        return out
    }

    /// ⌃⌥P: the focused window pinned to its place, or let go again; a frame lights up over it for a moment.
    func togglePin() {
        guard on, AXIsProcessTrusted() else { return }
        // a window on another screen: pinned at its place in that screen's turn
        if focusedWindow() == nil, let window = focusedReWindow() {
            refreshOthers()
            guard let list = others.values.first(where: { $0.contains(window) }), let at = list.firstIndex(of: window) else { return }
            if pinned[window] == nil { pinned[window] = at } else { pinned[window] = nil }
            say(pinned[window] == nil ? "unpin \(window.id ?? 0) elsewhere" : "pin \(window.id ?? 0) elsewhere")
            if let r = otherPlaces().first(where: { $0.0 == window })?.1 { mark.flash(r, strong: pinned[window] != nil) }
            return retile()
        }
        guard let window = focusedWindow(), let at = order.firstIndex(of: window) else { return }
        if pinned[window] == nil { pinned[window] = at } else { pinned[window] = nil }
        say(pinned[window] == nil ? "unpin \(window.id ?? 0)" : "pin \(window.id ?? 0)")
        if let r = place(of: window) { mark.flash(r, strong: pinned[window] != nil) }
        // the window told, to write PIN or take it away
        retile()
    }

    /// Keeps the turn of the windows in sight (after a swap, a move, a new main one) in `known`,
    /// those out of sight staying where they were.
    private func remember() {
        let spots = known.indices.filter { order.contains(known[$0]) }
        if spots.count == order.count {
            for (spot, window) in zip(spots, order) { known[spot] = window }
        } else {
            known = order + known.filter { !order.contains($0) }
        }
    }

    private func openWindows() -> [TiledWindow] {
        let visible = Desktops.onScreen()
        return NSWorkspace.shared.runningApplications
            // the windows on other desktops are out of sight: not among them
            .filter { tiledApps.contains($0.bundleIdentifier ?? "") && !$0.isHidden }
            .flatMap { app -> [TiledWindow] in
                let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
                return windows
                    .filter { w in
                        // put away on another desktop: Accessibility still lists it, the screen doesn't have it
                        Desktops.number(of: w).map { visible.contains($0) && !self.leaving.contains($0) } ?? true
                            && attribute(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
                            && attribute(w, kAXMinimizedAttribute) as? Bool != true
                            && attribute(w, "AXFullScreen") as? Bool != true
                            // on another screen (an external display): in that screen's turn, not this one's
                            && !Tiler.onOtherScreen(w)
                    }
                    .map { TiledWindow(element: $0) }
            }
    }

    /// The window whose top left left its place, keeping its size, if any.
    private func movedWindow() -> (index: Int, frame: NSRect)? {
        for (i, window) in order.enumerated() {
            guard let now = frame(of: window.element), let was = settled[window] else { continue }
            if (abs(now.minX - was.minX) > 4 || abs(now.maxY - was.maxY) > 4)
                && abs(now.width - was.width) <= 2 && abs(now.height - was.height) <= 2 { return (i, now) }
        }
        return nil
    }

    /// The window whose size changed, if any.
    private func resizedWindow() -> Int? {
        order.firstIndex { window in
            guard let now = frame(of: window.element), let was = settled[window] else { return false }
            return abs(now.width - was.width) > 2 || abs(now.height - was.height) > 2
        }
    }

    /// While the mouse is down: show where a dragged window would go, or let the others give way
    /// to one being resized.
    private func dragging() {
        // a window being resized on another screen: its neighbours there give way
        if animation == nil, !arrangement.stacks, resizingElsewhere() { resizedElsewhere = true; return }
        guard animation == nil, order.count > 1, !arrangement.stacks else { return }
        if dragged == nil && resizing == nil {
            if let k = resizedWindow() { resizing = k } else { dragged = movedWindow()?.index }
        }
        if let resizing { return follow(resizing) }
        guard let dragged else { return }
        let point = NSEvent.mouseLocation
        if let target = slots.firstIndex(where: { $0.contains(point) }), target != dragged,
           pinned[order[dragged]] == nil, pinned[order[target]] == nil {
            overlay.show(slots[target])
        } else {
            overlay.hide()
        }
    }

    /// The mouse is up (or something moved a window): a window dropped on another's place swaps with it;
    /// anything moved or resized goes back to its place.
    /// a window was resized on another screen while the mouse was down: all laid out by the new shares when it is let go
    private var resizedElsewhere = false

    private func released(at point: NSPoint?) {
        overlay.hide()
        dragged = nil
        resizing = nil
        guard on, animation == nil else { return }
        if resizedElsewhere {
            resizedElsewhere = false
            return retile()
        }
        if releasedElsewhere(at: point) { return }
        if let moved = movedWindow() {
            // dragged onto another screen: tiled there now; the others here close up
            if Tiler.onOtherScreen(order[moved.index].element) {
                pinned[order[moved.index]] = nil
                lookNow()
                retile()
                return
            }
            let drop = point ?? NSPoint(x: moved.frame.midX, y: moved.frame.midY)
            if !arrangement.stacks, let target = slots.firstIndex(where: { $0.contains(drop) }), target != moved.index,
               pinned[order[moved.index]] == nil, pinned[order[target]] == nil {
                order.swapAt(moved.index, target)
            }
            retile()
            return
        }
        let resized = order.contains { window in
            guard let now = frame(of: window.element), let was = settled[window] else { return false }
            return abs(now.width - was.width) > 2 || abs(now.height - was.height) > 2
        }
        if resized { retile() }
    }

    /// Where the windows share: the desk's middle, the whole screen in Full Screen, nearly all of it in Almost Full.
    private func tilingArea() -> NSRect? {
        guard let screen = NSScreen.screens.first else { return nil }
        let layout = Layout(area: screen.visibleFrame)
        // Almost Full: right under the top (the menu bar, or the apps' strip where it hides), `tileGap` from the other edges
        let almost = NSRect(x: layout.area.minX + edgeGap, y: layout.area.minY + edgeGap,
                            width: layout.area.width - edgeGap * 2, height: layout.area.height - edgeGap)
        return almostFull ? almost : Layout(area: screen.frame).tiles
    }

    private func places() -> [NSRect] {
        guard let area = tilingArea() else { return [] }
        return arrangement.frames(count: order.count, in: area, shares: shares[sharesKey] ?? [:]).map(\.integral)
    }

    /// A window being resized: the others follow at once.
    private func follow(_ k: Int) {
        guard k < order.count, slots.count == order.count, let now = frame(of: order[k].element), pull(k, to: now)
        else { return }
        let was = slots
        slots = places()
        for (i, window) in order.enumerated() where i != k && slots[i] != was[i] {
            setFrame(of: window.element, to: slots[i], exact: true)
            settled[window] = frame(of: window.element) ?? slots[i]
        }
    }

    /// ⌘fn arrows: the border between the focused window and its neighbour moves that way by a step, so
    /// the window grows toward a neighbour and shrinks away from it, wherever it stands. The border is the
    /// one on the right (below), or the left (above) when there is no neighbour on the right (below).
    func resize(_ direction: Direction) {
        // no waiting for a glide to end: the places are where the windows are going, and a new glide starts
        // from wherever they are
        guard on, !arrangement.stacks, AXIsProcessTrusted() else { return }
        let step: CGFloat = direction == .right || direction == .up ? 80 : -80
        /// the place pulled by a step: its right (lower) border, else its left (upper)
        func pulled(_ slot: NSRect) -> (NSRect, NSRect) {
            var first = slot, second = slot
            if direction == .left || direction == .right {
                first.size.width += step
                second.origin.x += step; second.size.width -= step
            } else {
                first.origin.y += step; first.size.height -= step
                second.size.height += step
            }
            return (first, second)
        }
        // a window on another screen: that screen's shares
        if focusedWindow() == nil, let window = focusedReWindow() {
            refreshOthers()
            let screens = NSScreen.screens
            guard let (k, list) = others.first(where: { $0.value.contains(window) }), k < screens.count,
                  let i = list.firstIndex(of: window) else { return }
            let area = area(of: screens[k]), key = otherKey(k, list.count)
            let places = arrangement.frames(count: list.count, in: area, shares: shares[key] ?? [:]).map(\.integral)
            let (first, second) = pulled(places[i])
            guard pull(i, count: list.count, slots: places, area: area, key: key, to: first)
                    || pull(i, count: list.count, slots: places, area: area, key: key, to: second) else { return }
            return retile()
        }
        guard let window = focusedWindow(), let k = order.firstIndex(of: window), slots.count == order.count else { return }
        var first = slots[k], second = slots[k]
        if direction == .left || direction == .right {
            first.size.width += step                             // the right border
            second.origin.x += step; second.size.width -= step   // the left border
        } else {
            first.origin.y += step; first.size.height -= step    // the border below
            second.size.height += step                           // the border above
        }
        guard pull(k, to: first) || pull(k, to: second) else { return }
        retile()
    }

    /// Each edge of window `k` that is no longer where its place has it moves the cut between its part and
    /// the neighbouring one (the nearest cut that way), to where the edge now is. Whether anything changed.
    private func pull(_ k: Int, to now: NSRect) -> Bool {
        guard let area = tilingArea() else { return false }
        return pull(k, count: order.count, slots: slots, area: area, key: sharesKey, to: now)
    }

    /// The shares of a screen's parts changed so the k-th of its `count` windows (in `slots`, within `area`)
    /// has the edges it was pulled to; kept under `key`. Whether they changed.
    private func pull(_ k: Int, count: Int, slots: [NSRect], area: NSRect, key: String, to now: NSRect) -> Bool {
        guard k < count, slots.count == count else { return false }
        let slot = slots[k]
        var mine = shares[key] ?? [:]
        // the cuts around this window, the nearest first: its part's place among the others
        var around: [(path: String, across: Bool, rects: [NSRect], at: Int)] = []
        func find(_ cut: Cut, _ r: NSRect, _ path: String) -> Bool {
            switch cut {
            case .window(let i): return i == k
            case .parts(let across, let parts, let given):
                let rects = pieces(r, across: across, mine[path].flatMap { $0.count == given.count ? $0 : nil } ?? given)
                for i in parts.indices where find(parts[i], rects[i], path + "/\(i)") {
                    around.append((path, across, rects, i))
                    return true
                }
                return false
            }
        }
        _ = find(arrangement.cut(count: count), area, "")
        // left, right, top, bottom: whether the edge runs across, whether the neighbour comes after, and the
        // part's new size for the edge where the window now has it
        let edges: [(across: Bool, after: Bool, pulled: CGFloat, size: (NSRect) -> CGFloat)] = [
            (true, false, now.minX - slot.minX, { $0.maxX - now.minX }),
            (true, true, now.maxX - slot.maxX, { now.maxX - $0.minX }),
            (false, false, now.maxY - slot.maxY, { now.maxY - $0.minY }),
            (false, true, now.minY - slot.minY, { $0.maxY - now.minY }),
        ]
        var changed = false
        for edge in edges where abs(edge.pulled) > 1 {
            guard let cut = around.first(where: { $0.across == edge.across && (edge.after ? $0.at < $0.rects.count - 1 : $0.at > 0) })
            else { continue }
            let length: (NSRect) -> CGFloat = { edge.across ? $0.width : $0.height }
            var sizes = cut.rects.map(length)
            let j = edge.after ? cut.at + 1 : cut.at - 1
            let both = sizes[cut.at] + sizes[j]
            guard both >= smallest * 2 else { continue }
            let size = min(max(edge.size(cut.rects[cut.at]), smallest), both - smallest)
            guard abs(size - sizes[cut.at]) > 0.5 else { continue }
            sizes[cut.at] = size
            sizes[j] = both - size
            mine[cut.path] = sizes
            changed = true
        }
        if changed { shares[key] = mine }
        return changed
    }

    /// Glass windows joined as one (Flush, side by side): one glass under them all (GlassBackdrop)
    private var sharedGlass: Bool { on && flush && !arrangement.stacks && order.count > 1 }

    func retile() {
        guard on, AXIsProcessTrusted() else { return }
        remember()
        slots = places()
        if sharedGlass, let first = slots.first {
            GlassBackdrop.shared.show(slots.dropFirst().reduce(first) { $0.union($1) }, duration: 0.32)
        } else {
            GlassBackdrop.shared.hide()
        }
        // each app told which of its corners to round (all, but while Flush); stacked, each window is alone
        WindowJoins.tell(zip(order, slots).map { ($0.element, $1) }, separate: !flush || arrangement.stacks,
                         pinned: pinned.keys.map(\.element), shared: sharedGlass)
        var moves = zip(order, slots).compactMap { window, to in
            frame(of: window.element).map { Move(window: window, from: $0, to: to) }
        }
        // the other screens' windows, each in its screen's middle
        refreshOthers()
        let elsewhere = otherPlaces()
        moves += elsewhere.compactMap { window, to in frame(of: window.element).map { Move(window: window, from: $0, to: to) } }
        // each other screen as the main one: in Flush one glass under its windows, which drop their own
        for k in Set(otherGlass.keys).union(others.keys) {
            let list = others[k] ?? []
            let placed = elsewhere.filter { list.contains($0.0) }
            let joined = on && flush && !arrangement.stacks && placed.count > 1
            if joined, let first = placed.first?.1 {
                (otherGlass[k] ?? { let g = GlassBackdrop(); otherGlass[k] = g; return g }())
                    .show(placed.dropFirst().reduce(first) { $0.union($1.1) }, duration: 0.32)
            } else {
                otherGlass[k]?.hide()
            }
            if !placed.isEmpty {
                WindowJoins.tell(placed.map { ($0.0.element, $0.1) }, separate: !flush || arrangement.stacks,
                                 pinned: pinned.keys.map(\.element), shared: joined)
            }
        }
        animate(moves)
    }

    /// Glides the windows to their places: quick at first, settling softly (ease-out).
    private func animate(_ moves: [Move]) {
        animation?.invalidate()
        animation = nil
        let finish = {
            for move in moves {
                setFrame(of: move.window.element, to: move.to, exact: true)
                self.settled[move.window] = frame(of: move.window.element) ?? move.to
            }
            // again where they now are: an app takes the word only for the place its window is in. Each screen told
            // on its own, all its windows (who touches whom), with its own glass: the main screen's shared glass is
            // not the other screens' (with fewer than two windows on the main one, theirs was taken for none)
            let separate = !self.flush || self.arrangement.stacks
            let pins = self.pinned.keys.map(\.element)
            guard self.on else {
                return WindowJoins.tell(moves.map { ($0.window.element, $0.to) }, separate: separate, pinned: pins, shared: false)
            }
            if self.slots.count == self.order.count, !self.order.isEmpty {
                WindowJoins.tell(zip(self.order, self.slots).map { ($0.element, $1) }, separate: separate, pinned: pins, shared: self.sharedGlass)
            }
            let elsewhere = self.otherPlaces()
            for list in self.others.values {
                let placed = elsewhere.filter { list.contains($0.0) }
                guard !placed.isEmpty else { continue }
                let joined = self.flush && !self.arrangement.stacks && placed.count > 1
                WindowJoins.tell(placed.map { ($0.0.element, $0.1) }, separate: separate, pinned: pins, shared: joined)
            }
        }
        let still = moves.allSatisfy { $0.from.integral == $0.to }
        guard !still, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return finish() }
        let duration = 0.32
        let begin = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            let t = min((CACurrentMediaTime() - begin) / duration, 1)
            guard t < 1 else {
                timer.invalidate()
                self?.animation = nil
                return finish()
            }
            let e = CGFloat(1 - pow(1 - t, 4))
            for move in moves {
                let f = move.from, to = move.to
                let r = NSRect(x: f.minX + (to.minX - f.minX) * e, y: f.minY + (to.minY - f.minY) * e,
                               width: f.width + (to.width - f.width) * e, height: f.height + (to.height - f.height) * e)
                setFrame(of: move.window.element, to: r, size: f.size != to.size)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    enum Direction { case left, right, up, down }

    /// a window whose middle is on another screen than the main one
    static func onOtherScreen(_ window: AXUIElement) -> Bool {
        guard NSScreen.screens.count > 1, let f = frame(of: window) else { return false }
        let middle = NSPoint(x: f.midX, y: f.midY)
        return NSScreen.screens.dropFirst().contains { $0.frame.contains(middle) }
    }

    /// ⌃⌥O: the window with the keyboard to the next screen, in its middle, as large as fits there; tiled
    /// there with that screen's windows. The windows left close up.
    func toOtherScreen() {
        guard AXIsProcessTrusted() else { return Tiler.openAccessibilitySettings() }
        let screens = NSScreen.screens
        guard screens.count > 1,
              let app = attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              let pid = Optional(app as! AXUIElement).flatMap({ el -> pid_t? in var p: pid_t = 0; return AXUIElementGetPid(el, &p) == .success ? p : nil }),
              tiledApps.contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""),
              let focused = attribute(app as! AXUIElement, kAXFocusedWindowAttribute),
              let now = frame(of: focused as! AXUIElement) else { return }
        let window = focused as! AXUIElement
        let middle = NSPoint(x: now.midX, y: now.midY)
        let here = screens.firstIndex { $0.frame.contains(middle) } ?? 0
        let there = screens[(here + 1) % screens.count].visibleFrame
        let w = min(now.width, there.width * 0.9), h = min(now.height, there.height * 0.9)
        pinned[TiledWindow(element: window)] = nil
        setFrame(of: window, to: NSRect(x: there.midX - w / 2, y: there.midY - h / 2, width: w, height: h), exact: true)
        if on { lookNow(); retile() }
    }

    /// the window that has the keyboard, if it is one of the Re apps', on whichever screen
    private func focusedReWindow() -> TiledWindow? {
        guard let app = attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app as! AXUIElement, &pid) == .success,
              tiledApps.contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""),
              let focused = attribute(app as! AXUIElement, kAXFocusedWindowAttribute) else { return nil }
        return TiledWindow(element: focused as! AXUIElement)
    }

    /// The window that has the keyboard, if it is one of the Re apps'.
    private func focusedWindow() -> TiledWindow? {
        guard let app = attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              let focused = attribute(app as! AXUIElement, kAXFocusedWindowAttribute) else { return nil }
        let window = TiledWindow(element: focused as! AXUIElement)
        return openWindows().contains(window) ? window : nil
    }

    /// ⌘ arrows: the focus goes to the nearest window that way. In One at a Time (all in one place)
    /// ← / ↑ and → / ↓ go back and forth through them.
    func focus(_ direction: Direction) {
        guard AXIsProcessTrusted() else { return Tiler.openAccessibilitySettings() }
        // the windows on every screen: the nearest may be on another one
        refreshOthers()
        let windows = (on && !order.isEmpty ? order : openWindows()) + others.keys.sorted().flatMap { others[$0] ?? [] }
        guard let current = focusedWindow() ?? focusedReWindow().flatMap({ windows.contains($0) ? $0 : nil }) ?? windows.first,
              windows.count > 1,
              let target = neighbour(of: current, among: windows, toward: direction) else { return }
        raise(target)
    }

    /// ⌘⌥ arrows: the focused window trades places with the nearest one that way, and keeps the focus.
    /// In One at a Time it moves back or forth in the turn.
    func move(_ direction: Direction) {
        guard on, AXIsProcessTrusted() else { return }
        // a window on another screen: it trades with its nearest neighbour there
        if focusedWindow() == nil, let current = focusedReWindow() {
            refreshOthers()
            guard let (k, list) = others.first(where: { $0.value.contains(current) }), let at = list.firstIndex(of: current),
                  let target = neighbour(of: current, among: list, toward: direction), let to = list.firstIndex(of: target),
                  pinned[current] == nil, pinned[target] == nil else { return }
            var swapped = list
            swapped.swapAt(at, to)
            others[k] = swapped
            return retile()
        }
        guard let current = focusedWindow(),
              let at = order.firstIndex(of: current),
              let target = neighbour(of: current, among: order, toward: direction),
              let to = order.firstIndex(of: target), pinned[current] == nil, pinned[target] == nil else { return }
        order.swapAt(at, to)
        retile()
    }

    /// Where a window belongs while tiling (it may still be gliding there), otherwise where it is.
    private func place(of window: TiledWindow) -> NSRect? {
        if on, slots.count == order.count, let at = order.firstIndex(of: window) { return slots[at] }
        if on, let there = otherPlaces().first(where: { $0.0 == window }) { return there.1 }
        return frame(of: window.element)
    }

    private func neighbour(of current: TiledWindow, among windows: [TiledWindow], toward direction: Direction) -> TiledWindow? {
        let target: TiledWindow?
        if on && arrangement.stacks, let at = windows.firstIndex(of: current) {
            let step = direction == .right || direction == .down ? 1 : -1
            target = windows[(at + step + windows.count) % windows.count]
        } else if let from = place(of: current) {
            // the closest window whose middle lies that way; straight ahead counts more than off to the side
            let candidates = windows.filter { $0 != current }.compactMap { w in place(of: w).map { (w, $0) } }
            target = candidates.compactMap { w, f -> (TiledWindow, CGFloat)? in
                let dx = f.midX - from.midX, dy = f.midY - from.midY
                let (ahead, aside): (CGFloat, CGFloat) = switch direction {
                case .left: (-dx, dy)
                case .right: (dx, dy)
                case .up: (dy, dx)
                case .down: (-dy, dx)
                }
                return ahead > 1 ? (w, ahead + abs(aside) * 2) : nil
            }.min { $0.1 < $1.1 }?.0
        } else {
            target = nil
        }
        return target
    }

    /// the window that had the focus when ⌃⌥F gave it to the desk: ⌃⌥F again gives it back
    private var focusedBefore: TiledWindow?

    /// ⌃⌥F: a window has the focus (its diamond, its + strong): the desk takes it, no window chosen; the desk
    /// has it: the window that had it before has it again (gone: the first of them)
    func toggleFocus() {
        guard AXIsProcessTrusted() else { return Tiler.openAccessibilitySettings() }
        refreshOthers()
        let windows = (on && !order.isEmpty ? order : openWindows()) + others.keys.sorted().flatMap { others[$0] ?? [] }
        let deskHasIt = NSWorkspace.shared.frontmostApplication == NSRunningApplication.current
        if !deskHasIt, let current = focusedWindow() ?? focusedReWindow() {
            focusedBefore = current
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if let back = focusedBefore.flatMap({ windows.contains($0) ? $0 : nil }) ?? windows.first { raise(back) }
    }

    private func raise(_ window: TiledWindow) {
        var pid: pid_t = 0
        AXUIElementGetPid(window.element, &pid)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// ⌘↑ / ⌘↓: the focused window fills the screen (all but the menu bar and the Dock), or the desk's middle.
    /// Tiling stops, or it would put the window straight back.
    func resizeFocused(wholeScreen: Bool) {
        guard let window = focusedWindow(), let screen = NSScreen.screens.first else { return }
        if on { on = false }
        let to = wholeScreen ? screen.visibleFrame : Layout(area: screen.frame).tiles.integral
        guard let from = frame(of: window.element) else { return }
        animate([Move(window: window, from: from, to: to)])
    }

    /// ⌘1…⌘6 (in the Re apps): this arrangement, with tiling on.
    /// Choosing the arrangement already in use evens out what resizing changed.
    func choose(_ arrangement: Arrangement) {
        if on && arrangement == self.arrangement { shares[sharesKey] = nil }
        self.arrangement = arrangement
        on = true
    }

    /// The focused window becomes the main one.
    func promote() {
        guard on, let app = attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              let focused = attribute(app as! AXUIElement, kAXFocusedWindowAttribute) else { return }
        let window = TiledWindow(element: focused as! AXUIElement)
        guard let at = order.firstIndex(of: window), at > 0, pinned[window] == nil else { return }
        order.remove(at: at)
        order.insert(window, at: 0)
        order = anchored(order)
        retile()
    }
}

// ── the Mac's appearance and cursors ──

/// ⌘⇧T: the Mac between light and dark. System Events does it, so macOS asks once whether ReDesk may.
/// (The Re apps' windows are glass whatever the Mac is: the system's blur of what is behind them, written in
/// the desk's white ink.)

enum Appearance {
    static func toggle() {
        let script = NSAppleScript(source: """
            tell application "System Events" to tell appearance preferences to set dark mode to not dark mode
            """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error { NSLog("ReDesk: the appearance didn't change: \(error)") }
    }

    /// As the app sees it: this turns the moment the Mac does, together with every other app
    /// (the AppleInterfaceStyle default is written a moment later).
    static var dark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// CoreGraphics' cursor registry: private, the way cursor apps such as Mousecape set the whole Mac's cursors
// (declarations as in Mousecape's CGSCursor.h).
private typealias CGSConnectionID = Int32
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSRegisterCursorWithImages")
private func CGSRegisterCursorWithImages(
    _ cid: CGSConnectionID, _ name: UnsafePointer<CChar>, _ setGlobally: Bool, _ instantly: Bool,
    _ size: CGSize, _ hotspot: CGPoint, _ frameCount: Int, _ frameDuration: CGFloat, _ images: CFArray,
    _ seed: UnsafeMutablePointer<Int32>) -> CGError
@_silgen_name("CoreCursorUnregisterAll")
private func CoreCursorUnregisterAll(_ cid: CGSConnectionID) -> CGError

/// The Re apps' ink cursors for every app on the Mac: the arrow and the pointing hand drawn
/// with a brush (light ink while the Mac is dark; the arrow always light, with a dark rim). They stay until ReDesk quits or they are turned off
/// (right click › Ink Cursors); then the Mac's own come back.
enum InkCursors {
    private struct Shape {
        let names: [String]
        let day: String
        let night: String
        /// the point that clicks, in a 20 × 20 cursor
        let hotspot: CGPoint
        /// a dark rim round it, so light ink reads on a light screen too
        var rimmed = false
    }

    // since macOS 26 the arrow and the I-beam are drawn from the …S names; the old ones are still
    // accepted, without effect (Mousecape PR #308)
    private static let shapes = [
        // the arrow: a diamond drawn out to its point (kite), white with a dark rim (InkCursors.kite)
        Shape(names: ["com.apple.coregraphics.ArrowS", "com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowCtx"],
              day: "kite", night: "kite", hotspot: CGPoint(x: 1.7, y: 1.4), rimmed: true),
        // (over text the Mac's own I-beam stays)
        // the hand (over what opens): the arrow's diamond, upright, pointing at it
        Shape(names: ["com.apple.cursor.13"], day: "hand", night: "hand", hotspot: CGPoint(x: 10, y: 1.4), rimmed: true),
    ]
    private static let size = CGSize(width: 20, height: 20)

    static var on: Bool {
        get { UserDefaults.standard.object(forKey: "inkCursors") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "inkCursors")
            apply()
        }
    }

    /// Sets the cursors for the current appearance, or gives the Mac its own back.
    static func apply() {
        let cid = CGSMainConnectionID()
        guard on else {
            _ = CoreCursorUnregisterAll(cid)
            return
        }
        // from the Mac's own first: a shape no longer drawn here is the Mac's again
        _ = CoreCursorUnregisterAll(cid)
        let night = Appearance.dark
        for shape in shapes {
            guard let images = images(night ? shape.night : shape.day, rimmed: shape.rimmed) else { continue }
            for name in shape.names {
                var seed: Int32 = 0
                let error = name.withCString {
                    CGSRegisterCursorWithImages(cid, $0, true, true, size, shape.hotspot, 1, 0, images as CFArray, &seed)
                }
                if error != .success { NSLog("ReDesk: cursor \(name) not set: \(error.rawValue)") }
            }
        }
    }

    static func restore() {
        _ = CoreCursorUnregisterAll(CGSMainConnectionID())
    }

    /// The cursors drawn here, white, in a 200 × 200 picture (from its top left): the arrow a diamond drawn
    /// out to its point (kite), the hand the same upright.
    private static func picture(_ name: String) -> CGImage? {
        guard let c = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: 200 - y) }
        /// a diamond drawn out to its point at `tip`, leaning `degrees` from across: its sides `side` out,
        /// `widest` along from the point, its back `length` from it
        func kite(tip: CGPoint, degrees: CGFloat, side: CGFloat, widest: CGFloat, length: CGFloat) {
            let angle = degrees * .pi / 180
            let along = CGPoint(x: cos(angle), y: sin(angle)), across = CGPoint(x: -sin(angle), y: cos(angle))
            func at(_ u: CGFloat, _ v: CGFloat) -> CGPoint { p(tip.x + u * along.x + v * across.x, tip.y + u * along.y + v * across.y) }
            c.move(to: at(0, 0)); c.addLine(to: at(widest, side)); c.addLine(to: at(length, 0)); c.addLine(to: at(widest, -side))
            c.closePath()
        }
        c.setFillColor(.white)
        switch name {
        case "kite":
            // leaning as the Mac's arrow does
            kite(tip: CGPoint(x: 10, y: 6), degrees: 62, side: 54, widest: 136, length: 190)
        case "hand":
            kite(tip: CGPoint(x: 100, y: 6), degrees: 90, side: 50, widest: 128, length: 184)
        default:
            return nil
        }
        c.fillPath()
        return c.makeImage()
    }

    /// The picture at each scale the screen may want (1×, 2×, 3×, 4×).
    private static func images(_ name: String, rimmed: Bool = false) -> [CGImage]? {
        let drawn = ["kite", "hand"].contains(name)
        guard let image = drawn ? picture(name) : Bundle.main.url(forResource: name, withExtension: "png")
            .flatMap({ CGImageSourceCreateWithURL($0 as CFURL, nil) })
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { return nil }
        return (1...4).compactMap { scale in
            let side = Int(size.width) * scale
            guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            guard rimmed else {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return ctx.makeImage()
            }
            // the ink a little smaller, room left round it for the rim; pure white, its tip made sharp (the
            // brush's own tip is too thin to see at this size); its dark shape drawn all round it
            let rim = CGFloat(side) * 0.05
            let whole = CGRect(x: 0, y: 0, width: side, height: side)
            let place = whole.insetBy(dx: rim, dy: rim)
            func layer(_ color: CGColor, from source: CGImage?) -> CGImage? {
                guard let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                c.interpolationQuality = .high
                if let source {
                    c.draw(source, in: whole)
                } else if drawn {
                    c.draw(image, in: place)
                } else {
                    c.draw(image, in: place)
                    // the tip: a wedge along the head's two edges (in the 200 × 200 picture, from its top left)
                    let k = place.width / 200
                    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: place.minX + x * k, y: place.maxY - y * k) }
                    c.move(to: at(1, 1)); c.addLine(to: at(36, 18)); c.addLine(to: at(16, 36)); c.closePath()
                    c.setFillColor(.white)
                    c.fillPath()
                }
                c.setBlendMode(.sourceIn)
                c.setFillColor(color)
                c.fill(whole)
                return c.makeImage()
            }
            guard let ink = layer(.white, from: nil),
                  let dark = layer(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 0.9), from: ink) else { return nil }
            for step in 0..<16 {
                let angle = CGFloat(step) / 16 * 2 * .pi
                ctx.draw(dark, in: whole.offsetBy(dx: cos(angle) * rim, dy: sin(angle) * rim))
            }
            ctx.draw(ink, in: whole)
            return ctx.makeImage()
        }
    }
}

// ── battery ──

/// 0…1, or nil on a Mac without one.
func batteryLevel() -> Double? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
        guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let now = d[kIOPSCurrentCapacityKey] as? Double,
              let max = d[kIOPSMaxCapacityKey] as? Double, max > 0 else { continue }
        return min(now / max, 1)
    }
    return nil
}

// ── the pieces ──

class DeskView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// items of this piece that go above the common ones
    func menuItems() -> [NSMenuItem] { [] }

    /// a right click anywhere on the desk: the settings
    override func rightMouseDown(with event: NSEvent) {
        SettingsPopup.shared.show()
    }
}

final class WordView: DeskView {
    let corner: Corner
    private var hovered = false { didSet { needsDisplay = true } }

    init(corner: Corner) {
        self.corner = corner
        super.init(frame: .zero)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func frontChanged() { needsDisplay = true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { open(corner) }

    override func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Open \(corner.app)", action: #selector(openApp), keyEquivalent: "")
        item.target = self
        return [item]
    }

    @objc private func openApp() { open(corner) }

    /// The app in front (or the word under the mouse) in full ink, the others at half.
    override func draw(_ dirtyRect: NSRect) {
        let inFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == corner.bundle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: letterFont,
            .foregroundColor: ink(hovered || inFront ? 0.95 : 0.5),
        ]
        for (i, letter) in corner.word.enumerated() {
            let text = NSAttributedString(string: String(letter), attributes: attributes)
            let size = text.size()
            let y = bounds.maxY - CGFloat(i + 1) * letterStep + (letterStep - size.height) / 2
            let at = NSPoint(x: (bounds.width - size.width) / 2, y: y)
            if letter == "ー", let context = NSGraphicsContext.current?.cgContext {
                // the long vowel mark, written down, stands as the word does (as the apps' vertical-rl)
                context.saveGState()
                context.translateBy(x: at.x + size.width / 2, y: at.y + size.height / 2)
                context.rotate(by: -.pi / 2)
                text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2))
                context.restoreGState()
            } else {
                text.draw(at: at)
            }
        }
    }
}

/// Full Screen's way between the apps: FILE  SURF  PLAY  NOTE across the top of the screen, in the apps'
/// small letters (as their corner buttons in a small window); the app in front in full ink,
/// a click goes to one (or opens it). In the Mac's menu bar while it stays; where it hides (it comes
/// only when the mouse goes up), on the desk in its place (AppStripView), the menu bar coming over it.
var menuBarHides: Bool { UserDefaults.standard.bool(forKey: "_HIHideMenuBar") }

/// On another screen than the main one, the room the apps across the top take where it has no menu bar of
/// its own (an external display, the menu bar hidden or only on the main screen): the menu bar's height.
func appStripRoom(_ screen: NSScreen) -> CGFloat {
    guard screen != NSScreen.screens.first, Tiler.shared.showsApps else { return 0 }
    return screen.frame.maxY - screen.visibleFrame.maxY < 1 ? NSStatusBar.system.thickness : 0
}

private let appWordFont = NSFont(name: "NotoSansJP-Regular", size: 15) ?? .systemFont(ofSize: 15, weight: .light)

func appWord(_ corner: Corner, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: corner.word, attributes: [.font: appWordFont, .kern: 0.4 * appWordFont.pointSize, .foregroundColor: color])
}

/// The words on the desk where the hidden menu bar would be, spread across the screen: the same space
/// between each two and at the ends, then each further from the middle: the outer two by 15%, the
/// inner two (SURF, PLAY) by 80%, which keeps the camera's notch well between them.
final class AppStripView: DeskView {
    private var hovered: Int? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func frontChanged() { needsDisplay = true }

    /// the space between two words, and between the screen's edges and the words at the ends
    private var gap: CGFloat {
        let words = corners.reduce(0) { $0 + appWord($1, color: .black).size().width }
        return (bounds.width - words) / CGFloat(corners.count + 1)
    }

    /// where each word is drawn
    private func places() -> [NSRect] {
        let gap = gap
        var x = bounds.minX + gap
        return corners.enumerated().map { i, corner in
            let size = appWord(corner, color: .black).size()
            defer { x += size.width + gap }
            let inner = i > 0 && i < corners.count - 1
            let middle = bounds.midX + (x + size.width / 2 - bounds.midX) * (inner ? 1.8 : 1.15)
            return NSRect(x: middle - size.width / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    private func word(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return places().firstIndex { $0.insetBy(dx: -24, dy: -8).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) { hovered = word(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {
        if let i = word(at: event) { open(corners[i]) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for (i, place) in places().enumerated() {
            let inFront = corners[i].bundle == front
            appWord(corners[i], color: ink(inFront || hovered == i ? 0.95 : 0.45)).draw(at: place.origin)
        }
    }
}

/// The words in the menu bar, while it stays.
final class AppMenuBar: NSObject {
    static let shared = AppMenuBar()
    private var items: [(corner: Corner, item: NSStatusItem)] = []

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(redraw), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    var shown: Bool {
        get { !items.isEmpty }
        set {
            guard newValue != shown else { return }
            if newValue {
                // a new item goes to the left of the ones there: NOTE first, so FILE ends up leftmost
                items = corners.reversed().map { corner in
                    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                    item.button?.target = self
                    item.button?.action = #selector(clicked(_:))
                    return (corner, item)
                }.reversed()
                redraw()
            } else {
                items.forEach { NSStatusBar.system.removeStatusItem($0.item) }
                items = []
            }
        }
    }

    @objc func redraw() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for (corner, item) in items {
            let inFront = corner.bundle == front
            // the menu bar's own ink, light or dark as it is
            item.button?.attributedTitle = appWord(corner, color: NSColor.labelColor.withAlphaComponent(inFront ? 1 : 0.5))
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let corner = items.first(where: { $0.item.button === sender })?.corner else { return }
        open(corner)
    }
}

/// The wallpapers as dots down the left edge; the one on the desktop is a diamond.
/// The wallpapers as the desktops are shown: a dash each, one above another down the right edge, the one on
/// the desk longer and stronger; a click on one sets it.
final class WallpaperView: DeskView {
    static let spacing: CGFloat = DesktopsView.spacing

    private var chosen = Wallpapers.current

    /// `mirror`: the same dashes on another screen, only showing (and choosing) what the main one keeps in step
    init(mirror: Bool = false) {
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .wallpaperChanged, object: nil)
        // the wallpaper can also change in System Settings
        if !mirror {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(changedElsewhere), name: Notification.Name("com.apple.desktop"), object: nil)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// The wallpaper changed outside ReDesk (System Settings, another Space): start or stop the video to match.
    @objc func changedElsewhere() {
        Wallpapers.sync()
        refresh()
    }

    @objc func refresh() {
        chosen = Wallpapers.current
        needsDisplay = true
    }

    /// the dashes around the middle of the view, the first wallpaper highest
    private func centre(_ i: Int) -> CGFloat {
        bounds.midY + (CGFloat(Wallpapers.all.count - 1) / 2 - CGFloat(i)) * Self.spacing
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        let nearest = Wallpapers.all.indices.min { abs(centre($0) - y) < abs(centre($1) - y) }
        if let nearest, abs(centre(nearest) - y) <= Self.spacing / 2 { Wallpapers.show(nearest) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in Wallpapers.all.indices {
            let now = i == chosen
            let width: CGFloat = now ? 20 : 10
            (now ? strong : faint).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - width / 2, y: centre(i) - 1, width: width, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}

let diamondSize: CGFloat = 13

/// The mark for "this one" or "now", in the strong ink (as the day's noon line).
func drawDiamond(at c: NSPoint, color: NSColor = strong) {
    let r = diamondSize / 2
    let path = NSBezierPath()
    path.move(to: NSPoint(x: c.x, y: c.y + r))
    path.line(to: NSPoint(x: c.x + r, y: c.y))
    path.line(to: NSPoint(x: c.x, y: c.y - r))
    path.line(to: NSPoint(x: c.x - r, y: c.y))
    path.close()
    color.setFill()
    path.fill()
}

/// A thin rounded bar: `filled` of it in the strong ink, from the left (or the bottom), the rest faint.
func drawBar(in rect: NSRect, filled: Double, vertical: Bool) {
    let radius = barWidth / 2
    faint.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    let part = CGFloat(max(0, min(filled, 1)))
    var done = rect
    if vertical { done.size.height *= part } else { done.size.width *= part }
    guard done.width > 0, done.height > 0 else { return }
    strong.setFill()
    NSBezierPath(roundedRect: done, xRadius: radius, yRadius: radius).fill()
}

/// Today, midnight to midnight, as a faint line with a mark at noon; a diamond stands at now.
final class DayView: DeskView {
    override func draw(_ dirtyRect: NSRect) {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let gone = now.timeIntervalSince(start) / end.timeIntervalSince(start)
        drawBar(in: NSRect(x: 0, y: bounds.midY - barWidth / 2, width: bounds.width, height: barWidth), filled: 0, vertical: false)
        strong.setFill()
        NSRect(x: bounds.midX - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        // kept inside the window so it is never cut at midnight's ends
        let r = diamondSize / 2
        drawDiamond(at: NSPoint(x: r + (bounds.width - diamondSize) * CGFloat(gone), y: bounds.midY))
    }

    override func menuItems() -> [NSMenuItem] {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        return [NSMenuItem(title: time, action: nil, keyEquivalent: "")]
    }
}

// ── desktops: ReDesk's own, one above another ──

/// The window number (CGWindowID) behind an Accessibility window: it stays the same while the window is out
/// of sight, where the Accessibility element does not.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// ReDesk's own desktops, one above another (⌥↑ / ⌥↓; ⌘⌃↑ / ⌘⌃↓ take the window in front along). Each window
/// of the Re apps is on one of them, on its own (two windows of one app can be on two desktops); the windows
/// of the others are out of sight (their app puts them away when asked: "hide-window <pid> <number>", and
/// back, "show-window …"), and tiling lays out only this one's. As many as are used, and an empty one under
/// them to take a window to (emptied ones go). Going down the windows rise and fade away while the next
/// desktop's rise into their places; going up, the other way.
final class Desktops {
    static let shared = Desktops()
    /// how far the windows slide, going and coming
    static let slide: CGFloat = 90

    /// each window's desktop, by its number; a window not seen before is on the desktop in sight
    private var place: [CGWindowID: Int] = [:]
    /// the windows out of sight on another desktop: their app, where they were, and when they were put away
    private var away: [CGWindowID: (pid: pid_t, frame: NSRect, at: Date)] = [:]
    private(set) var current = 0
    /// switching now: an app shown by it is no reason to switch again
    private var switching = false

    private var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { tiledApps.contains($0.bundleIdentifier ?? "") }
    }

    /// The windows on the screen now, by number. Accessibility lists a window its app has put away too:
    /// only this tells what is really in sight.
    static func onScreen() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    static func number(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    /// the Re apps' windows in sight now
    private func shown() -> [(app: NSRunningApplication, element: AXUIElement, id: CGWindowID, frame: NSRect)] {
        let visible = Self.onScreen()
        return running.filter { !$0.isHidden }.flatMap { app in
            Self.windows(of: app).compactMap { element, frame in
                Self.number(of: element).flatMap { visible.contains($0) ? (app, element, $0, frame) : nil }
            }
        }
    }

    /// The windows looked at: new ones are on this desktop; closed ones, and those of apps that quit, forgotten.
    private func learn() {
        let here = shown()
        let alive = Set(running.map(\.processIdentifier))
        away = away.filter { alive.contains($0.value.pid) }
        let seen = Set(here.map(\.id))
        // a window out of sight only because another macOS space is in front is still on its desktop: the
        // window server lists it (all spaces'); a closed one it doesn't
        let exist = Set((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        place = place.filter { seen.contains($0.key) || away[$0.key] != nil || exist.contains($0.key) }
        for window in here {
            if place[window.id] == nil {
                place[window.id] = current
            } else if let was = away[window.id], Date().timeIntervalSince(was.at) > 1.2 {
                // put away (and done fading out a while ago), but its app brought it back by itself: here now
                away[window.id] = nil
                place[window.id] = current
            }
        }
    }

    /// whether a window is put away on another desktop
    func holds(_ id: CGWindowID) -> Bool { away[id] != nil }

    /// The desktop an app is on: this one while any of its windows is in sight, else the first of those it has away.
    func desktop(of app: NSRunningApplication) -> Int {
        if shown().contains(where: { $0.app == app }) { return current }
        return away.filter { $0.value.pid == app.processIdentifier }.compactMap { place[$0.key] }.min() ?? current
    }

    /// the desktops in use, the one in sight among them, and the empty one under them
    var count: Int {
        learn()
        let used = place.values.max() ?? -1
        return max(used + 2, current + 1)
    }

    func start() {
        // the apps an older ReDesk hid for its desktops (a whole app on each) back in sight, all on this one
        if let old = UserDefaults.standard.dictionary(forKey: "desktopOf") as? [String: Int] {
            let was = UserDefaults.standard.integer(forKey: "desktop")
            for app in running where app.isHidden && old[app.bundleIdentifier ?? ""].map({ $0 != was }) == true { app.unhide() }
            UserDefaults.standard.removeObject(forKey: "desktopOf")
        }
        UserDefaults.standard.set(0, forKey: "desktop")
        // the desktops start anew: windows put away before (by a ReDesk that quit) back in sight
        let visible = Self.onScreen()
        for app in running where !app.isHidden {
            for (element, _) in Self.windows(of: app) {
                if let id = Self.number(of: element), !visible.contains(id) { Self.tell("show-window", app.processIdentifier, id) }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.changed()
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            Tiler.log("macOS space changed")
            // the desktops' dashes drawn again once the space's windows are in sight
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: .desktopsChanged, object: nil)
            }
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.changed()
        }
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            // an app whose windows are all on another desktop brought forward (⌘Tab, the Dock, its corner word): there
            guard let self, !self.switching, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  tiledApps.contains(app.bundleIdentifier ?? "") else { return }
            // a moment for a window it opens on its own to be there
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard !self.switching else { return }
                self.learn()
                let there = self.desktop(of: app)
                if there != self.current { self.go(to: there) }
            }
        }
    }

    /// ⌥↑ / ⌥↓: the desktop above or below
    func step(_ by: Int) {
        let to = current + by
        guard to >= 0, to < count else { return }
        go(to: to)
    }

    /// ⌘⌃↑ / ⌘⌃↓: the window in front (only it, not its app's others) to the desktop above or below, and there with it
    func take(_ by: Int) {
        guard let app = NSWorkspace.shared.frontmostApplication, tiledApps.contains(app.bundleIdentifier ?? ""),
              let focused = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              let id = Self.number(of: focused as! AXUIElement) else { return }
        let to = current + by
        guard to >= 0, to < count else { return }
        place[id] = to
        go(to: to, keeping: id)
    }

    private static func tell(_ what: String, _ pid: pid_t, _ id: CGWindowID) {
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.artursavytskyi.re.windows"), object: "\(what) \(pid) \(id)", userInfo: nil, deliverImmediately: true)
    }

    func go(to desktop: Int, keeping kept: CGWindowID? = nil) {
        guard desktop != current else { return }
        learn()
        let down = desktop > current
        let going = shown().filter { $0.id != kept }
        let coming = away.filter { place[$0.key] == desktop && $0.key != kept }
        switching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.switching = false }
        // the window taken along stays in sight: on the new desktop now
        if let kept { place[kept] = desktop }
        current = desktop
        // going down, everything rises: the windows going up and away, the coming ones up from under
        let rise = down ? Self.slide : -Self.slide
        let leaving = Set(going.map(\.id))
        Tiler.log("go → \(desktop): going \(going.map(\.id)) coming \(Array(coming.keys))")
        Tiler.shared.leaving.subtract(coming.keys)
        Tiler.shared.leaving.formUnion(leaving)
        // put away by then (their app fades them out): off the screen, so no longer looked at anyway
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Tiler.shared.leaving.subtract(leaving.filter { self.place[$0] != self.current })
        }
        Self.slide(going.map { ($0.element, $0.frame) }, by: rise)
        for window in going {
            away[window.id] = (window.app.processIdentifier, window.frame, Date())
            Self.tell("hide-window", window.app.processIdentifier, window.id)
        }
        for (id, was) in coming {
            away[id] = nil
            Self.tell("show-window", was.pid, id)
        }
        // a moment for them to be there again: from under their places (they fade in: their app does), into them
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let back = self.shown().filter { coming[$0.id] != nil }
            for window in back { setFrame(of: window.element, to: coming[window.id]!.frame.offsetBy(dx: 0, dy: -rise), exact: true) }
            if !Tiler.shared.on { Self.slide(back.map { ($0.element, coming[$0.id]!.frame.offsetBy(dx: 0, dy: -rise)) }, by: rise) }
        }
        normalize()
        // tiling: this desktop's windows to their places (the coming ones glide up into theirs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { Tiler.shared.lookNow() }
        // in front: the window taken along, else the biggest here (the same size: the leftmost); on an empty
        // desktop the desk itself (so F, S, D, N open the apps)
        let here = current  // after normalize(): the desktops may be counted anew
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.focus(on: here, kept: kept, coming: Set(coming.keys), last: [:], tries: 25)
        }
        NotificationCenter.default.post(name: .desktopsChanged, object: nil)
    }

    /// The window to have the focus on the desktop just come to, once its windows are there (their apps show
    /// them a moment later) and stand still in their places (tiling glides them): the one taken along, else
    /// the biggest; of the same size (within 2%), the leftmost, then the highest. None: the desk itself.
    private func focus(on desktop: Int, kept: CGWindowID?, coming: Set<CGWindowID>, last: [CGWindowID: NSRect], tries: Int) {
        guard current == desktop else { return }  // gone on to another meanwhile
        let here = shown()
        let frames = Dictionary(here.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let arrived = coming.isSubset(of: Set(frames.keys))
        if tries > 0 && (!arrived || frames != last) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                self.focus(on: desktop, kept: kept, coming: coming, last: frames, tries: tries - 1)
            }
            return
        }
        let pick = here.first { $0.id == kept } ?? here.sorted { a, b in
            let sa = a.frame.width * a.frame.height, sb = b.frame.width * b.frame.height
            if abs(sa - sb) > 0.02 * max(sa, sb) { return sa > sb }
            if abs(a.frame.minX - b.frame.minX) > 2 { return a.frame.minX < b.frame.minX }
            return a.frame.maxY > b.frame.maxY
        }.first
        Tiler.log("focus on \(desktop): \(pick.map { String($0.id) } ?? "the desk")")
        guard let pick else { return NSApp.activate(ignoringOtherApps: true) }
        AXUIElementPerformAction(pick.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(pick.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        pick.app.activate()
    }

    /// emptied desktops gone (but the one in sight), the rest counted from 0
    private func normalize() {
        let used = Set(place.values).union([current]).sorted()
        let index = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
        place = place.mapValues { index[$0] ?? 0 }
        current = index[current] ?? 0
        UserDefaults.standard.set(current, forKey: "desktop")
    }

    private func changed() {
        learn()
        normalize()
        NotificationCenter.default.post(name: .desktopsChanged, object: nil)
    }

    /// an app's standard windows and where they are
    static func windows(of app: NSRunningApplication) -> [(AXUIElement, NSRect)] {
        let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.compactMap { w in
            guard attribute(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                  attribute(w, kAXMinimizedAttribute) as? Bool != true, let f = frame(of: w) else { return nil }
            return (w, f)
        }
    }

    /// windows glided up (or down) by `by` from where they are, easing out
    static func slide(_ windows: [(AXUIElement, NSRect)], by: CGFloat, over duration: Double = 0.4) {
        guard !windows.isEmpty else { return }
        let begin = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let t = min((CACurrentMediaTime() - begin) / duration, 1)
            let e = CGFloat(1 - pow(1 - t, 3))
            for (window, from) in windows { setFrame(of: window, to: from.offsetBy(dx: 0, dy: by * e), size: false) }
            if t >= 1 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// The desktops on the left edge, around its middle: a dash each, top to bottom, the one in sight longer and
/// stronger. A click goes to one.
final class DesktopsView: DeskView {
    static let spacing: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(forName: .desktopsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { nil }

    /// the dashes around the middle of the view, the first desktop highest
    private func centre(_ i: Int) -> CGFloat {
        bounds.midY + (CGFloat(Desktops.shared.count - 1) / 2 - CGFloat(i)) * Self.spacing
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = Desktops.shared.count
        for i in 0..<count {
            let now = i == Desktops.shared.current
            let width: CGFloat = now ? 20 : 10
            (now ? strong : faint).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - width / 2, y: centre(i) - 1, width: width, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        let count = Desktops.shared.count
        guard let nearest = (0..<count).min(by: { abs(centre($0) - y) < abs(centre($1) - y) }),
              abs(centre(nearest) - y) <= Self.spacing / 2 else { return }
        Desktops.shared.go(to: nearest)
    }
}

/// The battery, filling from the bottom.
final class BatteryView: DeskView {
    var level = batteryLevel()

    /// a line across the top, filled from the middle out toward both its ends as far as charged
    override func draw(_ dirtyRect: NSRect) {
        guard let level else { return }
        let line = NSRect(x: 0, y: bounds.midY - barWidth / 2, width: bounds.width, height: barWidth)
        let radius = barWidth / 2
        faint.setFill()
        NSBezierPath(roundedRect: line, xRadius: radius, yRadius: radius).fill()
        let width = line.width * CGFloat(max(0, min(level, 1)))
        guard width > 0 else { return }
        strong.setFill()
        NSBezierPath(roundedRect: NSRect(x: line.midX - width / 2, y: line.minY, width: width, height: line.height), xRadius: radius, yRadius: radius).fill()
    }

    override func menuItems() -> [NSMenuItem] {
        guard let level else { return [] }
        return [NSMenuItem(title: "Battery \(Int((level * 100).rounded()))%", action: nil, keyEquivalent: "")]
    }
}

// ── sound ──

private let system = AudioObjectID(kAudioObjectSystemObject)

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

/// For plain numbers and ids only; strings go through `uid`.
private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as value: T) -> T? {
    var address = address(selector)
    var value = value
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

/// A device's UID; Core Audio hands the string over retained.
private func uid(_ device: AudioObjectID) -> String? {
    var address = address(kAudioDevicePropertyDeviceUID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

/// Whether any other app is sending sound out right now (asked per app, so ReDesk's own
/// listening below doesn't count).
func othersPlaying() -> Bool {
    var list = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr else { return false }
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &processes) == noErr else { return false }
    let me = getpid()
    return processes.contains { process in
        read(process, kAudioProcessPropertyPID, as: pid_t(0)) != me
            && read(process, kAudioProcessPropertyIsRunningOutput, as: UInt32(0)) ?? 0 != 0
    }
}

/// How loud the Mac is playing, 0…1. It listens to everything that goes out through a Core Audio
/// tap (macOS asks once for permission to capture audio); nothing is kept, only the loudness.
final class Meter {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var current: Float = 0
    private(set) var running = false

    var level: CGFloat {
        lock.lock(); defer { lock.unlock() }
        return CGFloat(current)
    }

    func start() {
        guard !running else { return }
        // the system's sound is heard from macOS 14.2 on; before it the wave stays still
        guard #available(macOS 14.2, *) else { return }
        running = true
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr,
              let output = read(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID(0)),
              let outputUID = uid(output) else { return stop() }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ReDesk Meter",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else { return stop() }
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, DispatchQueue(label: "redesk.meter")) { [weak self] _, input, _, _, _ in
            var sum: Float = 0
            var count = 0
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<n { sum += samples[i] * samples[i] }
                count += n
            }
            let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
            // -54 dB … -12 dB of loudness spread over 0…1
            let db = 20 * log10(max(rms, 1e-6))
            let level = min(max((db + 54) / 42, 0), 1)
            self?.lock.lock()
            self?.current = level
            self?.lock.unlock()
        }
        guard status == noErr, let proc, AudioDeviceStart(device, proc) == noErr else { return stop() }
    }

    func stop() {
        if device != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(device, proc)
                AudioDeviceDestroyIOProcID(device, proc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if #available(macOS 14.2, *), tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        device = AudioObjectID(kAudioObjectUnknown)
        proc = nil
        running = false
        lock.lock(); current = 0; lock.unlock()
    }
}

/// While sound plays: three soft sine lines drifting along the bottom, tapering to nothing at
/// both ends. Their height follows how loud it is; in silence they settle flat and away.
final class WaveView: NSView {
    private let meter = Meter()
    private var playing = false
    /// the drawn loudness, 0 (gone) … 1, eased towards the meter
    private var strength: CGFloat = 0
    private var phase: CGFloat = 0
    private var last = CACurrentMediaTime()
    private var frames: Timer?
    private let waves: [(cycles: CGFloat, speed: CGFloat, height: CGFloat, alpha: CGFloat)] = [
        (2.0, 1.6, 1.0, 0.35),
        (3.0, -1.1, 0.7, 0.22),
        (1.5, 0.8, 0.55, 0.14),
    ]

    func set(playing: Bool) {
        self.playing = playing
        if playing {
            meter.start()
            start()
        }
    }

    private func start() {
        guard frames == nil else { return }
        last = CACurrentMediaTime()
        frames = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.frame() }
    }

    private func frame() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(now - last)
        last = now
        let target = playing ? meter.level : 0
        // rise quickly with a beat, fall back gently
        strength += (target - strength) * (target > strength ? 0.35 : 0.08)
        // louder sound moves the lines a little faster
        phase += dt * (0.6 + 0.9 * strength)
        if !playing && strength < 0.005 {
            strength = 0
            frames?.invalidate()
            frames = nil
            meter.stop()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard strength > 0.01 else { return }
        let mid = bounds.midY
        let reach = bounds.height / 2 - 2
        for (k, wave) in waves.enumerated() {
            // each line breathes a little on its own
            let breath = 0.75 + 0.25 * sin(phase * 0.9 + CGFloat(k) * 2.1)
            let amplitude = reach * wave.height * breath * strength
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            var x: CGFloat = 0
            while x <= bounds.width {
                let u = x / bounds.width
                let taper = pow(sin(.pi * u), 2)
                let y = mid + amplitude * taper * sin(2 * .pi * wave.cycles * u + phase * wave.speed * 2 + CGFloat(k))
                if x == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
                x += 2
            }
            // quiet sound draws fainter lines too
            ink(wave.alpha * min(1, strength * 1.6)).setStroke()
            path.stroke()
        }
    }
}

final class DeskWindow: NSWindow {
    /// where this piece goes on a screen
    let frameOn: (Layout) -> NSRect

    init(view: NSView, frameOn: @escaping (Layout) -> NSRect) {
        self.frameOn = frameOn
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // a clear window lets clicks fall through wherever nothing is drawn, i.e. between
        // the thin strokes of the letters; saying so explicitly makes the whole piece clickable
        ignoresMouseEvents = false
        // just above the desktop icons, below every other window
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(on screen: NSScreen) {
        // by the whole screen, not what the menu bar leaves: on every screen the same, the side dashes in its
        // very middle (the menu bar pushed them down on the main one)
        setFrame(frameOn(Layout(area: screen.frame)).integral, display: true)
        orderFront(nil)
        contentView?.needsDisplay = true
    }

    /// Redraws the piece with its old look fading into the new one (the ink turned with the
    /// wallpaper or the Mac's appearance), as the wallpaper itself does.
    func redrawFading() {
        guard let view = contentView else { return }
        view.wantsLayer = true
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Crossfade.themeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(fade, forKey: "ink")
        view.needsDisplay = true
    }
}



// ── the lock screen ──
// ⌘L, or a few minutes with nothing touched: the desk's own screen over everything — the wallpaper
// (a video one moving) — until the Mac's password is typed into its own field (UNLOCK clicked, Return or
// any letter opens it; tried against the account with OpenDirectory, no Touch ID, no system prompt). It is
// a window over a Mac still unlocked, so after a while on it the Mac's own lock comes too; unlocking that
// lets this go.

/// The face: UNLOCK down the screen's middle, the password's field there once asked for. Over the wallpaper, in the apps' small letters.
let lockLetters = NSFont(name: "NotoSansJP-Regular", size: 14) ?? .systemFont(ofSize: 14, weight: .light)

final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The password's field: unseen (it only takes the typing, as a secure field: no other app reads it); the face
/// draws a diamond for each letter, in a box marked by a + at each corner. Return tries it, Escape puts it away.
final class PasswordField: NSSecureTextField {
    /// what is typed now: a secure field gives its text back only once editing ends, its editor has it meanwhile
    var typed: String { (currentEditor() as? NSText)?.string ?? stringValue }
}

/// Over the password box's glass: its +, its diamonds and its caret (the face draws under its subviews, the
/// glass among them, so these are drawn here, above it). Clicks go through to the face.
final class LockBoxMarks: NSView {
    weak var face: LockFace?
    override func draw(_ dirtyRect: NSRect) { face?.drawBox() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class LockFace: NSView, NSTextFieldDelegate {
    /// the password typed, to be tried: `answer` says whether it was right
    var tryPassword: (_ password: String, _ answer: @escaping (Bool) -> Void) -> Void = { _, _ in }
    /// a click on another screen than the main one
    var elsewhere: () -> Void = {}
    /// the screen with UNLOCK and the password (the others only show the wallpaper)
    let main: Bool
    private(set) var field: PasswordField?
    private var trying = false
    /// the box's sideways shift while it shakes for a wrong password
    private var shake: CGFloat = 0

    init(frame: NSRect, main: Bool) {
        self.main = main
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard main else { return elsewhere() }
        let point = convert(event.locationInWindow, from: nil)
        if let field, !boxClosing {
            // a click beside the open field leaves it be (only Escape puts it away)
            window?.makeFirstResponder(field)
            return
        }
        if unlockPlace.contains(point) { openField(with: "") }
    }
    override func keyDown(with event: NSEvent) {
        guard main, field == nil else { return }
        if event.keyCode == UInt16(kVK_Escape) { return }
        // Return opens the field; a letter opens it with that letter already in
        let enter = event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        let typed = event.characters?.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } } ?? ""
        if enter || !typed.isEmpty { openField(with: enter ? "" : typed) }
    }

    private var letters: [Character] { Array(tr("UNLOCK").filter { $0 != " " }) }

    /// UNLOCK down the screen's middle, with room round it for the click
    private var unlockPlace: NSRect {
        let height = CGFloat(letters.count) * letterStep
        return NSRect(x: bounds.midX - 40, y: bounds.midY - height / 2 - 16, width: 80, height: height + 32)
    }

    /// the password's box, in the screen's middle where UNLOCK was
    private var fieldPlace: NSRect {
        NSRect(x: bounds.midX - 220 + shake, y: bounds.midY - 34, width: 440, height: 68)
    }

    /// the diamonds' size and the step between them
    private let dot: CGFloat = 12, dotStep: CGFloat = 22

    func openField(with typed: String) {
        guard field == nil else { return }
        let field = PasswordField(frame: .zero)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alphaValue = 0
        field.stringValue = typed
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.frame = fieldPlace.insetBy(dx: 14, dy: 20)
        addSubview(field)
        self.field = field
        window?.makeFirstResponder(field)
        playBox(closing: false)
        startBlinking()
        // typing goes on after what was typed, not over all of it chosen
        DispatchQueue.main.async {
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0) }
        }
        needsDisplay = true
    }

    /// Escape: the box closes as it opened, backwards; then UNLOCK again
    func closeField() {
        guard field != nil, !boxClosing else { return }
        window?.makeFirstResponder(self)
        playBox(closing: true)
    }

    private func removeField() {
        blink?.invalidate()
        blink = nil
        glass.removeFromSuperview()
        marks.removeFromSuperview()
        field?.removeFromSuperview()
        field = nil
        trying = false
        needsDisplay = true
    }

    // ── the box opening and closing as the apps' windows do (Opening.swift): UNLOCK fading, the corners' + round the
    // box's whole width but a quarter of its height, the box growing to its height, the diamonds coming in over it ──

    /// the box's glass, as the apps' windows have (their dark HUD blur), as tall as the box has grown
    private lazy var glass: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .withinWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.alphaValue = 0
        return v
    }()
    private var glassAlpha: CGFloat = 1
    /// the caret after the diamonds, blinking as a text field's
    private var caretOn = true
    private var blink: Timer?

    private var boxStage: Timer?
    private var boxBegun = Date()
    private var boxClosing = false
    private var wordAlpha: CGFloat = 1
    private var plusAlpha: CGFloat = 1
    private var boxGrow: CGFloat = 1
    private var dotsAlpha: CGFloat = 1
    private static let boxOpening = (word: (0.0, 0.12), plus: (0.06, 0.16), fill: (0.10, 0.22), grow: (0.16, 0.40), dots: (0.36, 0.50))
    private static let boxClosingTimes = (dots: (0.0, 0.10), grow: (0.06, 0.26), fill: (0.20, 0.32), plus: (0.24, 0.36), word: (0.30, 0.46))

    /// the box as it is now: a quarter of its height to the whole of it, shaking when the password was wrong
    private var boxNow: NSRect {
        let whole = fieldPlace
        let h = whole.height * (0.25 + 0.75 * boxGrow)
        return NSRect(x: whole.minX, y: whole.midY - h / 2, width: whole.width, height: h)
    }

    private lazy var marks: LockBoxMarks = {
        let v = LockBoxMarks()
        v.face = self
        return v
    }()

    private func placeGlass() {
        if glass.superview == nil, let field { addSubview(glass, positioned: .below, relativeTo: field) }
        if marks.superview == nil { addSubview(marks, positioned: .above, relativeTo: glass) }
        glass.frame = boxNow
        glass.alphaValue = field == nil ? 0 : glassAlpha
        marks.frame = bounds
        marks.needsDisplay = true
    }

    private func startBlinking() {
        blink?.invalidate()
        caretOn = true
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretOn.toggle()
            self.redraw()
        }
        RunLoop.main.add(timer, forMode: .common)
        blink = timer
    }

    private static func ease(_ t: Double) -> CGFloat {
        let t = min(1, max(0, t))
        return CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
    }
    private static func part(_ t: Double, _ span: (Double, Double)) -> CGFloat { ease((t - span.0) / (span.1 - span.0)) }

    private func playBox(closing: Bool) {
        boxStage?.invalidate()
        boxBegun = Date()
        boxClosing = closing
        stepBox()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stepBox() }
        RunLoop.main.add(timer, forMode: .common)
        boxStage = timer
    }

    private func stepBox() {
        let t = Date().timeIntervalSince(boxBegun)
        if !boxClosing {
            let o = Self.boxOpening
            wordAlpha = 1 - Self.part(t, o.word)
            plusAlpha = Self.part(t, o.plus)
            glassAlpha = Self.part(t, o.fill)
            boxGrow = Self.part(t, o.grow)
            dotsAlpha = Self.part(t, o.dots)
            if t >= o.dots.1 { boxStage?.invalidate(); boxStage = nil }
        } else {
            let c = Self.boxClosingTimes
            dotsAlpha = 1 - Self.part(t, c.dots)
            boxGrow = 1 - Self.part(t, c.grow)
            glassAlpha = 1 - Self.part(t, c.fill)
            plusAlpha = 1 - Self.part(t, c.plus)
            wordAlpha = Self.part(t, c.word)
            if t >= c.word.1 {
                boxStage?.invalidate()
                boxStage = nil
                boxClosing = false
                removeField()
                (wordAlpha, plusAlpha, boxGrow, dotsAlpha, glassAlpha) = (1, 1, 1, 1, 1)
            }
        }
        if field != nil { placeGlass() }
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        // typing: the caret steady a moment, as a text field's
        startBlinking()
        redraw()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { closeField(); return true }
        return false
    }

    private func submit() {
        guard let field, !trying else { return }
        let password = field.typed
        guard !password.isEmpty else { return }
        trying = true
        tryPassword(password) { [weak self] right in
            guard let self, self.field === field else { return }
            self.trying = false
            if !right { self.wrong(field) }
        }
    }

    /// a wrong password: the box shakes, then empties
    private func wrong(_ field: PasswordField) {
        let steps: [CGFloat] = [-14, 12, -9, 6, -3, 0]
        for (i, dx) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045 * Double(i)) {
                self.shake = dx
                self.placeGlass()
                self.redraw()
                if i == steps.count - 1 { field.stringValue = "" }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard main else { return }
        if field != nil {
            if wordAlpha > 0 { drawWord(alpha: wordAlpha) }
            return
        }
        drawWord()
    }

    /// the box's +, diamonds and caret, drawn over its glass (LockBoxMarks)
    func drawBox() {
        guard main, let field else { return }
        do {
            // a + at each corner of the box, as the popups and the apps' windows; a quarter of its height to the
            // whole of it while it opens
            let box = boxNow
            let path = NSBezierPath()
            let a = PlusMarks.arm
            for p in [NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY),
                      NSPoint(x: box.minX, y: box.maxY), NSPoint(x: box.maxX, y: box.maxY)] {
                let x = p.x.rounded() + 0.25, y = p.y.rounded() - 0.25
                path.move(to: NSPoint(x: x - a, y: y)); path.line(to: NSPoint(x: x + a, y: y))
                path.move(to: NSPoint(x: x, y: y - a)); path.line(to: NSPoint(x: x, y: y + a))
            }
            path.lineWidth = PlusMarks.line
            ink(0.6 * plusAlpha).setStroke()
            path.stroke()
            // a diamond for each letter typed, in the box's very middle (as many as fit)
            let count = min((field.typed as NSString).length, Int((box.width - 40) / dotStep) + 1)
            let first = box.midX - CGFloat(max(count, 1) - 1) * dotStep / 2
            // the caret: after the last diamond (in the middle, nothing typed yet), blinking
            if caretOn && !boxClosing && dotsAlpha > 0 {
                let x = count > 0 ? first + CGFloat(count - 1) * dotStep + dot / 2 + 8 : box.midX
                ink(0.85 * dotsAlpha).setFill()
                NSRect(x: x.rounded(), y: box.midY - 11, width: 1.5, height: 22).fill()
            }
            guard count > 0 else { return }
            for i in 0..<count {
                let c = NSPoint(x: first + CGFloat(i) * dotStep, y: box.midY)
                let r = dot / 2
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: c.x, y: c.y + r)); diamond.line(to: NSPoint(x: c.x + r, y: c.y))
                diamond.line(to: NSPoint(x: c.x, y: c.y - r)); diamond.line(to: NSPoint(x: c.x - r, y: c.y))
                diamond.close()
                ink(0.95 * dotsAlpha).setFill()
                diamond.fill()
            }
        }
    }

    /// the face drawn again, and the box's marks over the glass with it (a blink, a letter typed, the box shaking)
    private func redraw() {
        needsDisplay = true
        if marks.superview != nil { marks.needsDisplay = true }
    }

    /// UNLOCK down the screen's middle, as the desk's words and the apps' side buttons: a letter to a step
    private func drawWord(alpha: CGFloat = 1) {
        let attributes: [NSAttributedString.Key: Any] = [.font: letterFont, .foregroundColor: ink(0.5 * alpha)]
        let bottom = bounds.midY - CGFloat(letters.count) * letterStep / 2
        for (i, letter) in letters.reversed().enumerated() {
            let text = NSAttributedString(string: String(letter), attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bottom + CGFloat(i) * letterStep + (letterStep - size.height) / 2))
        }
    }
}

final class LockScreen {
    static let shared = LockScreen()

    private var windows: [LockWindow] = []
    private var faces: [LockFace] = []
    private var shownAt: Date?
    private var before: NSRunningApplication?
    private var systemLocked = false

    var shown: Bool { !windows.isEmpty }

    /// minutes with nothing touched before it comes (0: only ⌘L)
    var idleMinutes: Double {
        UserDefaults.standard.object(forKey: "lockAfterMinutes") as? Double ?? 5
    }
    /// minutes on it before the Mac's own lock comes too
    let systemLockMinutes: Double = 10

    /// Watches for the idle time and the Mac's own lock.
    func start() {
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.systemLocked = true
        }
        // the Mac unlocked with its own password: no second unlocking here
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.systemLocked = false
            self?.hide()
        }
        // the screens changed under it (the lid shut or opened, a display in or out): made again for the
        // screens there are now, never a dark window left without its face
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.shown else { return }
            let before = self.before
            self.windows.forEach { $0.orderOut(nil) }
            self.windows = []
            self.faces = []
            self.show()
            self.before = before
        }
    }

    private func check() {
        if shown {
            if !systemLocked, !faces.contains(where: { $0.field != nil }), let shownAt, Date().timeIntervalSince(shownAt) > systemLockMinutes * 60 {
                lockTheMac()
            }
            return
        }
        guard idleMinutes > 0, !systemLocked else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= idleMinutes * 60 && !somethingKeepsTheScreenOn() { show() }
    }

    /// A video playing, a call, a presentation: whatever keeps the display awake keeps this away too.
    private func somethingKeepsTheScreenOn() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let dict = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (dict[kIOPMAssertPreventUserIdleDisplaySleep as String] ?? 0) > 0
            || (dict["PreventUserIdleDisplaySleep"] ?? 0) > 0
    }

    /// The Mac's own lock (login.framework, as the menu's Lock Screen does); its display sleep if that can't be found.
    private func lockTheMac() {
        typealias Lock = @convention(c) () -> Int32
        if let framework = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(framework, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: Lock.self)()
        } else {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["displaysleepnow"]
            try? task.run()
        }
        systemLocked = true
    }

    func show() {
        guard !shown else { return }
        before = NSWorkspace.shared.frontmostApplication
        shownAt = Date()
        let mainScreen = NSScreen.screens.first
        for screen in NSScreen.screens {
            let window = LockWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let bounds = NSRect(origin: .zero, size: screen.frame.size)
            let container = NSView(frame: bounds)
            container.wantsLayer = true

            // the wallpaper: its picture (a video's still), the video moving over it, a light veil for the letters
            let still = NSView(frame: bounds)
            still.wantsLayer = true
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = Crossfade.picture(url, for: screen) {
                still.layer?.contents = image
                still.layer?.contentsGravity = .resizeAspectFill
            }
            container.addSubview(still)
            if let player = LiveWallpaper.shared.player {
                let video = NSView(frame: bounds)
                let layer = AVPlayerLayer(player: player)
                layer.videoGravity = .resizeAspectFill
                video.layer = layer
                video.wantsLayer = true
                container.addSubview(video)
            }
            let veil = NSView(frame: bounds)
            veil.wantsLayer = true
            veil.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            container.addSubview(veil)

            let face = LockFace(frame: bounds, main: screen == mainScreen)
            face.tryPassword = { [weak self] password, answer in self?.tryPassword(password, answer: answer) }
            face.elsewhere = { [weak self] in self?.windows.first?.makeKeyAndOrderFront(nil) }
            container.addSubview(face)
            faces.append(face)

            window.contentView = container
            window.alphaValue = 0
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        // no Dock, no menu bar, no ⌘Tab, no Force Quit or logging out past it
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
                                     .disableSessionTermination, .disableHideApplication, .disableAppleMenu]
        if let main = windows.first {
            main.makeKeyAndOrderFront(nil)
            main.makeFirstResponder(main.contentView?.subviews.last)
        }
        NSCursor.setHiddenUntilMouseMoves(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Crossfade.themeDuration
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }

    /// The password typed into the lock screen's own field, tried against this Mac's account (OpenDirectory,
    /// as the Mac's own lock does), away from the main thread; no Touch ID, no system prompt.
    private func tryPassword(_ password: String, answer: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var right = false
            if let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
               let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil) {
                right = (try? record.verifyPassword(password)) != nil
            }
            DispatchQueue.main.async {
                answer(right)
                if right { self.hide() }
            }
        }
    }

    func hide() {
        guard shown else { return }
        NSApp.presentationOptions = []
        let going = windows
        windows = []
        faces = []
        shownAt = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            going.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            going.forEach { $0.orderOut(nil) }
        })
        before?.activate()
        before = nil
    }
}

/// The screen's brightness follows the lid: open (from about 100°) it is the brightness the user chose,
/// closing it dims the screen down to nearly dark at 20°. The angle comes from the hinge's sensor (a HID
/// sensor of Apple's, 0x05AC:0x8104, on the MacBooks that have one), the brightness goes through
/// DisplayServices; neither is public. Set by hand (the keys, Control Center, auto-brightness) with the lid
/// well open, the brightness becomes the new open one. Shut, asleep or on an external display, the screen
/// is given its brightness back first, and nothing read from a screen just woken counts.
final class LidLight {
    static let shared = LidLight()

    var on: Bool {
        get { UserDefaults.standard.object(forKey: "lidLight") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lidLight"); newValue ? start() : stop() }
    }

    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set_ = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var getBrightness: Get?
    private var setBrightness: Set_?
    private var sensor: IOHIDDevice?
    private var manager: IOHIDManager?
    private var timer: Timer?
    /// the brightness with the lid open
    private var base: Float?
    private var setAt = Date.distantPast

    var available: Bool { open() }

    private init() {
        if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
            if let f = dlsym(h, "DisplayServicesGetBrightness") { getBrightness = unsafeBitCast(f, to: Get.self) }
            if let f = dlsym(h, "DisplayServicesSetBrightness") { setBrightness = unsafeBitCast(f, to: Set_.self) }
        }
    }

    @discardableResult private func open() -> Bool {
        if sensor != nil { return true }
        guard getBrightness != nil, setBrightness != nil else { return false }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
                                          kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let device = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first else { return false }
        manager = m
        sensor = device
        return true
    }

    /// degrees, 0 closed
    private func angle() -> Double? {
        guard let sensor else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        guard IOHIDDeviceGetReport(sensor, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess, length >= 3 else { return nil }
        return Double(Int(report[1]) | Int(report[2]) << 8)
    }

    /// the MacBook's own screen, while it is on (none with the lid shut on an external display)
    private var builtin: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }
    }

    private func brightness(_ display: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        guard let getBrightness, getBrightness(display, &value) == 0 else { return nil }
        return value
    }

    /// The brightness with the lid open, kept across sleeps and launches: never guessed from a screen just
    /// woken (it says 0 then, or the dim it was closed at), never below a tenth, so the screen can't be left dark.
    private static let floor: Float = 0.1
    private var kept: Float? {
        get { (UserDefaults.standard.object(forKey: "lidLightBase") as? Double).map { Float($0) } }
        set { UserDefaults.standard.set(newValue.map { Double($0) }, forKey: "lidLightBase") }
    }
    /// no reading nor setting until then: the screen just woke, came back or changed
    private var quietUntil = Date.distantPast
    /// the lid shut (or the MacBook's screen off): the brightness given back, nothing done until it opens
    private var closed = false
    private var watching = false

    /// Wake, the screens changing (the lid shut on an external display, the cable out): wait a moment, then
    /// begin again from the brightness kept.
    private func settle() {
        quietUntil = Date().addingTimeInterval(2.5)
        smooth = nil
        shown = nil
    }

    /// The user's brightness back on the MacBook's screen.
    private func giveBack() {
        guard let base, let setBrightness, let display = builtin else { return }
        _ = setBrightness(display, base)
        shown = base
        setAt = Date()
    }

    /// how much of the open brightness at this angle: 0 at 20°, all of it from 100°, eased between
    private func share(_ angle: Double) -> Float {
        let t = min(max((angle - 20) / 80, 0), 1)
        return Float(t * t * (3 - 2 * t))
    }

    func start() {
        guard on, timer == nil, open() else { return }
        smooth = nil
        shown = nil
        base = kept.map { max(Self.floor, $0) }
        closed = false
        if !watching {
            watching = true
            let workspace = NSWorkspace.shared.notificationCenter
            // going to sleep: the brightness given back first, so the screen wakes as it was
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.giveBack(); self?.settle() }
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.settle() }
            }
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.settle()
            }
        }
        pace(fast: false)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // the user's brightness back
        giveBack()
    }

    /// 60 times a second while the lid or the brightness moves, 10 while all is still
    private func pace(fast: Bool) {
        if timer != nil && fast == self.fast { return }
        self.fast = fast
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 60 : 0.1, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var fast = false
    /// the angle, eased (the sensor gives whole degrees)
    private var smooth: Double?
    /// the brightness as set last, easing toward the target
    private var shown: Float?
    private var stillSince = Date()

    private func step() {
        guard Date() >= quietUntil else { return }
        // the lid shut on an external display: the MacBook's screen is off, nothing to do
        guard let display = builtin, CGDisplayIsAsleep(display) == 0 else {
            closed = true
            smooth = nil
            shown = nil
            return
        }
        guard let angle = angle(), let now = brightness(display) else { return }
        // all but shut: the brightness given back now, so the screen comes back as it was when it opens
        if angle < 8 {
            if !closed { giveBack() }
            closed = true
            smooth = nil
            return
        }
        if closed {
            closed = false
            smooth = nil
            shown = nil
        }
        let eased = smooth.map { $0 + (angle - $0) * 0.18 } ?? angle
        smooth = eased
        let share = share(eased)
        if base == nil {
            // the first time ever: what the screen shows with the lid well open
            guard share > 0.9, now >= Self.floor else { return }
            base = min(1, now / share)
            kept = base
        }
        if shown == nil {
            shown = now
            setAt = Date()
        } else if let shown, abs(shown - now) > 0.02, Date().timeIntervalSince(setAt) > 1, share > 0.9 {
            // changed by the user (the brightness keys), with the lid open: what they want, but never dark
            base = max(Self.floor, min(1, now / share))
            kept = base
            self.shown = now
        }
        guard let base, let shown, let setBrightness else { return }
        let target = max(0.01, base * share)
        let moving = abs(angle - eased) > 0.05 || abs(target - shown) > 0.001
        if moving { stillSince = Date() }
        pace(fast: Date().timeIntervalSince(stillSince) < 0.5)
        guard abs(target - shown) > 0.001 else { return }
        let next = shown + (target - shown) * 0.2
        let value = abs(target - next) < 0.001 ? target : next
        if setBrightness(display, value) == 0 {
            self.shown = value
            setAt = Date()
        }
    }
}

// ── the two popups: Settings (⌘, or a right click) and Keys (⌘/), every Re app's keys ──

/// The Re apps' popups (as their INFO on glass): a darker frosted pane and a line round it, in the middle of
/// the screen, everything else blurred behind; the heading in Noto Sans JP spaced wide, the words in M PLUS 1p. Esc, the same keys again, or a click beside it closes it.
class Popup: NSPanel {
    /// the pane's colours, as the apps' --bg, --text and --line on glass: the words in the desk's white
    static let paper = NSColor(white: 0, alpha: 0.32)
    static let text = NSColor(white: 1, alpha: 0.8)
    static let line = NSColor(white: 1, alpha: 0.5)

    static let fonts: Void = {
        for name in ["Kurale"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "woff") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        if let url = Bundle.main.url(forResource: "MPLUS1p", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        _ = letterFont
    }()
    static func noto(_ size: CGFloat) -> NSFont { _ = fonts; return NSFont(name: "NotoSansJP-Regular", size: size) ?? .systemFont(ofSize: size, weight: .light) }
    /// the words' font: M PLUS 1p (as the apps' text on glass), Kurale if it can't be loaded
    static func kurale(_ size: CGFloat) -> NSFont {
        _ = fonts
        if let font = NSFont(name: "MPLUS1p-Regular", size: size) { return font }
        return NSFont(name: "Kurale-Regular", size: size) ?? NSFont(name: "Kurale", size: size) ?? .systemFont(ofSize: size) }

    private let paperView = PaperView()
    private lazy var veil: NSWindow = {
        let veil = VeilWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        veil.level = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue - 1)
        veil.isOpaque = false
        veil.backgroundColor = NSColor(white: 0, alpha: 0.001)
        veil.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        veil.onClick = { [weak self] in self?.close() }
        // the blur: the system's own glass over everything behind (light or dark as the Mac is)
        let glass = NSVisualEffectView()
        glass.material = .fullScreenUI
        glass.blendingMode = .behindWindow
        glass.state = .active
        veil.contentView = glass
        return veil
    }()
    /// the controls' actions, kept while they're shown
    var actions: [Do] = []

    init(width: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = paperView
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() { super.resignKey(); if closesWhenLeft { close() } }
    /// closed when another window takes the keys (the guide stays: a permission's question may come over it)
    var closesWhenLeft: Bool { true }

    // ── opening and closing as the apps' windows do (Opening.swift): the corners' + first, round the whole
    // width but a quarter of the height, in the middle; the paper fills them and grows to the whole height;
    // what it shows fades in over it. Closing: the same, backwards ──

    private var stage: Timer?
    private var stageBegun = Date()
    private var closingNow = false
    private static let opening = (plus: 0.10, fill: (0.06, 0.20), grow: (0.20, 0.44), show: (0.38, 0.56))
    private static let closing = (hide: (0.0, 0.10), shrink: (0.08, 0.30), fill: (0.28, 0.42), plus: (0.40, 0.54))

    private static func ease(_ t: Double) -> CGFloat {
        let t = min(1, max(0, t))
        return CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
    }
    private static func part(_ t: Double, _ span: (Double, Double)) -> Double { (t - span.0) / (span.1 - span.0) }

    private func play(closing: Bool) {
        stage?.invalidate()
        stageBegun = Date()
        closingNow = closing
        stageStep()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.stageStep() }
        RunLoop.main.add(timer, forMode: .common)
        stage = timer
    }

    private func stageStep() {
        let t = Date().timeIntervalSince(stageBegun)
        let content = paperView.subviews
        if !closingNow {
            let o = Self.opening
            paperView.stage(height: 0.25 + 0.75 * Self.ease(Self.part(t, o.grow)), fill: Self.ease(Self.part(t, o.fill)), plus: Self.ease(t / o.plus))
            veil.alphaValue = Self.ease(Self.part(t, o.fill))
            content.forEach { $0.alphaValue = Self.ease(Self.part(t, o.show)) }
            if t >= o.show.1 { stage?.invalidate(); stage = nil }
        } else {
            let c = Self.closing
            content.forEach { $0.alphaValue = 1 - Self.ease(Self.part(t, c.hide)) }
            paperView.stage(height: 1 - 0.75 * Self.ease(Self.part(t, c.shrink)), fill: 1 - Self.ease(Self.part(t, c.fill)),
                            plus: 1 - Self.ease(Self.part(t, c.plus)))
            veil.alphaValue = 1 - Self.ease(Self.part(t, c.fill))
            if t >= c.plus.1 { closed() }
        }
    }

    /// closes as the apps' windows do; a second close meanwhile changes nothing
    override func close() {
        guard isVisible else { return veil.orderOut(nil) }
        guard !closingNow else { return }
        play(closing: true)
    }

    private func closed() {
        stage?.invalidate()
        stage = nil
        closingNow = false
        super.close()
        veil.orderOut(nil)
        veil.alphaValue = 1
        paperView.stage(height: 1, fill: 1, plus: 1)
    }

    /// the popup's content: built anew each time it shows (and when a choice changes what it shows)
    func build() -> NSView { NSView() }

    /// how wide it is on this screen
    func width(on screen: NSRect) -> CGFloat { frame.width }

    func toggle() { isVisible && !closingNow ? close() : show() }

    func show() {
        refresh()
        if let screen = NSScreen.main {
            veil.setFrame(screen.frame, display: true)
            veil.appearance = NSAppearance(named: .darkAqua)
            veil.alphaValue = 0
            veil.orderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        play(closing: false)
    }

    func refresh() {
        actions = []
        // the lists a choice opens, dark as the pane
        appearance = NSAppearance(named: .darkAqua)
        veil.appearance = appearance
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = width(on: screen)
        setContentSize(NSSize(width: width, height: 400))
        let content = build()
        content.translatesAutoresizingMaskIntoConstraints = false
        paperView.subviews.forEach { $0.removeFromSuperview() }
        paperView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: paperView.leadingAnchor, constant: 48),
            content.trailingAnchor.constraint(equalTo: paperView.trailingAnchor, constant: -48),
            content.topAnchor.constraint(equalTo: paperView.topAnchor, constant: 40),
        ])
        paperView.needsDisplay = true
        paperView.layoutSubtreeIfNeeded()
        let height = min(content.fittingSize.height + 80, screen.height - 40)
        setFrame(NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height), display: true)
    }

    // ── pieces ──

    func heading(_ words: String) -> NSTextField {
        NSTextField(labelWithAttributedString: NSAttributedString(string: tr(words).uppercased(), attributes: [
            .font: Self.noto(18), .foregroundColor: Self.text, .kern: 7.2,
        ]))
    }

    /// a section's name: small, spaced, quiet
    func caption(_ words: String) -> NSTextField {
        NSTextField(labelWithAttributedString: NSAttributedString(string: tr(words).uppercased(), attributes: [
            .font: Self.noto(11), .foregroundColor: Self.text.withAlphaComponent(0.6), .kern: 2.2,
        ]))
    }

    func words(_ words: String, size: CGFloat = 14, alpha: CGFloat = 1) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: tr(words))
        field.font = Self.kurale(size)
        field.textColor = Self.text.withAlphaComponent(alpha)
        field.isSelectable = false
        return field
    }

    /// keys, as the apps write them: Noto Sans JP, small, quieter
    func keys(_ keys: String) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: NSAttributedString(string: tr(keys), attributes: [
            .font: Self.noto(11), .foregroundColor: Self.text.withAlphaComponent(0.6), .kern: 0.55,
        ]))
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    func divider() -> NSView {
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = Self.line.withAlphaComponent(0.3)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    func act(_ run: @escaping (Any) -> Void) -> Do {
        let action = Do(run)
        actions.append(action)
        return action
    }

    /// a word to click, as the apps' buttons: Noto Sans JP, capitals, spaced
    func button(_ title: String, alpha: CGFloat = 1, _ press: @escaping (NSButton) -> Void) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: tr(title).uppercased(), attributes: [
            .font: Self.noto(12), .foregroundColor: Self.text.withAlphaComponent(alpha), .kern: 2.4,
        ])
        let action = act { sender in if let b = sender as? NSButton { press(b) } }
        button.target = action
        button.action = #selector(Do.fire(_:))
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    /// a line: the words on the left, the control on the right
    func row(_ name: String, _ control: NSView, indent: CGFloat = 0, note: String? = nil) -> NSView {
        var left: [NSView] = [words(name)]
        if let note { left.append(keys(note)) }
        let label = NSStackView(views: left)
        label.orientation = .horizontal
        label.spacing = 10
        label.alignment = .firstBaseline
        let line = NSStackView(views: [label, NSView(), control])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        return line
    }

    /// ON / OFF, the one that isn't so faint
    func toggleRow(_ name: String, _ on: Bool, indent: CGFloat = 0, note: String? = nil, _ change: @escaping (Bool) -> Void) -> NSView {
        let control = button(on ? "On" : "Off", alpha: on ? 1 : 0.45) { [weak self] _ in
            change(!on)
            DispatchQueue.main.async { self?.refresh() }
        }
        return row(name, control, indent: indent, note: note)
    }

    /// the chosen one's name; a click lists the others
    func choiceRow(_ name: String, _ choices: [String], _ chosen: Int, indent: CGFloat = 0, note: String? = nil, _ change: @escaping (Int) -> Void) -> NSView {
        let choices = choices.map(tr)
        let control = button(choices[chosen] + "  ▾") { [weak self] button in
            guard let self else { return }
            let menu = NSMenu()
            for (i, choice) in choices.enumerated() {
                let item = menu.addItem(withTitle: choice, action: #selector(Do.fire(_:)), keyEquivalent: "")
                item.state = i == chosen ? .on : .off
                item.target = self.act { _ in
                    change(i)
                    DispatchQueue.main.async { self.refresh() }
                }
            }
            menu.popUp(positioning: menu.item(at: chosen), at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
        return row(name, control, indent: indent, note: note)
    }

    func buttonRow(_ name: String, _ title: String, indent: CGFloat = 0, note: String? = nil, _ press: @escaping () -> Void) -> NSView {
        row(name, button(title) { _ in press() }, indent: indent, note: note)
    }

    func column(_ views: [NSView], spacing: CGFloat = 10, centred: Bool = false) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = centred ? .centerX : .leading
        stack.spacing = spacing
        for view in views where !(view is NSTextField && centred) {
            if view is NSTextField, !(view as! NSTextField).isEditable, (view as! NSTextField).maximumNumberOfLines == 1 { continue }
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }
}

/// the popup's pane
final class PaperView: NSView {
    /// room round the paper for the corners' + (their arms reach out past it)
    static let margin: CGFloat = 8
    /// opening or closing: how much of its height the paper has (in its middle), how filled, how strong the +
    private var height: CGFloat = 1
    private var fill: CGFloat = 1
    private var plus: CGFloat = 1

    func stage(height: CGFloat, fill: CGFloat, plus: CGFloat) {
        self.height = height
        self.fill = fill
        self.plus = plus
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let whole = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        let h = (whole.height * height).rounded()
        let paper = NSRect(x: whole.minX, y: (whole.midY - h / 2).rounded(), width: whole.width, height: h)
        Popup.paper.withAlphaComponent(Popup.paper.alphaComponent * fill).setFill()
        paper.fill()
        // no frame round it: a thin + at each of its corners, as ReDesk marks windows' corners
        let path = NSBezierPath()
        let a = PlusMarks.arm
        for p in [NSPoint(x: paper.minX, y: paper.minY), NSPoint(x: paper.maxX, y: paper.minY),
                  NSPoint(x: paper.minX, y: paper.maxY), NSPoint(x: paper.maxX, y: paper.maxY)] {
            let x = p.x.rounded() + 0.25, y = p.y.rounded() - 0.25
            path.move(to: NSPoint(x: x - a, y: y)); path.line(to: NSPoint(x: x + a, y: y))
            path.move(to: NSPoint(x: x, y: y - a)); path.line(to: NSPoint(x: x, y: y + a))
        }
        path.lineWidth = PlusMarks.line
        Popup.line.withAlphaComponent(Popup.line.alphaComponent * plus).setStroke()
        path.stroke()
    }
}

/// the blur behind a popup; a click on it closes the popup
final class VeilWindow: NSWindow {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}

/// a control's action as a closure
final class Do: NSObject {
    let run: (Any) -> Void
    init(_ run: @escaping (Any) -> Void) { self.run = run }
    @objc func fire(_ sender: Any) { run(sender) }
}

/// Settings: everything the right-click menu had, in one place.
final class SettingsPopup: Popup {
    static let shared = SettingsPopup(width: 1080)

    override func width(on screen: NSRect) -> CGFloat { min(1080, screen.width - 80) }

    override func build() -> NSView {
        // two columns: the desk on the left, the screen and its wallpaper on the right
        var left: [NSView] = [], right: [NSView] = []
        func section(_ name: String, _ rows: [NSView], right isRight: Bool = false) {
            var views = isRight ? right : left
            if !views.isEmpty { views.append(divider()) }
            views.append(caption(name))
            views.append(contentsOf: rows)
            if isRight { right = views } else { left = views }
        }

        var desk: [NSView] = [toggleRow("Tile windows", Tiler.shared.on, note: "⌘.") { Tiler.shared.on = $0 }]
        if Tiler.shared.on && !AXIsProcessTrusted() {
            desk.append(buttonRow("Tiling needs Accessibility", "Allow", indent: 18) { Tiler.openAccessibilitySettings() })
        }
        let arrangements = Arrangement.allCases
        desk.append(choiceRow("Arrangement", arrangements.map(\.title), arrangements.firstIndex(of: Tiler.shared.arrangement) ?? 0,
                              indent: 18, note: "⌘1…⌘6") { Tiler.shared.choose(arrangements[$0]) })
        desk.append(toggleRow("Almost full", Tiler.shared.almostFull, indent: 18, note: "⌘0") { Tiler.shared.almostFull = $0 })
        desk.append(toggleRow("Flush", Tiler.shared.flush, indent: 18, note: "⌘-") { Tiler.shared.flush = $0 })
        desk += [
            toggleRow("Ink cursors", InkCursors.on) { InkCursors.on = $0 },
            toggleRow("Dark appearance", Appearance.dark, note: "⌘⇧T") { if $0 != Appearance.dark { Appearance.toggle() } },
            toggleRow("Plus marks", PlusMarks.on, note: "⌘=") { PlusMarks.on = $0 },
            toggleRow("Open at login", SMAppService.mainApp.status == .enabled) { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {
                    SMAppService.openSystemSettingsLoginItems()
                }
            },
        ]
        let languages = Language.allCases
        desk.append(choiceRow("Language", languages.map(\.title), languages.firstIndex(of: Language.current) ?? 0) { Language.current = languages[$0] })
        section("Desk", desk)

        var wallpaper: [NSView] = []
        if let index = Wallpapers.current, Wallpapers.removable(Wallpapers.all[index]) {
            wallpaper.append(buttonRow("This wallpaper", "Remove") { [weak self] in self?.close(); Wallpapers.removeCurrent() })
        }
        wallpaper.append(toggleRow("Blur wallpaper", WallpaperBlur.on, note: "⌘⇧B") { WallpaperBlur.on = $0 })
        wallpaper.append(toggleRow("Video wallpaper stands still", LiveWallpaper.shared.frozen, note: "⌘⇧M") { LiveWallpaper.shared.frozen = $0 })

        var screen: [NSView] = [
            buttonRow("Lock screen", "Lock", note: "⌘L") { [weak self] in self?.close(); LockScreen.shared.show() },
            buttonRow("Guide", "Open", note: DeskKey.guide.shortcut.text) { [weak self] in self?.close(); GuidePopup.shared.show() },
            toggleRow("Guide at start", GuidePopup.atStart, indent: 18) { GuidePopup.atStart = $0 },
        ]
        if LidLight.shared.available {
            screen.append(toggleRow("Brightness by lid", LidLight.shared.on) { LidLight.shared.on = $0 })
        }
        section("Screen", screen, right: true)
        section("Wallpaper", wallpaper, right: true)

        let columns = NSStackView(views: [column(left, spacing: 12), column(right, spacing: 12)])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 56
        let footer = NSStackView(views: [words("⌘, settings  ·  ⌘/ keys", size: 13, alpha: 0.4), NSView(),
                                         button("Donate") { [weak self] _ in self?.close(); NSWorkspace.shared.open(donateURL) },
                                         button("Quit") { _ in NSApp.terminate(nil) }])
        footer.orientation = .horizontal
        footer.spacing = 36
        footer.alignment = .centerY
        let views: [NSView] = [heading("Re:Desk"), divider(), columns, divider(), footer]
        let stack = column(views, spacing: 12)
        stack.setCustomSpacing(26, after: views[0])
        stack.setCustomSpacing(20, after: views[1])
        stack.setCustomSpacing(20, after: views[2])
        return stack
    }
}

/// Keys: every Re app's keys at once, an app to a column.
final class KeysPopup: Popup {
    static let shared = KeysPopup(width: 1700)

    typealias Keys = [(String, String)]
    static let apps: [(name: String, parts: [(String?, Keys)])] = [
        // "@name": a key one can set (a click, then the new keys): the desk's own (DeskKey) or an app's (AppKey,
        // "@ReSurf.newTab"). Alone, its words are its own; with others ("@a / @b"), the words given.
        ("Re:Desk", [
            (nil, [("@settings", ""), ("@keys", ""), ("@guide", ""), ("@dashboard", ""), ("@lock", ""), ("@appearance", ""), ("@language", ""),
                   ("@stillWallpaper", ""), ("@blurWallpaper", "")]),
            ("Windows", [("@focusLeft @focusRight @focusUp @focusDown", "focus the nearest window"),
                         ("@tradeLeft @tradeRight @tradeUp @tradeDown", "trade places with it"),
                         ("@resizeLeft @resizeRight @resizeUp @resizeDown", "resize the window"), ("@plusMarks", ""), ("@flush", ""),
                         ("@almostFull", ""), ("@tiling", ""), ("@arrange1 @arrange2 @arrange3 @arrange4 @arrange5 @arrange6", "an arrangement"),
                         ("@nextArrangement", ""), ("@promote", ""), ("@pin", ""), ("@otherScreen", ""), ("@focusDesk", ""),
                         ("@sidesIn", ""), ("@sidesOut", ""), ("@wordsIn", ""), ("@wordsOut", ""),
                         ("fn A ← → ↑ ↓", "the same in every app's windows")]),
            ("On the desk", [("@openFile / @openSurf / @openTerm / @openNote", "ReFile / ReSurf / ReTerm / ReNote")]),
            ("Desktops", [("@desktopUp / @desktopDown", "the desktop above / below"), ("@carryUp / @carryDown", "take the window there"),
                          ("@wallpaperBack / @wallpaperNext", "previous / next wallpaper")]),
        ]),
        ("Re:File", [
            (nil, [("@ReFile.allInside  ⇧F…P", "all inside"), ("@ReFile.newWindow", ""), ("@ReFile.up / @ReFile.down", "select"),
                   ("@ReFile.right / @ReFile.enter", "open"), ("@ReFile.left", "the folder above"), ("@ReFile.search", "search"),
                   ("@ReFile.columns / @ReFile.list", "views"), ("@ReFile.sortName @ReFile.sortKind @ReFile.sortDate @ReFile.sortSize", "sort: name, kind, date, size"),
                   ("@ReFile.newFolder", "new folder"), ("@ReFile.info", "info"), ("@ReFile.trash", "move to the Trash")]),
            ("Play", [("@ReFile.folder / @ReFile.songs / @ReFile.radio", "folder / songs / radio"), ("@ReFile.space", "play / pause"),
                      ("@ReFile.shuffle / @ReFile.repeat", "shuffle / repeat"), ("@ReFile.queue", "queue"), ("@ReFile.keep", "keep a station"),
                      ("@ReFile.mini", "mini player")]),
            ("View", [("@ReFile.left @ReFile.right @ReFile.space", "turn the page"), ("@ReFile.mini", "manga"), ("@ReFile.full", "full screen")]),
            ("Table", [("@ReFile.enter", "write in a cell"), ("@ReFile.moreLeft @ReFile.moreRight @ReFile.moreUp @ReFile.moreDown @ReFile.selectAll", "choose more cells"),
                       ("@ReFile.copy / @ReFile.cut / @ReFile.paste", "copy / cut / paste"),
                       ("@ReFile.addLeft @ReFile.addRight @ReFile.addUp @ReFile.addDown", "add a column / row"),
                       ("@ReFile.deleteRow / @ReFile.deleteColumn", "delete the row / column"), ("@ReFile.sortDown / @ReFile.sortUp", "sort by the column"),
                       ("@ReFile.undo / @ReFile.redo", "undo / redo")]),
        ]),
        ("Re:Surf", [
            (nil, [("@ReSurf.newWindow", ""), ("@ReSurf.newTab", ""), ("@ReSurf.address", ""), ("@ReSurf.closeTab", ""), ("@ReSurf.nextTab", ""),
                   ("@ReSurf.tabUp / @ReSurf.tabDown", "previous / next tab"), ("@ReSurf.back / @ReSurf.forward", "back / forward"),
                   ("@ReSurf.reload", ""), ("@ReSurf.favourite", ""), ("@ReSurf.video", ""), ("@ReSurf.pageFull", ""), ("@ReSurf.info", "")]),
            ("Search", [("@ReSurf.left / @ReSurf.right", "previous / next page"), ("@ReSurf.up / @ReSurf.down  @ReSurf.enter", "choose, open")]),
        ]),
        ("Re:Note", [
            ("Notes", [("@ReNote.newWindow", ""), ("@ReNote.up / @ReNote.down", "select a note"), ("@ReNote.left / @ReNote.right", "another space"),
                       ("@ReNote.newNote", "new note"), ("@ReNote.edit / @ReNote.enter", "edit"),
                       ("@ReNote.search  @ReNote.find", "search"), ("@ReNote.delete", "delete"), ("@ReNote.esc", "home")]),
            ("A note", [("@ReNote.save", ""), ("@ReNote.esc", "back")]),
            ("Writing", [("@ReNote.highlight", ""), ("@ReNote.draw", ""), ("@ReNote.undo", ""), ("@ReNote.redo  @ReNote.redoY", "redo")]),
            ("Drawing", [("drag", "draw"), ("⌥ drag", "rub out")]),
        ]),
        ("Re:Term", [
            (nil, [("@ReTerm.newWindow", ""), ("@ReTerm.term / @ReTerm.chat", "TERM / CHAT"), ("@ReTerm.wholeWindow", ""), ("@ReTerm.newConversation", ""),
                   ("@ReTerm.conversationUp / @ReTerm.conversationDown", "the conversation above / below"), ("@ReTerm.deleteConversation", "")]),
            ("TERM", [("@ReTerm.up / @ReTerm.down", "the commands before"), ("@ReTerm.tab", "complete"), ("@ReTerm.stop", ""), ("@ReTerm.end", ""),
                      ("@ReTerm.suspend", ""), ("@ReTerm.bigger / @ReTerm.smaller / @ReTerm.actualSize", "text size")]),
            ("CHAT", [("@ReTerm.send", ""), ("@ReTerm.newLine", ""), ("@ReTerm.tab", "the next provider"), ("@ReTerm.esc", ""),
                      ("@ReTerm.up / @ReTerm.down", "what was said before")]),
        ]),
    ]

    override func width(on screen: NSRect) -> CGFloat { min(1760, screen.width - 80) }

    // ── setting a key of one's own ──

    /// the key being set: the next keys pressed (with ⌘, ⌃ or ⌥) become its own
    private var recording: Settable?
    private var monitor: Any?

    /// one of the desk's keys, as kept: a click and it waits for the new ones; one set otherwise brighter
    private func setter(_ own: Settable) -> NSView {
        let waiting = recording == own
        let title = waiting ? tr("press the keys…") : own.shortcut.text
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Self.noto(11), .kern: 0.55,
            .foregroundColor: Self.text.withAlphaComponent(waiting || own.changed ? 1 : 0.6),
            .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: Self.text.withAlphaComponent(waiting ? 0.8 : 0.3),
        ])
        let action = act { [weak self] _ in self?.record(own) }
        button.target = action
        button.action = #selector(Do.fire(_:))
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func record(_ own: Settable) {
        if recording == own { return stopRecording() }
        recording = own
        CommandKeys.recording = true
        HotKeys.pause()
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.recording != nil else { return event }
                self.pressed(event)
                return nil
            }
        }
        refresh()
    }

    private func pressed(_ event: NSEvent) {
        guard let own = recording else { return }
        var flags: CGEventFlags = []
        if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        let key = Int(event.keyCode)
        // Esc: left as it was; ⌫: its own again
        if flags.isEmpty && key == kVK_Escape { return stopRecording() }
        if flags.isEmpty && (key == kVK_Delete || key == kVK_ForwardDelete) {
            take(own.standard, for: own, asItCame: true)
            return stopRecording()
        }
        // a key alone (or with ⇧ only) only for one that came alone (N, Space, the arrows…): the others want ⌘, ⌃ or ⌥
        let alone: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        guard !flags.intersection(alone).isEmpty || own.standard.flags.intersection(alone).isEmpty else { return NSSound.beep() }
        guard take(Shortcut(key: key, flags: flags), for: own) else { return NSSound.beep() }
        stopRecording()
    }

    /// the keys become this one's; another of its neighbours that had them gets this one's old ones (the two
    /// trade). An app's key can't be one of the desk's: the desk would take it first.
    @discardableResult
    private func take(_ shortcut: Shortcut, for own: Settable, asItCame: Bool = false) -> Bool {
        // (the desk's letters only work with nothing but the desk in front, where no app's key is pressed; a key
        // given back as it came is always taken)
        if case .app = own, !asItCame, DeskKey.allCases.contains(where: { !$0.deskOnly && $0.shortcut == shortcut }) { return false }
        if let other = own.neighbours.first(where: { $0.shortcut == shortcut }) {
            other.shortcut = own.shortcut
        }
        own.shortcut = shortcut
        return true
    }

    private func stopRecording() {
        guard recording != nil || CommandKeys.recording else { return }
        recording = nil
        CommandKeys.recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeys.register()
        if isVisible { refresh() }
    }

    override func close() {
        stopRecording()
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        if recording != nil { return stopRecording() }
        close()
    }

    /// a key and what it does: the key on the left (one's own: a click sets it), the words on the right
    private func line(_ key: String, _ what: String) -> NSView {
        let parts = key.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let owns = parts.compactMap { $0.hasPrefix("@") ? Settable(String($0.dropFirst())) : nil }
        let left: NSView
        if owns.isEmpty {
            left = keys(key)
        } else if parts.count == 1, let own = owns.first {
            left = setter(own)
        } else {
            // several keys, each set by itself, with the words between them ("/") as they are
            let row = NSStackView(views: parts.filter { !$0.isEmpty }.map { part in
                part.hasPrefix("@") ? (Settable(String(part.dropFirst())).map(setter) ?? keys(part)) : keys(part)
            })
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            left = row
        }
        let title = what.isEmpty ? (owns.first?.title ?? "") : what
        // four keys or more (the arrows, the arrangements): the keys on their own line, the words under them
        if owns.count >= 4 {
            let under = NSStackView(views: [NSView(), words(title, size: 14)])
            under.orientation = .horizontal
            under.alignment = .firstBaseline
            let both = NSStackView(views: [left, under])
            both.orientation = .vertical
            both.alignment = .leading
            both.spacing = 4
            under.widthAnchor.constraint(equalTo: both.widthAnchor).isActive = true
            return both
        }
        let line = NSStackView(views: [left, NSView(), words(title, size: 14)])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 12
        return line
    }

    /// a group's name and its keys, one after another
    private func entries(_ parts: [(String?, Keys)]) -> [NSView] {
        var views: [NSView] = []
        for (name, list) in parts {
            if let name { views.append(caption(name)) }
            for (key, what) in list { views.append(line(key, what)) }
        }
        return views
    }

    /// a column: its heading and the line under it (if it has them), then its keys; a little room before each group
    private func stack(_ views: [NSView], head: [NSView]) -> NSStackView {
        let all = head + views
        let column = column(all, spacing: 7)
        for (i, view) in all.enumerated() where view is NSTextField && i > 0 && !head.contains(view) { column.setCustomSpacing(12, after: all[i - 1]) }
        for view in head { column.setCustomSpacing(16, after: view) }
        return column
    }

    private func row(_ columns: [NSView]) -> NSStackView {
        let row = NSStackView(views: columns)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 44
        return row
    }

    /// Five columns across the top (ReFile's long list in two), and ReDesk across the bottom, its keys in five
    /// columns too: so it all stands on one screen.
    override func build() -> NSView {
        var top: [NSView] = []
        for app in Self.apps.dropFirst() {
            if app.name == "Re:File" && app.parts.count > 2 {
                top.append(stack(entries(Array(app.parts.prefix(2))), head: [heading(app.name), divider()]))
                top.append(stack(entries(Array(app.parts.dropFirst(2))), head: [heading(" "), divider()]))
            } else {
                top.append(stack(entries(app.parts), head: [heading(app.name), divider()]))
            }
        }
        let topRow = row(top)

        // ReDesk: its heading and line across, its keys split into five columns as even as they go
        let desk = Self.apps[0]
        let deskViews = entries(desk.parts)
        let per = Int((Double(deskViews.count) / 5).rounded(.up))
        var deskColumns: [NSView] = []
        for start in stride(from: 0, to: deskViews.count, by: per) {
            deskColumns.append(stack(Array(deskViews[start..<min(start + per, deskViews.count)]), head: []))
        }
        while deskColumns.count < 5 { deskColumns.append(NSView()) }
        let deskRow = row(deskColumns)
        let deskHead = heading(desk.name)
        let deskLine = divider()

        let footer = words("\(DeskKey.keys.shortcut.text) \(tr("or Esc closes"))  ·  \(DeskKey.settings.shortcut.text) \(tr("settings"))  ·  \(tr("click a key to set your own, ⌫ for its own again"))",
                           size: 13, alpha: 0.4)
        let all = NSStackView(views: [topRow, deskHead, deskLine, deskRow, footer])
        all.orientation = .vertical
        all.alignment = .centerX
        all.spacing = 30
        all.setCustomSpacing(36, after: topRow)
        all.setCustomSpacing(16, after: deskHead)
        all.setCustomSpacing(16, after: deskLine)
        for view in [topRow, deskLine, deskRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: all.widthAnchor).isActive = true
        }
        deskHead.translatesAutoresizingMaskIntoConstraints = false
        deskHead.leadingAnchor.constraint(equalTo: all.leadingAnchor).isActive = true
        return all
    }
}

final class Desk: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        InkCursors.restore()
        LidLight.shared.stop()
    }

    private let wallpapers = WallpaperView()
    private let day = DayView()
    private let wave = WaveView()
    private var windows: [DeskWindow] = []
    private let strip = AppStripView()
    /// placed by showStrip(), over the strip the hidden menu bar leaves at the top of the screen
    private lazy var stripWindow = DeskWindow(view: strip) { l in l.area }
    /// the apps across the top of the other screens (an external display), in Full Screen and Almost Full
    private var otherStrips: [DeskWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ReDesk shows no menu bar, but its fields (the dashboard's Wi-Fi password) still want ⌘X ⌘C ⌘V ⌘A ⌘Z:
        // key equivalents reach them through a main menu, so it has an Edit menu nobody sees
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "ReDesk", action: nil, keyEquivalent: ""))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main

        windows = Self.pieces(wallpapers: wallpapers)
        // the wave at the bottom, between TERM and NOTE; only to look at, clicks go through
        let waveWindow = DeskWindow(view: wave) { l in
            let width = l.area.width * 0.24
            return NSRect(x: l.area.midX - width / 2, y: l.waveLine - 22, width: width, height: 44)
        }
        waveWindow.ignoresMouseEvents = true
        windows.append(waveWindow)

        layout()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(layout), name: .wallpapersListed, object: nil)
        // the side columns moved (⌃⌥- / ⌃⌥=): the desk laid out again, the windows tiled again
        NotificationCenter.default.addObserver(forName: SideMargin.changed, object: nil, queue: .main) { [weak self] _ in
            self?.placePieces()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: Language.changed, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(tick), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            wallpapers, selector: #selector(WallpaperView.changedElsewhere), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // a minute of the day is a few pixels at most
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        HotKeys.register()
        LockScreen.shared.start()
        Wallpapers.appearanceChanged()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in LiveWallpaper.shared.pause() }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in LiveWallpaper.shared.resume() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [wave] _ in wave.set(playing: othersPlaying()) }
        if Tiler.shared.on { Tiler.shared.start() }
        NotificationCenter.default.addObserver(forName: .arrangementChanged, object: nil, queue: .main) { [weak self] _ in
            self?.showPieces()
            self?.showBar()
        }
        InkCursors.apply()
        // the windows' corners marked with a +, if kept so (Plus.swift)
        PlusMarks.apply()
        // the Re apps' windows opening and closing, drawn under them (Opening.swift)
        Opening.listen()
        // a picture or a video added from ReFile (Edit › Add to wallpapers): among the wallpapers at once
        DistributedNotificationCenter.default().addObserver(forName: .init("com.artursavytskyi.redesk.wallpapers"), object: nil, queue: .main) { _ in
            Wallpapers.reload()
        }
        // light ink at night: the cursors follow the appearance. The app's own appearance turns the
        // moment the Mac's does, together with the other apps; the notice is a second way to hear of it.
        night = Appearance.dark
        appearanceWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.appearanceTurned() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.appearanceTurned()
        }
        CommandKeys.install()
        LidLight.shared.start()
        // each time ReDesk starts: the guide
        GuidePopup.whenStarting()
        Desktops.shared.start()
    }

    private var night = false
    private var appearanceWatch: NSKeyValueObservation?

    /// The Mac turned light or dark (heard once, however it is told).
    private func appearanceTurned() {
        guard Appearance.dark != night else { return }
        night = Appearance.dark
        InkCursors.apply()
        // the other folder's wallpapers: another one on the desktop, another column of dots
        Wallpapers.appearanceChanged()
        layout()
        // the ink turns with it (where there's no wallpaper to look at)
        allPieces.forEach { $0.redrawFading() }
        stripWindow.redrawFading()
        // an open popup turns with it
        for popup in [SettingsPopup.shared, KeysPopup.shared] as [Popup] where popup.isVisible { popup.refresh() }
        NotificationCenter.default.post(name: .wallpaperChanged, object: nil)
    }

    @objc private func tick() {
        day.needsDisplay = true
    }

    /// the corner words (and the apps across the top) in the other language: their columns as long as the new words
    @objc private func languageChanged() {
        layout()
        redrawWords()
        // the letters turn over one after another, as on a departures board
        Flap.start { [weak self] in self?.redrawWords() }
    }

    private func redrawWords() {
        allPieces.forEach { $0.contentView?.subviews.forEach { $0.needsDisplay = true }; $0.contentView?.needsDisplay = true }
        stripWindow.contentView?.needsDisplay = true
        AppMenuBar.shared.redraw()
    }

    /// The desk's words and dashes for one screen: the four corner words, the wallpapers on the right edge,
    /// the desktops on the left.
    private static func pieces(wallpapers: WallpaperView) -> [DeskWindow] {
        var pieces = corners.map { corner in
            DeskWindow(view: WordView(corner: corner)) { l in
                let height = CGFloat(corner.word.count) * letterStep
                let x = (corner.left ? l.leftX : l.rightX) - columnWidth / 2
                let y = corner.top ? l.topWord - height : l.bottomWord
                return NSRect(x: x, y: y, width: columnWidth, height: height)
            }
        }
        // the wallpapers on the right edge, around its middle, as the desktops on the left
        pieces.append(DeskWindow(view: wallpapers) { l in
            let height = WallpaperView.spacing * CGFloat(max(Wallpapers.all.count, 1) + 1)
            return NSRect(x: l.rightX - columnWidth / 2, y: l.area.midY - height / 2, width: columnWidth, height: height)
        })
        // the desktops on the left edge, around its middle (room for eight)
        pieces.append(DeskWindow(view: DesktopsView()) { l in
            let height = DesktopsView.spacing * 8
            return NSRect(x: l.leftX - columnWidth / 2, y: l.area.midY - height / 2, width: columnWidth, height: height)
        })
        return pieces
    }

    /// The same words and dashes on every other screen (an external display), one set each.
    private var others: [[DeskWindow]] = []
    /// the screens they stand on, by number
    private var otherScreens: [CGDirectDisplayID] = []
    /// a layout again once the screens have settled: asked for, and being done
    private var settleAsked = false
    private var settlingNow = false
    /// every piece of the desk, on all the screens
    private var allPieces: [DeskWindow] { windows + others.flatMap { $0 } }

    @objc private func layout() {
        guard let screen = NSScreen.screens.first else { return }
        windows.forEach { $0.place(on: screen) }
        let extra = Array(NSScreen.screens.dropFirst())
        let ids = extra.map { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
        if ids != otherScreens {
            // other screens than before (the lid shut on a display, the cable out): their sets made anew
            others.flatMap { $0 }.forEach { $0.orderOut(nil) }
            others = extra.map { _ in Self.pieces(wallpapers: WallpaperView(mirror: true)) }
            otherScreens = ids
        }
        for (set, screen) in zip(others, extra) { set.forEach { $0.place(on: screen) } }
        showPieces(animated: false)
        LiveWallpaper.shared.layout()
        WallpaperBlur.refresh()
        Tiler.shared.retile()
        showBar()
    }

    /// Only the desk's words and dashes put in their places again, and the windows tiled again (the side
    /// columns moved): the wallpaper, a film perhaps, left playing as it is.
    private func placePieces() {
        if let screen = NSScreen.screens.first { windows.forEach { $0.place(on: screen) } }
        for (set, screen) in zip(others, NSScreen.screens.dropFirst()) { set.forEach { $0.place(on: screen) } }
        Tiler.shared.retile()
    }

    /// The screens changed (a display plugged in or out, the lid shut on one): laid out now, and again once
    /// they have settled, since they tell of a change while it is still under way.
    @objc private func screensChanged() {
        layout()
        if !settlingNow && !settleAsked {
            settleAsked = true
            for delay in [0.8, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    self.settlingNow = true
                    self.layout()
                    self.settlingNow = false
                    if delay > 1 { self.settleAsked = false }
                }
            }
        }
    }

    /// The desk's own pieces (the corner words, the dots, the day line, the wave): gone in
    /// Almost Full, where only the apps across the top stay; they fade out and back.
    private func showPieces(animated: Bool = true) {
        let hidden = Tiler.shared.on && Tiler.shared.almostFull
        for window in allPieces {
            let alpha: CGFloat = hidden ? 0 : 1
            window.ignoresMouseEvents = hidden || window.contentView === wave
            guard window.alphaValue != alpha else { continue }
            if animated {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.25; window.animator().alphaValue = alpha }
            } else {
                window.alphaValue = alpha
            }
        }
    }

    /// The apps across the top: only while the windows are in Full Screen or Almost Full. In the menu bar while it stays,
    /// on the desk in its strip while it hides.
    private func showBar() {
        let full = Tiler.shared.showsApps
        AppMenuBar.shared.shown = full && !menuBarHides
        // the other screens: the words across their top where they have no menu bar showing them
        let extra = Array(NSScreen.screens.dropFirst())
        while otherStrips.count < extra.count { otherStrips.append(DeskWindow(view: AppStripView()) { l in l.area }) }
        for (i, window) in otherStrips.enumerated() {
            guard i < extra.count, full else { window.orderOut(nil); continue }
            let screen = extra[i]
            let room = appStripRoom(screen)
            let menu = screen.frame.maxY - screen.visibleFrame.maxY
            // its own (hidden) menu bar's place, or a band of that height at its top
            let height = room > 0 ? room : (menuBarHides ? menu : 0)
            guard height > 0 else { window.orderOut(nil); continue }
            window.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height), display: true)
            window.orderFront(nil)
        }
        guard full && menuBarHides, let screen = NSScreen.screens.first, screen.frame.maxY > screen.visibleFrame.maxY else {
            return stripWindow.orderOut(nil)
        }
        let frame = NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY,
                           width: screen.frame.width, height: screen.frame.maxY - screen.visibleFrame.maxY)
        stripWindow.setFrame(frame, display: true)
        stripWindow.orderFront(nil)
    }
}

// ReDesk --render-lock <file.png>: the lock screen's face, its password box open with a few letters in, drawn
// into a picture (to look at it); no desk, nothing locked
if let at = CommandLine.arguments.firstIndex(of: "--render-lock"), at + 1 < CommandLine.arguments.count {
    let out = URL(fileURLWithPath: CommandLine.arguments[at + 1])
    _ = NSApplication.shared
    _ = letterFont
    let frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
    let window = LockWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    let container = NSView(frame: frame)
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor(calibratedRed: 0.32, green: 0.3, blue: 0.27, alpha: 1).cgColor
    let face = LockFace(frame: frame, main: true)
    container.addSubview(face)
    window.contentView = container
    window.orderFrontRegardless()
    window.level = .screenSaver
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    face.openField(with: "")
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    // typed as a person types: through the field's editor, a letter at a time
    for ch in "secret1" {
        (face.field?.currentEditor() as? NSTextView)?.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    // as the window server shows it (the glass composited), beside the view's own drawing
    if let shot = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) {
        let rep = NSBitmapImageRep(cgImage: shot)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.deletingPathExtension().appendingPathExtension("screen.png"))
    }
    container.layoutSubtreeIfNeeded()
    container.displayIfNeeded()
    if let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) {
        container.cacheDisplay(in: container.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out)
    }
    exit(0)
}

// ReDesk --render-popups <folder>: the two popups drawn into PNGs there (to look at them); no desk
if let at = CommandLine.arguments.firstIndex(of: "--render-popups"), at + 1 < CommandLine.arguments.count {
    let folder = URL(fileURLWithPath: CommandLine.arguments[at + 1])
    _ = NSApplication.shared
    _ = letterFont
    if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
    if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
    let suffix = Appearance.dark ? "-dark" : "-light"
    func render(_ popup: Popup, _ name: String) {
        popup.refresh()
        guard let view = popup.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()
        view.bounds.fill()
        image.unlockFocus()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let back = NSImage(size: view.bounds.size)
        back.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        back.unlockFocus()
        if let tiff = back.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent(name))
        }
    }
    render(SettingsPopup.shared, "settings\(suffix).png")
    render(KeysPopup.shared, "keys\(suffix).png")
    GuidePopup.shared.render { render(GuidePopup.shared, String(format: "guide-%02d\(suffix).png", $0 + 1)) }
    // the dashboard with a few seconds of what it reads
    DashboardPopup.shared.warmUp()
    render(DashboardPopup.shared, "dashboard\(suffix).png")
    // the corner words, side by side, on the dark
    let columns = corners.map { corner -> NSView in
        let view = WordView(corner: corner)
        view.frame = NSRect(x: 0, y: 0, width: columnWidth, height: CGFloat(corner.word.count) * letterStep)
        return view
    }
    let height = columns.map(\.frame.height).max() ?? 0
    let board = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(columns.count) * (columnWidth + 20) + 20, height: height + 40))
    for (i, view) in columns.enumerated() {
        view.frame.origin = NSPoint(x: 20 + CGFloat(i) * (columnWidth + 20), y: 20 + height - view.frame.height)
        board.addSubview(view)
    }
    do {
        let back = NSImage(size: board.bounds.size)
        back.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()
        board.bounds.fill()
        for view in columns {
            NSGraphicsContext.current?.saveGraphicsState()
            let shift = NSAffineTransform()
            shift.translateX(by: view.frame.minX, yBy: view.frame.minY)
            shift.concat()
            view.draw(view.bounds)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        back.unlockFocus()
        if let tiff = back.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("words.png"))
        }
    }
    exit(0)
}

let app = NSApplication.shared
let desk = Desk()
app.delegate = desk
app.setActivationPolicy(.accessory)
app.run()
