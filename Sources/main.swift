// ReDesk: the Re apps and a few quiet gauges on the desktop.
// Corners: the apps as words (a click opens one). Left edge: the wallpapers, pictures and videos, as dots
// (wallpapers/Light or wallpapers/Dark, as the Mac's appearance is).
// Top: the day. Right edge: the battery. Bottom: a wave while sound plays.
// Tiling (optional): the Re apps' windows share the middle of the desk, between the gauges.
// Keys: ⌃⌥ arrows move the focus between windows (anywhere); in the Re apps ⌘⇧↑/↓ step the wallpapers,
// ⌘↑ makes a window fill the screen, ⌘↓ the desk's middle (tiling stops), ⌘1…⌘8 pick an arrangement;
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
import IOKit.pwr_mgt
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
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

    /// Videos from YouTube (YouTubeWallpaper), in Application Support/ReDesk/YouTube: in both appearances,
    /// after the folder's own, oldest first.
    static let youtubeFolder: URL = {
        let folder = stills.appendingPathComponent("YouTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    private(set) static var youtube = youtubeVideos()
    private static func youtubeVideos() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: youtubeFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        func made(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return files.filter { videos.contains($0.pathExtension.lowercased()) }.sorted { made($0) < made($1) }
    }
    /// Looks at the YouTube folder again (a video came or went), and lays the dots out again.
    static func reload() {
        youtube = youtubeVideos()
        NotificationCenter.default.post(name: .wallpapersListed, object: nil)
    }

    /// The wallpapers of the appearance the Mac is in (the other folder's while this one is empty),
    /// then those from YouTube.
    static var all: [URL] {
        let (mine, other) = Appearance.dark ? (dark, light) : (light, dark)
        return (mine.isEmpty ? other : mine) + youtube
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
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        self.player = player
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
    func resume() { if !frozen { player?.play() } }

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
    /// one more wallpaper, or one fewer: the dots are laid out again
    static let wallpapersListed = Notification.Name("ReDeskWallpapersListed")
    /// tiling turned on or off, or another arrangement
    static let arrangementChanged = Notification.Name("ReDeskArrangementChanged")
}

/// From anywhere (Carbon hot keys need no permissions): ⌃⌥ arrows move the focus between windows,
/// ⌃⌥T turns tiling on and off, ⌃⌥Space goes to the next arrangement (⌘1…⌘8 pick one: CommandKeys),
/// ⌃⌥↩ makes the focused window the main one, ⌃⌥⇧ arrows move it to its neighbour's place.
/// ⌘⇧T switches the Mac between light and dark.
enum HotKeys {
    private static var refs: [EventHotKeyRef?] = []
    private static let keys: [(id: UInt32, key: Int)] = [
        (1, kVK_UpArrow), (2, kVK_DownArrow), (3, kVK_ANSI_T), (4, kVK_Return), (5, kVK_Space), (6, kVK_LeftArrow), (7, kVK_RightArrow),
    ]
    /// with ⌘ as well
    private static let commanded: [(id: UInt32, key: Int)] = [
        (41, kVK_UpArrow), (42, kVK_DownArrow), (43, kVK_LeftArrow), (44, kVK_RightArrow),
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
            case 41: Tiler.shared.resize(.up)
            case 42: Tiler.shared.resize(.down)
            case 43: Tiler.shared.resize(.left)
            case 44: Tiler.shared.resize(.right)
            case 31: Appearance.toggle()
            case 32: LiveWallpaper.shared.frozen.toggle()
            case 33: LockScreen.shared.show()
            default: break
            }
            return noErr
        }, 1, &spec, nil, nil)
        let modifiers = UInt32(controlKey | optionKey)
        let all = keys.map { ($0.id, $0.key, modifiers) } + shifted.map { ($0.id, $0.key, modifiers | UInt32(shiftKey)) }
            + commanded.map { ($0.id, $0.key, modifiers | UInt32(cmdKey)) }
            + [(UInt32(31), kVK_ANSI_T, UInt32(cmdKey | shiftKey)), (UInt32(32), kVK_ANSI_M, UInt32(cmdKey | shiftKey)),
               (UInt32(33), kVK_ANSI_L, UInt32(cmdKey | controlKey))]
        for (number, key, mods) in all {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x5244_534B), id: number),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

