// ReDesk: the Re apps and a few quiet gauges on the desktop.
// Corners: the apps as words (a click opens one). Left edge: the wallpapers, pictures and videos, as dots
// (wallpapers/Light or wallpapers/Dark, as the Mac's appearance is).
// Top: the day. Right edge: the battery. Bottom: a wave while sound plays.
// Tiling (optional): the Re apps' windows share the middle of the desk, between the gauges.
// Keys: ⌃⌥ arrows move the focus between windows (anywhere); in the Re apps ⌘⇧↑/↓ step the wallpapers,
// ⌘↑ makes a window fill the screen, ⌘↓ the desk's middle (tiling stops), ⌘1…⌘7 pick an arrangement;
// ⌘⇧T switches the Mac between light and dark (anywhere).
// Each piece is a small borderless window just above the desktop icons;
// a right click on any of them can open ReDesk at login or quit it.
import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import ImageIO
import IOKit.ps
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

/// The desk's ink: white in a dark appearance, a near black in a light one, as see-through either way.
/// Resolved at each drawing by the window's appearance, which each piece takes from the wallpaper
/// behind it (DeskWindow.adaptInk), or else from the Mac.
func ink(_ alpha: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        let night = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (night ? NSColor.white : NSColor(white: 0.08, alpha: 1)).withAlphaComponent(alpha)
    }
}

/// Gauges: the empty part at 25%, the filled part (and the chosen wallpaper) at 50%.
let faint = ink(0.25)
let strong = ink(0.5)
/// the day's "now": a soft grey-green, darker by day
let nowInk = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0xAD / 255, green: 0xB5 / 255, blue: 0xB4 / 255, alpha: 1)
        : NSColor(srgbRed: 0x4F / 255, green: 0x57 / 255, blue: 0x56 / 255, alpha: 1)
}
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

struct Layout {
    let area: NSRect