/// ⌘ keys, only while one of the Re apps is in front (elsewhere they keep their usual meaning):
/// ⌘⇧↑ / ⌘⇧↓ wallpapers, ⌘↑ the window fills the screen, ⌘↓ the desk's middle, ⌘1…⌘8 an arrangement.
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
        // ⌘1…⌘8: an arrangement (in the order of the right-click menu), tiling on
        if let number = digits.firstIndex(of: key), number < Arrangement.allCases.count {
            return { Tiler.shared.choose(Arrangement.allCases[number]) }
        }
        guard arrow != 0 else { return nil }
        return { Tiler.shared.resizeFocused(wholeScreen: arrow > 0) }
    }
}

// ── tiling: the Re apps' windows share the middle of the desk ──
// The windows keep an order, newest first; the arrangement decides where each one goes.
// Changes glide; a window dragged onto another's place swaps with it. Pulling a window's edge moves the
// cut between it and its neighbour, which gives way as it goes; anything else snaps back.
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
    case main, mainTop, centre, columns, rows, grid, single, full

    var title: String {
        switch self {
        case .main: "Main and Stack"
        case .mainTop: "Main on Top"
        case .centre: "Main in the Middle"
        case .columns: "Columns"
        case .rows: "Rows"
        case .grid: "Grid"
        case .single: "One at a Time"
        case .full: "Full Screen"
        }
    }

    /// One at a Time and Full Screen: all the windows in one place, the focused one on top
    var stacks: Bool { self == .single || self == .full }

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
        case .columns:
            return even(all, across: true)
        case .rows:
            return even(all, across: false)
        case .grid:
            // as square as it gets; a short last row is spread across the width
            let across = Int(Double(count).squareRoot().rounded(.up))
            let rows = stride(from: 0, to: count, by: across).map { even(Array(all[$0 ..< min($0 + across, count)]), across: true) }
            return even(rows, across: false)
        case .single, .full:
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

    /// the windows, main first; `slots[i]` is where `order[i]` belongs
    private var order: [TiledWindow] = []
    /// every window still alive in its turn, also those out of sight for now (on another desktop, its app
    /// hidden), so one coming back takes its old place instead of the newest one's
    private var known: [TiledWindow] = []
    private var slots: [NSRect] = []
    /// where each window really ended up (a window may keep a size of its own), to tell when it is moved
    private var settled: [TiledWindow: NSRect] = [:]

    private var timer: Timer?
    private var ticks = 0
    private var pressed = false
    private var dragged: Int?
    /// the window being resized with the mouse
    private var resizing: Int?
    /// the shares the user gave the parts by resizing, per arrangement and number of windows
    private var shares: [String: Shares] = [:]
    private var sharesKey: String { "\(arrangement.rawValue) \(order.count)" }
    /// a part never gets smaller than this
    private let smallest: CGFloat = 240
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
        known = known.filter { open.contains($0) || alive($0) }
        known = open.filter { !known.contains($0) } + known
        let now = known.filter(open.contains)
        if now != order {
            order = now
            retile()
        } else {
            // moved without the mouse (the keyboard, the app itself): back to its place
            released(at: nil)
        }
    }

    /// Whether a window out of sight still exists (a closed one, or one whose app quit, doesn't).
    private func alive(_ window: TiledWindow) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &value)
        return error != .invalidUIElement && error != .cannotComplete
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
        guard animation == nil, order.count > 1, !arrangement.stacks else { return }
        if dragged == nil && resizing == nil {
            if let k = resizedWindow() { resizing = k } else { dragged = movedWindow()?.index }
        }
        if let resizing { return follow(resizing) }
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
        resizing = nil
        guard on, animation == nil else { return }
        if let moved = movedWindow() {
            let drop = point ?? NSPoint(x: moved.frame.midX, y: moved.frame.midY)
            if !arrangement.stacks, let target = slots.firstIndex(where: { $0.contains(drop) }), target != moved.index {
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

    /// Where the windows share: the desk's middle, or the whole screen in Full Screen.
    private func tilingArea() -> NSRect? {
        guard let screen = NSScreen.screens.first else { return nil }
        let layout = Layout(area: screen.visibleFrame)
        return arrangement == .full ? layout.area : layout.tiles
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

    /// ⌃⌥⌘ arrows: the border between the focused window and its neighbour moves that way by a step, so
    /// the window grows toward a neighbour and shrinks away from it, wherever it stands. The border is the
    /// one on the right (below), or the left (above) when there is no neighbour on the right (below).
    func resize(_ direction: Direction) {
        // no waiting for a glide to end: the places are where the windows are going, and a new glide starts
        // from wherever they are
        guard on, !arrangement.stacks, AXIsProcessTrusted(), let window = focusedWindow(),
              let k = order.firstIndex(of: window), slots.count == order.count else { return }
        let step: CGFloat = direction == .right || direction == .up ? 80 : -80
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
        guard k < order.count, slots.count == order.count, let area = tilingArea() else { return false }
        let slot = slots[k]
        var mine = shares[sharesKey] ?? [:]
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
        _ = find(arrangement.cut(count: order.count), area, "")
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
        if changed { shares[sharesKey] = mine }
        return changed
    }

    func retile() {
        guard on, AXIsProcessTrusted() else { return }
        remember()
        slots = places()
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

    /// ⌘1…⌘8 (in the Re apps): this arrangement, with tiling on.
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
        if let progress = YouTubeWallpaper.progress {
            let item = menu.addItem(withTitle: "YouTube: \(progress)", action: nil, keyEquivalent: "")
            item.isEnabled = false
        } else {
            let item = menu.addItem(withTitle: "Wallpaper from YouTube…", action: #selector(youtubeWallpaper), keyEquivalent: "")
            item.target = self
        }
        if let index = Wallpapers.current, Wallpapers.youtube.contains(Wallpapers.all[index]) {
            let item = menu.addItem(withTitle: "Remove This Wallpaper", action: #selector(removeWallpaper), keyEquivalent: "")
            item.target = self
        }
        let lock = menu.addItem(withTitle: "Lock Screen", action: #selector(lockScreen), keyEquivalent: "l")
        lock.keyEquivalentModifierMask = [.command, .control]
        lock.target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit ReDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleTiling() { Tiler.shared.on.toggle() }

    @objc private func lockScreen() { LockScreen.shared.show() }

    @objc private func youtubeWallpaper() { YouTubeWallpaper.ask() }

    @objc private func removeWallpaper() { YouTubeWallpaper.removeCurrent() }

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
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y))
        }
    }
}

/// Full Screen's way between the apps: FILE  SURF  HEAR  NOTE across the top of the screen, in the apps'
/// small letters (as their corner buttons in a small window); the app in front in full ink,
/// a click goes to one (or opens it). In the Mac's menu bar while it stays; where it hides (it comes
/// only when the mouse goes up), on the desk in its place (AppStripView), the menu bar coming over it.
var menuBarHides: Bool { UserDefaults.standard.bool(forKey: "_HIHideMenuBar") }

private let appWordFont = NSFont(name: "NotoSansJP-Regular", size: 15) ?? .systemFont(ofSize: 15, weight: .light)

func appWord(_ corner: Corner, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: corner.word, attributes: [.font: appWordFont, .kern: 0.4 * appWordFont.pointSize, .foregroundColor: color])
}

/// The words on the desk where the hidden menu bar would be, spread across the screen: the same space
/// between each two and at the ends, then each further from the middle: the outer two by 15%, the
/// inner two (SURF, HEAR) by 80%, which keeps the camera's notch well between them.
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

    @objc private func redraw() {
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



// ── wallpapers from YouTube ──
// A link pasted in (the right-click menu's Wallpaper from YouTube…): yt-dlp fetches its picture alone,
// no sound, in the best quality up to 4K; a video AVFoundation can't play here (VP9, AV1) is turned into
// HEVC by ffmpeg with the Mac's own encoder. It goes to Application Support/ReDesk/YouTube and onto the desk.
// yt-dlp and ffmpeg come from Homebrew (brew install yt-dlp ffmpeg).

enum YouTubeWallpaper {
    /// what the download is doing, for the menu; nil while there is none
    private(set) static var progress: String?

    private static let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    private static func tool(_ name: String) -> String? {
        paths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func looksLikeYouTube(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.hasPrefix("http") && (t.contains("youtube.com/") || t.contains("youtu.be/"))
    }

    /// Asks for the link, the clipboard's already in it when it is one.
    static func ask() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://www.youtube.com/watch?v=…"
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           looksLikeYouTube(clip) {
            field.stringValue = clip
        }
        let alert = NSAlert()
        alert.messageText = "Wallpaper from YouTube"
        alert.informativeText = "Paste a link: the video comes in its best quality, without sound."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let link = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeYouTube(link) else { return fail("That isn't a YouTube link.") }
        download(link)
    }

    private static func fail(_ message: String) {
        DispatchQueue.main.async {
            progress = nil
            let alert = NSAlert()
            alert.messageText = "No wallpaper from YouTube"
            alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Runs a tool, each line of its output handed to `line` as it comes; its status at the end.
    @discardableResult
    private static func run(_ path: String, _ arguments: [String], line: (String) -> Void = { _ in }) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (paths + [environment["PATH"] ?? ""]).joined(separator: ":")
        task.environment = environment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        guard (try? task.run()) != nil else { return (-1, "") }
        var all = "", pending = ""
        let handle = pipe.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            let text = String(decoding: data, as: UTF8.self)
            all += text
            pending += text
            // progress comes as lines (--newline) or carriage returns
            let parts = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            pending = parts.last ?? ""
            parts.dropLast().filter { !$0.isEmpty }.forEach(line)
        }
        task.waitUntilExit()
        return (task.terminationStatus, all)
    }

    private static func say(_ text: String) {
        DispatchQueue.main.async { progress = text }
    }

    static func download(_ link: String) {
        guard progress == nil else { return }
        guard let ytdlp = tool("yt-dlp"), let ffmpeg = tool("ffmpeg"), let ffprobe = tool("ffprobe") else {
            return fail("It takes yt-dlp and ffmpeg: brew install yt-dlp ffmpeg")
        }
        progress = "starting"
        DispatchQueue.global(qos: .userInitiated).async {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ReDesk-YouTube-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            // the picture alone, the best there is up to 4K (larger only costs, a screen shows no more)
            let fetched = run(ytdlp, ["-f", "bv*[height<=2160]/bv*", "--no-playlist", "--newline", "--no-part",
                                      "-o", work.appendingPathComponent("%(title).80B [%(id)s].%(ext)s").path, link]) { line in
                if line.hasPrefix("[download]"), let percent = line.split(separator: " ").first(where: { $0.hasSuffix("%") }) {
                    say("downloading \(percent)")
                }
            }
            let files = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
            guard fetched.status == 0, let source = files.first else {
                let reason = fetched.output.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init)
                return fail(reason ?? "yt-dlp couldn't get the video.")
            }
            let codec = run(ffprobe, ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name",
                                      "-of", "csv=p=0", source.path]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = source.deletingPathExtension().lastPathComponent + ".mp4"
            let out = work.appendingPathComponent("out.mp4")
            var arguments = ["-y", "-i", source.path, "-an", "-movflags", "+faststart"]
            if codec == "h264" {
                arguments += ["-c:v", "copy"]
            } else if codec == "hevc" {
                arguments += ["-c:v", "copy", "-tag:v", "hvc1"]
            } else {
                // VP9 or AV1: HEVC by the Mac's encoder, generous enough for 4K
                say("converting")
                arguments += ["-c:v", "hevc_videotoolbox", "-b:v", "24M", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
            }
            guard run(ffmpeg, arguments + [out.path]).status == 0 else { return fail("ffmpeg couldn't make it playable.") }
            let target = Wallpapers.youtubeFolder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            guard (try? FileManager.default.moveItem(at: out, to: target)) != nil else { return fail("It couldn't be kept.") }
            DispatchQueue.main.async {
                progress = nil
                Wallpapers.reload()
                if let index = Wallpapers.all.firstIndex(of: target) { Wallpapers.show(index) }
            }
        }
    }

    /// The YouTube video on the desk goes (its file and its still), and the desk takes the one before it.
    static func removeCurrent() {
        guard let index = Wallpapers.current else { return }
        let url = Wallpapers.all[index]
        guard Wallpapers.youtube.contains(url) else { return }
        let count = Wallpapers.all.count
        if count > 1 { Wallpapers.show(index > 0 ? index - 1 : 1) }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: Wallpapers.still(of: url))
        Wallpapers.reload()
    }
}

// ── the lock screen ──
// ⌃⌘L, or a few minutes with nothing touched: the desk's own screen over everything — the wallpaper
// (a video one moving) — until Touch ID or the Mac's password
// says it is you (LocalAuthentication: the password never reaches ReDesk). It is a window over a Mac
// still unlocked, so after a while on it the Mac's own lock comes too; unlocking that lets this go.

/// The face: a life of 90 years as a line (as the day's on the desk), UNLOCK at the bottom, and in the bottom left corner a small
/// diamond that sets the birthday the weeks count from. Over the wallpaper, in the apps' small letters.
let lockLetters = NSFont(name: "NotoSansJP-Regular", size: 14) ?? .systemFont(ofSize: 14, weight: .light)

/// The birthday the life calendar counts from, kept between launches.
var birthday: Date? {
    get { UserDefaults.standard.object(forKey: "birthday") as? Date }
    set { UserDefaults.standard.set(newValue, forKey: "birthday") }
}

/// The birthday's field: Return or Escape puts it away.
final class BirthdayField: NSDatePicker {
    var done: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_Escape) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            done()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class LockFace: NSView {
    /// `asked`: UNLOCK clicked or Return pressed, which brings the system's prompt even while Touch ID waits
    var unlock: (_ asked: Bool) -> Void = { _ in }
    /// the screen with the calendar and UNLOCK (the others only show the wallpaper)
    let main: Bool
    private var field: BirthdayField?

    /// a life of 90 years
    static let years = 90

    init(frame: NSRect, main: Bool) {
        self.main = main
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// the corner diamond, where FILE's column meets the bottom words' line on the desk
    private var corner: NSPoint {
        NSPoint(x: bounds.minX + bounds.width * 0.05, y: bounds.minY + bounds.height * 0.0625 + 8)
    }

    override func mouseDown(with event: NSEvent) {
        guard main else { return unlock(false) }
        let point = convert(event.locationInWindow, from: nil)
        if field != nil { return closeBirthday() }
        if hypot(point.x - corner.x, point.y - corner.y) < 18 { return openBirthday() }
        unlock(unlockPlace.contains(point))
    }
    override func rightMouseDown(with event: NSEvent) { if field == nil { unlock(false) } }
    override func keyDown(with event: NSEvent) {
        let enter = event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        unlock(enter)
    }

    /// UNLOCK at the bottom, with room round it for the click
    private var unlockPlace: NSRect {
        NSRect(x: bounds.midX - 160, y: bounds.minY + bounds.height * 0.0625 - 16, width: 320, height: 52)
    }

    private func openBirthday() {
        let field = BirthdayField(frame: .zero)
        field.datePickerStyle = .textField
        field.datePickerElements = .yearMonthDay
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.textColor = ink(0.95)
        field.font = lockLetters
        field.maxDate = Date()
        field.dateValue = birthday ?? Calendar.current.date(from: DateComponents(year: 1995, month: 1, day: 1)) ?? Date()
        field.target = self
        field.action = #selector(birthdayChanged(_:))
        field.done = { [weak self] in self?.closeBirthday() }
        field.sizeToFit()
        field.setFrameOrigin(NSPoint(x: corner.x + 18, y: corner.y - field.frame.height / 2))
        addSubview(field)
        window?.makeFirstResponder(field)
        self.field = field
        // set at once, so the weeks show while the date is being typed
        birthday = field.dateValue
        needsDisplay = true
    }

    @objc private func birthdayChanged(_ sender: NSDatePicker) {
        birthday = sender.dateValue
        needsDisplay = true
    }

    private func closeBirthday() {
        guard let field else { return }
        birthday = field.dateValue
        field.removeFromSuperview()
        self.field = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard main else { return }
        drawLife()
        drawDiamond(at: corner, color: field != nil ? ink(0.95) : strong)
        let hint = NSAttributedString(string: "UNLOCK", attributes: [
            .font: lockLetters, .kern: 0.4 * 14, .foregroundColor: ink(0.5),
        ])
        let h = hint.size()
        hint.draw(at: NSPoint(x: bounds.midX - h.width / 2, y: bounds.minY + bounds.height * 0.0625))
    }

    /// A life of 90 years as the day's line on the desk, MEMENTO MORI over it: a faint line, a mark at its middle (45), and
    /// the diamond at how far in. Without a birthday, no diamond.
    private func drawLife() {
        let width = bounds.width * 0.24
        let line = NSRect(x: bounds.midX - width / 2, y: bounds.midY - 9, width: width, height: 18)
        drawBar(in: NSRect(x: line.minX, y: line.midY - barWidth / 2, width: line.width, height: barWidth), filled: 0, vertical: false)
        strong.setFill()
        NSRect(x: line.midX - 0.75, y: line.minY, width: 1.5, height: line.height).fill()
        let title = NSAttributedString(string: "MEMENTO MORI", attributes: [
            .font: lockLetters, .kern: 0.4 * 14, .foregroundColor: ink(0.5),
        ])
        let t = title.size()
        title.draw(at: NSPoint(x: line.midX - t.width / 2 + 0.2 * 14, y: line.maxY + 14))
        guard let birthday, let end = Calendar.current.date(byAdding: .year, value: LockFace.years, to: birthday) else { return }
        let gone = min(max(Date().timeIntervalSince(birthday) / end.timeIntervalSince(birthday), 0), 1)
        // kept inside the line so it is never cut at the ends
        let r = diamondSize / 2
        drawDiamond(at: NSPoint(x: line.minX + r + (line.width - diamondSize) * CGFloat(gone), y: line.midY))
    }
}

final class LockScreen {
    static let shared = LockScreen()

    private var windows: [LockWindow] = []
    private var faces: [LockFace] = []
    private var shownAt: Date?
    private var before: NSRunningApplication?
    private var systemLocked = false
    /// Touch ID being waited for without the system's prompt
    private var touch: LAContext?
    private var touchView: NSView?

    var shown: Bool { !windows.isEmpty }

    /// minutes with nothing touched before it comes (0: only ⌃⌘L)
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
    }

    private func check() {
        if shown {
            if !systemLocked, let shownAt, Date().timeIntervalSince(shownAt) > systemLockMinutes * 60 {
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
            face.unlock = { [weak self] asked in self?.unlock(asked: asked) }
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
        waitForTouch()
        NSCursor.setHiddenUntilMouseMoves(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Crossfade.themeDuration
            windows.forEach { $0.animator().alphaValue = 1 }
        }
    }

    /// Touch ID without the system's prompt: an unseen LAAuthenticationView takes the prompt's place, so
    /// a finger on the key is all it takes. Tried again after a miss; once Touch ID can't (locked after
    /// misses, or none), a key or a click brings the system's prompt with the password.
    private func waitForTouch() {
        guard shown, let face = faces.first(where: { $0.main }) else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return }
        let view = LAAuthenticationView(context: context, controlSize: .small)
        view.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        view.alphaValue = 0
        touchView?.removeFromSuperview()
        face.addSubview(view)
        touchView = view
        touch = context
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "unlock the desk") { ok, error in
            DispatchQueue.main.async {
                guard self.shown, self.touch === context else { return }
                if ok { return self.hide() }
                let code = (error as? LAError)?.code
                if code == .biometryLockout || code == .biometryNotAvailable || code == .biometryNotEnrolled {
                    self.touch = nil
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.waitForTouch() }
            }
        }
    }

    /// UNLOCK clicked or Return: the screen goes, no prompt asked. Any other key or click does nothing.
    private func unlock(asked: Bool) {
        guard shown, asked else { return }
        hide()
    }

    func hide() {
        guard shown else { return }
        touch?.invalidate()
        touch = nil
        touchView = nil
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

final class Desk: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        InkCursors.restore()
    }

    private let wallpapers = WallpaperView()
    private let day = DayView()
    private let battery = BatteryView()
    private let wave = WaveView()
    private var windows: [DeskWindow] = []
    private let strip = AppStripView()
    /// placed by showStrip(), over the strip the hidden menu bar leaves at the top of the screen
    private lazy var stripWindow = DeskWindow(view: strip) { l in l.area }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ReDesk shows no menu bar, but its fields (the YouTube link, the birthday) still want ⌘X ⌘C ⌘V ⌘A ⌘Z:
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
        NotificationCenter.default.addObserver(self, selector: #selector(layout), name: .wallpapersListed, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(tick), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            wallpapers, selector: #selector(WallpaperView.changedElsewhere), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // a minute of the day is a few pixels at most; the battery moves slower still
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
            self?.showBar()
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
        stripWindow.redrawFading()
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
        showBar()
    }

    /// The apps across the top: only while the windows are in Full Screen. In the menu bar while it stays,
    /// on the desk in its strip while it hides.
    private func showBar() {
        let full = Tiler.shared.on && Tiler.shared.arrangement == .full
        AppMenuBar.shared.shown = full && !menuBarHides
        guard full && menuBarHides, let screen = NSScreen.screens.first, screen.frame.maxY > screen.visibleFrame.maxY else {
            return stripWindow.orderOut(nil)
        }
        let frame = NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY,
                           width: screen.frame.width, height: screen.frame.maxY - screen.visibleFrame.maxY)
        stripWindow.setFrame(frame, display: true)
        stripWindow.orderFront(nil)
    }
}

let app = NSApplication.shared
let desk = Desk()
app.delegate = desk
app.setActivationPolicy(.accessory)
app.run()