    var leftX: CGFloat { area.minX + area.width * 0.05 }
    var rightX: CGFloat { area.maxX - area.width * 0.05 }
    var topWord: CGFloat { area.maxY - area.height * 0.0625 }
    var bottomWord: CGFloat { area.minY + area.height * 0.0625 }
    /// the dots on the left and the battery on the right share this length, around the middle
    var sideLength: CGFloat { area.height * 0.22 }
    /// the day line: a little under halfway between the top of the screen and the tops of FILE and SURF
    var dayLine: CGFloat { topWord + (area.maxY - topWord) * 0.35 - 8 }
    /// the wave: the day line's twin at the bottom
    var waveLine: CGFloat { bottomWord - (bottomWord - area.minY) * 0.35 + 8 }
    /// where tiled windows go: between the side columns, 40pt under the day line and over the wave
    var tiles: NSRect {
        NSRect(x: leftX + 56, y: waveLine + 40, width: rightX - leftX - 112, height: dayLine - waveLine - 80)
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

    /// The wallpapers of the appearance the Mac is in (the other folder's while this one is empty).
    static var all: [URL] {
        let (mine, other) = Appearance.dark ? (dark, light) : (light, dark)
        return mine.isEmpty ? other : mine
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
/// It pauses while the displays sleep.
final class LiveWallpaper {
    static let shared = LiveWallpaper()

    private var player: AVQueuePlayer?
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
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        self.player = player
        layout()
        player.play()
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
        window.contentView?.layer?.sublayers?.lazy.compactMap { $0 as? AVPlayerLayer }.first
    }

    /// the new video has its first frame on every screen
    var ready: Bool {
        windows.allSatisfy { videoLayer(of: $0)?.isReadyForDisplay ?? true }
    }

    /// the video's still lies under it on every screen: the new wallpaper shows before the video plays
    var stillShown: Bool {
        !windows.isEmpty && windows.allSatisfy { $0.contentView?.layer?.contents != nil }
    }

    func pause() { player?.pause() }
    func resume() { player?.play() }

    func layout() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
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
            if let url, let still = Crossfade.picture(Wallpapers.still(of: url), for: screen) {
                base.contents = still
                base.contentsGravity = .resizeAspectFill
                base.masksToBounds = true
            }
            let video = AVPlayerLayer(player: player)
            video.videoGravity = .resizeAspectFill
            video.frame = base.bounds
            video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            base.addSublayer(video)
            view.layer = base
            view.wantsLayer = true
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFront(nil)
            return window
        }
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
                  let image = picture(url, for: screen) else { return nil }
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

    /// Fades the old wallpaper away once the new one shows: at once over a video's still (its first
    /// frame, under the video until it plays), else once the video's first frame is there (or a second
    /// and a half has gone); a picture has a moment to be drawn by macOS.
    static func lift(_ windows: [NSWindow], keeping video: [AnyObject] = [], over duration: Double = duration, waited: Double = 0) {
        guard !windows.isEmpty else { return }
        let shown = LiveWallpaper.shared.url == nil ? waited >= 0.2 : (LiveWallpaper.shared.stillShown || LiveWallpaper.shared.ready)
        if waited < 1.5 && !shown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                lift(windows, keeping: video, over: duration, waited: waited + 0.05)
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
}

/// From anywhere (Carbon hot keys need no permissions): ⌃⌥ arrows move the focus between windows,
/// ⌃⌥T turns tiling on and off, ⌃⌥Space goes to the next arrangement (⌘1…⌘7 pick one: CommandKeys),
/// ⌃⌥↩ makes the focused window the main one, ⌃⌥⇧ arrows move it to its neighbour's place.
/// ⌘⇧T switches the Mac between light and dark.
enum HotKeys {
    private static var refs: [EventHotKeyRef?] = []
    private static let keys: [(id: UInt32, key: Int)] = [
        (1, kVK_UpArrow), (2, kVK_DownArrow), (3, kVK_ANSI_T), (4, kVK_Return), (5, kVK_Space), (6, kVK_LeftArrow), (7, kVK_RightArrow),
    ]
    /// with ⇧ as well
    private static let shifted: [(id: UInt32, key: Int)] = [
        (21, kVK_UpArrow), (22, kVK_DownArrow), (23, kVK_LeftArrow), (24, kVK_RightArrow),
    ]

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            switch id.id {
            case 1: Tiler.shared.focus(.up)
            case 2: Tiler.shared.focus(.down)
            case 3: Tiler.shared.on.toggle()
            case 4: Tiler.shared.promote()
            case 5: Tiler.shared.nextArrangement()
            case 6: Tiler.shared.focus(.left)
            case 7: Tiler.shared.focus(.right)
            case 21: Tiler.shared.move(.up)
            case 22: Tiler.shared.move(.down)
            case 23: Tiler.shared.move(.left)
            case 24: Tiler.shared.move(.right)
            case 31: Appearance.toggle()
            default: break
            }
            return noErr
        }, 1, &spec, nil, nil)
        let modifiers = UInt32(controlKey | optionKey)
        let all = keys.map { ($0.id, $0.key, modifiers) } + shifted.map { ($0.id, $0.key, modifiers | UInt32(shiftKey)) }
            + [(UInt32(31), kVK_ANSI_T, UInt32(cmdKey | shiftKey))]
        for (number, key, mods) in all {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x5244_534B), id: number),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

/// ⌘ keys, only while one of the Re apps is in front (elsewhere they keep their usual meaning):
/// ⌘⇧↑ / ⌘⇧↓ wallpapers, ⌘↑ the window fills the screen, ⌘↓ the desk's middle, ⌘1…⌘7 an arrangement.
/// Taking a key away from an app needs an event tap, which needs the Accessibility permission.
enum CommandKeys {
    private static var tap: CFMachPort?

    /// Tries now and again later: the tap can only be made once the permission is given.
    static func install() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { install() }
            return
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = CommandKeys.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let action = CommandKeys.action(for: event) else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async(execute: action)
            return nil
        }, userInfo: nil) else { return }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    private static func action(for event: CGEvent) -> (() -> Void)? {
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        guard flags.contains(.maskCommand),
              tiledApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else { return nil }
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let arrow = key == kVK_UpArrow ? 1 : key == kVK_DownArrow ? -1 : 0
        if flags == [.maskCommand, .maskShift], arrow != 0 {
            return { Wallpapers.step(-arrow) }
        }
        guard flags == .maskCommand else { return nil }
        // ⌘1…⌘7: an arrangement (in the order of the right-click menu), tiling on
        if let number = digits.firstIndex(of: key), number < Arrangement.allCases.count {
            return { Tiler.shared.choose(Arrangement.allCases[number]) }
        }
        guard arrow != 0 else { return nil }
        return { Tiler.shared.resizeFocused(wholeScreen: arrow > 0) }
    }
}

// ── tiling: the Re apps' windows share the middle of the desk ──
// The windows keep an order, newest first; the arrangement decides where each one goes.
// Changes glide; a window dragged onto another's place swaps with it, anything else snaps back.
// Moving other apps' windows takes the Accessibility permission, asked for when tiling is turned on.

let tiledApps: Set<String> = Set(corners.map(\.bundle) + ["com.artursavytskyi.rebook"])
let tileGap: CGFloat = 10

/// An Accessibility window, comparable so the order can be kept between looks.
struct TiledWindow: Hashable {
    let element: AXUIElement
    static func == (a: Self, b: Self) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// `count` equal slices of `r` side by side, `tileGap` apart.
func sideBySide(_ r: NSRect, _ count: Int) -> [NSRect] {
    let width = (r.width - tileGap * CGFloat(count - 1)) / CGFloat(count)
    return (0 ..< count).map { i in
        NSRect(x: r.minX + CGFloat(i) * (width + tileGap), y: r.minY, width: width, height: r.height)
    }
}

/// `count` equal slices of `r` one above another, the top one first.
func stacked(_ r: NSRect, _ count: Int) -> [NSRect] {
    let height = (r.height - tileGap * CGFloat(count - 1)) / CGFloat(count)
    return (0 ..< count).map { i in
        NSRect(x: r.minX, y: r.maxY - CGFloat(i + 1) * height - CGFloat(i) * tileGap, width: r.width, height: height)
    }
}

/// Where the windows go; the first window is the main one.
enum Arrangement: String, CaseIterable {
    case main, mainTop, centre, columns, rows, grid, single

    var title: String {
        switch self {
        case .main: "Main and Stack"
        case .mainTop: "Main on Top"
        case .centre: "Main in the Middle"
        case .columns: "Columns"
        case .rows: "Rows"
        case .grid: "Grid"
        case .single: "One at a Time"
        }
    }

    func frames(count: Int, in area: NSRect) -> [NSRect] {
        guard count > 1 else { return count == 1 ? [area] : [] }
        let rest = count - 1
        switch self {
        case .main:
            // the main one on the left half, the others one above another on the right
            let halves = sideBySide(area, 2)
            return [halves[0]] + stacked(halves[1], rest)
        case .mainTop:
            // the main one across the top 60%, the others side by side under it
            let mainHeight = (area.height - tileGap) * 0.6
            let top = NSRect(x: area.minX, y: area.maxY - mainHeight, width: area.width, height: mainHeight)
            let bottom = NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height - mainHeight - tileGap)
            return [top] + sideBySide(bottom, rest)
        case .centre:
            // the main one in the middle half, the others shared out to the left and the right
            guard count > 2 else { return sideBySide(area, 2) }
            let side = (area.width - tileGap * 2) * 0.25
            let left = NSRect(x: area.minX, y: area.minY, width: side, height: area.height)
            let middle = NSRect(x: left.maxX + tileGap, y: area.minY, width: area.width - 2 * (side + tileGap), height: area.height)
            let right = NSRect(x: middle.maxX + tileGap, y: area.minY, width: side, height: area.height)
            let rightCount = rest / 2, leftCount = rest - rightCount
            let l = stacked(left, leftCount), r = stacked(right, rightCount)
            // alternating left and right, so a new window lands on the side with fewer
            let sides: [NSRect] = (0 ..< rest).map { i in i % 2 == 0 ? l[i / 2] : r[i / 2] }
            return [middle] + sides
        case .columns:
            return sideBySide(area, count)
        case .rows:
            return stacked(area, count)
        case .grid:
            // as square as it gets; a short last row is spread across the width
            let across = Int(Double(count).squareRoot().rounded(.up))
            let down = (count + across - 1) / across
            return stacked(area, down).enumerated().flatMap { row, strip in
                sideBySide(strip, min(across, count - row * across))
            }
        case .single:
            // every window fills the area; the focused one is on top
            return Array(repeating: area, count: count)
        }
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
        }
    }

    var arrangement = Arrangement(rawValue: UserDefaults.standard.string(forKey: "arrangement") ?? "") ?? .main {
        didSet {
            UserDefaults.standard.set(arrangement.rawValue, forKey: "arrangement")
            retile()
        }
    }

    /// the windows, main first; `slots[i]` is where `order[i]` belongs
    private var order: [TiledWindow] = []
    private var slots: [NSRect] = []
    /// where each window really ended up (a window may keep a size of its own), to tell when it is moved
    private var settled: [TiledWindow: NSRect] = [:]

    private var timer: Timer?
    private var ticks = 0
    private var pressed = false
    private var dragged: Int?
    private let overlay = DropOverlay()

    private struct Move { let window: TiledWindow; let from: NSRect; let to: NSRect }
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
        let kept = order.filter(open.contains)
        let added = open.filter { !kept.contains($0) }
        if added.count > 0 || kept.count != order.count {
            order = added + kept
            retile()
        } else {
            // moved without the mouse (the keyboard, the app itself): back to its place
            released(at: nil)
        }
    }

    private func openWindows() -> [TiledWindow] {
        NSWorkspace.shared.runningApplications
            .filter { tiledApps.contains($0.bundleIdentifier ?? "") && !$0.isHidden }
            .flatMap { app -> [TiledWindow] in
                let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
                return windows
                    .filter { w in
                        attribute(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
                            && attribute(w, kAXMinimizedAttribute) as? Bool != true
                            && attribute(w, "AXFullScreen") as? Bool != true
                    }
                    .map(TiledWindow.init)
            }
    }

    /// The window whose top left left its place, if any.
    private func movedWindow() -> (index: Int, frame: NSRect)? {
        for (i, window) in order.enumerated() {
            guard let now = frame(of: window.element), let was = settled[window] else { continue }
            if abs(now.minX - was.minX) > 4 || abs(now.maxY - was.maxY) > 4 { return (i, now) }
        }
        return nil
    }

    /// While the mouse is down: show where a dragged window would go.
    private func dragging() {
        guard animation == nil, order.count > 1, arrangement != .single else { return }
        if dragged == nil { dragged = movedWindow()?.index }
        guard let dragged else { return }
        let point = NSEvent.mouseLocation
        if let target = slots.firstIndex(where: { $0.contains(point) }), target != dragged {
            overlay.show(slots[target])
        } else {
            overlay.hide()
        }
    }

    /// The mouse is up (or something moved a window): a window dropped on another's place swaps with it;
    /// anything moved or resized goes back to its place.
    private func released(at point: NSPoint?) {
        overlay.hide()
        dragged = nil
        guard on, animation == nil else { return }
        if let moved = movedWindow() {
            let drop = point ?? NSPoint(x: moved.frame.midX, y: moved.frame.midY)
            if arrangement != .single, let target = slots.firstIndex(where: { $0.contains(drop) }), target != moved.index {
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

    func retile() {
        guard on, AXIsProcessTrusted(), let screen = NSScreen.screens.first else { return }
        slots = arrangement.frames(count: order.count, in: Layout(area: screen.visibleFrame).tiles).map(\.integral)
        let moves = zip(order, slots).compactMap { window, to in
            frame(of: window.element).map { Move(window: window, from: $0, to: to) }
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

    /// The window that has the keyboard, if it is one of the Re apps'.
    private func focusedWindow() -> TiledWindow? {
        guard let app = attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              let focused = attribute(app as! AXUIElement, kAXFocusedWindowAttribute) else { return nil }
        let window = TiledWindow(element: focused as! AXUIElement)
        return openWindows().contains(window) ? window : nil
    }

    /// ⌃⌥ arrows: the focus goes to the nearest window that way. In One at a Time (all in one place)
    /// ← / ↑ and → / ↓ go back and forth through them.
    func focus(_ direction: Direction) {
        guard AXIsProcessTrusted() else { return Tiler.openAccessibilitySettings() }
        let windows = on && !order.isEmpty ? order : openWindows()
        guard let current = focusedWindow() ?? windows.first, windows.count > 1,
              let target = neighbour(of: current, among: windows, toward: direction) else { return }
        raise(target)
    }

    /// ⌃⌥⇧ arrows: the focused window trades places with the nearest one that way, and keeps the focus.
    /// In One at a Time it moves back or forth in the turn.
    func move(_ direction: Direction) {
        guard on, AXIsProcessTrusted(), let current = focusedWindow(),
              let at = order.firstIndex(of: current),
              let target = neighbour(of: current, among: order, toward: direction),
              let to = order.firstIndex(of: target) else { return }
        order.swapAt(at, to)
        retile()
    }

    /// Where a window belongs while tiling (it may still be gliding there), otherwise where it is.
    private func place(of window: TiledWindow) -> NSRect? {
        if on, slots.count == order.count, let at = order.firstIndex(of: window) { return slots[at] }
        return frame(of: window.element)
    }

    private func neighbour(of current: TiledWindow, among windows: [TiledWindow], toward direction: Direction) -> TiledWindow? {
        let target: TiledWindow?
        if on && arrangement == .single, let at = windows.firstIndex(of: current) {
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
        let to = wholeScreen ? screen.visibleFrame : Layout(area: screen.visibleFrame).tiles.integral
        guard let from = frame(of: window.element) else { return }
        animate([Move(window: window, from: from, to: to)])
    }

    /// ⌘1…⌘7 (in the Re apps): this arrangement, with tiling on.
    func choose(_ arrangement: Arrangement) {
        self.arrangement = arrangement
        on = true
    }

    /// The focused window becomes the main one.
    func promote() {
        guard on, let app = attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
              let focused = attribute(app as! AXUIElement, kAXFocusedWindowAttribute) else { return }
        let window = TiledWindow(element: focused as! AXUIElement)
        guard let at = order.firstIndex(of: window), at > 0 else { return }
        order.remove(at: at)
        order.insert(window, at: 0)
        retile()
    }
}

// ── the Mac's appearance and cursors ──

/// ⌘⇧T: the Mac between light and dark. System Events does it, so macOS asks once whether ReDesk may.
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

/// The Re apps' ink cursors for every app on the Mac: the arrow, the I-beam and the pointing hand drawn
/// with a brush (light ink while the Mac is dark). They stay until ReDesk quits or they are turned off
/// (right click › Ink Cursors); then the Mac's own come back.
enum InkCursors {
    private struct Shape {
        let names: [String]
        let day: String
        let night: String
        /// the point that clicks, in a 20 × 20 cursor
        let hotspot: CGPoint
    }

    // since macOS 26 the arrow and the I-beam are drawn from the …S names; the old ones are still
    // accepted, without effect (Mousecape PR #308)
    private static let shapes = [
        Shape(names: ["com.apple.coregraphics.ArrowS", "com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowCtx"],
              day: "cursor-arrow", night: "cursor-arrow-night", hotspot: CGPoint(x: 1, y: 1)),
        Shape(names: ["com.apple.coregraphics.IBeamS", "com.apple.coregraphics.IBeam", "com.apple.coregraphics.IBeamXOR"],
              day: "cursor-ibeam", night: "cursor-ibeam-night", hotspot: CGPoint(x: 10, y: 10)),
        // the hand has a white body inside its outline: it reads on both
        Shape(names: ["com.apple.cursor.13"], day: "cursor-hand", night: "cursor-hand", hotspot: CGPoint(x: 6.5, y: 1)),
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
        let night = Appearance.dark
        for shape in shapes {
            guard let images = images(night ? shape.night : shape.day) else { continue }
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

    /// The picture at each scale the screen may want (1×, 2×, 3×, 4×).
    private static func images(_ name: String) -> [CGImage]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (1...4).compactMap { scale in
            let side = Int(size.width) * scale
            guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
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

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let own = menuItems()
        own.forEach(menu.addItem)
        if !own.isEmpty { menu.addItem(.separator()) }
        let tiling = menu.addItem(withTitle: "Tile Windows", action: #selector(toggleTiling), keyEquivalent: "")
        tiling.target = self
        tiling.state = Tiler.shared.on ? .on : .off
        if Tiler.shared.on && !AXIsProcessTrusted() {
            let allow = menu.addItem(withTitle: "Allow in Accessibility…", action: #selector(allowAccessibility), keyEquivalent: "")
            allow.target = self
            allow.indentationLevel = 1
        }
        for arrangement in Arrangement.allCases {
            let number = Arrangement.allCases.firstIndex(of: arrangement)! + 1
            let item = menu.addItem(withTitle: arrangement.title, action: #selector(arrange(_:)), keyEquivalent: "\(number)")
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.representedObject = arrangement.rawValue
            item.indentationLevel = 1
            item.state = Tiler.shared.on && Tiler.shared.arrangement == arrangement ? .on : .off
        }
        menu.addItem(.separator())
        let cursors = menu.addItem(withTitle: "Ink Cursors", action: #selector(toggleCursors), keyEquivalent: "")
        cursors.target = self
        cursors.state = InkCursors.on ? .on : .off
        let theme = menu.addItem(withTitle: "Dark Appearance", action: #selector(toggleAppearance), keyEquivalent: "t")
        theme.keyEquivalentModifierMask = [.command, .shift]
        theme.target = self
        theme.state = Appearance.dark ? .on : .off
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit ReDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleTiling() { Tiler.shared.on.toggle() }

    @objc private func toggleCursors() { InkCursors.on.toggle() }

    @objc private func toggleAppearance() { Appearance.toggle() }

    @objc private func allowAccessibility() { Tiler.openAccessibilitySettings() }

    /// Picking an arrangement also turns tiling on.
    @objc private func arrange(_ item: NSMenuItem) {
        guard let arrangement = Arrangement(rawValue: item.representedObject as? String ?? "") else { return }
        Tiler.shared.choose(arrangement)
    }

    /// Starting with the Mac is up to the user; macOS may ask to approve it in Login Items.
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

final class WordView: DeskView {
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

    override func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Open \(corner.app)", action: #selector(openApp), keyEquivalent: "")
        item.target = self
        return [item]
    }

    @objc private func openApp() { open(corner) }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: letterFont,
            .foregroundColor: ink(hovered ? 0.95 : 0.5),
        ]
        for (i, letter) in corner.word.enumerated() {
            let text = NSAttributedString(string: String(letter), attributes: attributes)
            let size = text.size()
            let y = bounds.maxY - CGFloat(i + 1) * letterStep + (letterStep - size.height) / 2
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y))
        }
    }
}

/// The wallpapers as dots down the left edge; the one on the desktop is a diamond.
final class WallpaperView: DeskView {
    static let dot: CGFloat = 6

    /// distance between dots, top to bottom
    var spacing: CGFloat = 52

    private var chosen = Wallpapers.current

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .wallpaperChanged, object: nil)
        // the wallpaper can also change in System Settings
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changedElsewhere), name: Notification.Name("com.apple.desktop"), object: nil)
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

    private func centre(_ i: Int) -> NSPoint {
        let first = bounds.midY + spacing * CGFloat(Wallpapers.all.count - 1) / 2
        return NSPoint(x: bounds.midX, y: first - spacing * CGFloat(i))
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        let nearest = Wallpapers.all.indices.min { abs(centre($0).y - y) < abs(centre($1).y - y) }
        if let nearest, abs(centre(nearest).y - y) <= spacing / 2 { Wallpapers.show(nearest) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in Wallpapers.all.indices {
            let c = centre(i)
            if i == chosen {
                drawDiamond(at: c)
            } else {
                let r = Self.dot / 2
                faint.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: Self.dot, height: Self.dot)).fill()
            }
        }
    }
}

let diamondSize: CGFloat = 13

/// The mark for "this one" (the strong ink) or "now" (solid grey-green).
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
        drawDiamond(at: NSPoint(x: r + (bounds.width - diamondSize) * CGFloat(gone), y: bounds.midY), color: nowInk)
    }

    override func menuItems() -> [NSMenuItem] {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        return [NSMenuItem(title: time, action: nil, keyEquivalent: "")]
    }
}

/// The battery, filling from the bottom.
final class BatteryView: DeskView {
    var level = batteryLevel()

    override func draw(_ dirtyRect: NSRect) {
        guard let level else { return }
        drawBar(in: NSRect(x: bounds.midX - barWidth / 2, y: 0, width: barWidth, height: bounds.height), filled: level, vertical: true)
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
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
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

/// How light the wallpaper is behind each piece of the desk, which decides its ink: white over a dark
/// part of it, near black over a light one. A video is judged by its still (the macOS wallpaper under it).
enum Backdrop {
    private static var small: (url: URL, image: CGImage)?

    /// the desktop picture, a few hundred pixels wide
    private static func image(on screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let small, small.url == url { return small.image }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        small = (url, image)
        return image
    }

    /// 0 (black) … 1 (white): the wallpaper's average behind `frame` (screen coordinates), or nil
    /// while there is no picture to look at.
    static func lightness(behind frame: NSRect, on screen: NSScreen) -> CGFloat? {
        guard let image = image(on: screen) else { return nil }
        let s = screen.frame
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        // the picture fills the screen, cut evenly at the sides that stick out (as wallpapers are shown)
        let scale = max(s.width / w, s.height / h)
        let cutX = (w * scale - s.width) / 2, cutY = (h * scale - s.height) / 2
        // screen points (from the bottom) → the picture's pixels (from the top)
        let rect = CGRect(x: (frame.minX - s.minX + cutX) / scale, y: (s.maxY - frame.maxY + cutY) / scale,
                          width: frame.width / scale, height: frame.height / scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isEmpty, let part = image.cropping(to: rect) else { return nil }
        // averaged by drawing it small
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum: CGFloat = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.2126 * CGFloat(pixels[i]) + 0.7152 * CGFloat(pixels[i + 1]) + 0.0722 * CGFloat(pixels[i + 2])
        }
        return sum / CGFloat(side * side) / 255
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
        setFrame(frameOn(Layout(area: screen.visibleFrame)).integral, display: true)
        orderFront(nil)
        adaptInk(on: screen)
    }

    /// White ink over a dark part of the wallpaper, near black over a light one (ink(_:) resolves by
    /// the window's appearance); the Mac's appearance decides while there is no picture to look at.
    func adaptInk(on screen: NSScreen) {
        // a margin round the piece: its letters are seen against what is around them too
        let lightness = Backdrop.lightness(behind: frame.insetBy(dx: -16, dy: -16), on: screen)
        let ink = lightness.map { NSAppearance(named: $0 < 0.55 ? .darkAqua : .aqua) } ?? nil
        if ink?.name != appearance?.name {
            appearance = ink
            redrawFading()
        } else {
            contentView?.needsDisplay = true
        }
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

final class Desk: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        InkCursors.restore()
    }

    private let wallpapers = WallpaperView()
    private let day = DayView()
    private let battery = BatteryView()
    private let wave = WaveView()
    private var windows: [DeskWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        windows = corners.map { corner in
            DeskWindow(view: WordView(corner: corner)) { l in
                let height = CGFloat(corner.word.count) * letterStep
                let x = (corner.left ? l.leftX : l.rightX) - columnWidth / 2
                let y = corner.top ? l.topWord - height : l.bottomWord
                return NSRect(x: x, y: y, width: columnWidth, height: height)
            }
        }
        windows.append(DeskWindow(view: wallpapers) { [wallpapers] l in
            let count = CGFloat(max(Wallpapers.all.count - 1, 1))
            wallpapers.spacing = min(52, l.sideLength / count)
            let height = wallpapers.spacing * count + wallpapers.spacing
            return NSRect(x: l.leftX - columnWidth / 2, y: l.area.midY - height / 2, width: columnWidth, height: height)
        })
        windows.append(DeskWindow(view: day) { l in
            let width = l.area.width * 0.24
            return NSRect(x: l.area.midX - width / 2, y: l.dayLine - 9, width: width, height: 18)
        })
        windows.append(DeskWindow(view: battery) { l in
            NSRect(x: l.rightX - columnWidth / 2, y: l.area.midY - l.sideLength / 2, width: columnWidth, height: l.sideLength)
        })
        // the day line's twin at the bottom, between HEAR and NOTE; only to look at, clicks go through
        let waveWindow = DeskWindow(view: wave) { l in
            let width = l.area.width * 0.24
            return NSRect(x: l.area.midX - width / 2, y: l.waveLine - 22, width: width, height: 44)
        }
        waveWindow.ignoresMouseEvents = true
        windows.append(waveWindow)

        layout()
        NotificationCenter.default.addObserver(
            self, selector: #selector(layout), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(tick), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            wallpapers, selector: #selector(WallpaperView.changedElsewhere), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // a minute of the day is a few pixels at most; the battery moves slower still
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        HotKeys.register()
        Wallpapers.appearanceChanged()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in LiveWallpaper.shared.pause() }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in LiveWallpaper.shared.resume() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [wave] _ in wave.set(playing: othersPlaying()) }
        if Tiler.shared.on { Tiler.shared.start() }
        // another wallpaper: each piece looks at what is behind it now
        NotificationCenter.default.addObserver(forName: .wallpaperChanged, object: nil, queue: .main) { [weak self] _ in
            guard let screen = NSScreen.screens.first else { return }
            self?.windows.forEach { $0.adaptInk(on: screen) }
        }
        InkCursors.apply()
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
        windows.forEach { $0.redrawFading() }
        NotificationCenter.default.post(name: .wallpaperChanged, object: nil)
    }

    @objc private func tick() {
        day.needsDisplay = true
        battery.level = batteryLevel()
        battery.needsDisplay = true
    }

    @objc private func layout() {
        guard let screen = NSScreen.screens.first else { return }
        windows.forEach { $0.place(on: screen) }
        LiveWallpaper.shared.layout()
        Tiler.shared.retile()
    }
}

let app = NSApplication.shared
let desk = Desk()
app.delegate = desk
app.setActivationPolicy(.accessory)
app.run()
