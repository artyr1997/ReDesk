// ReDesk: the Re apps and a few quiet gauges on the desktop.
// Corners: the apps as words (a click opens one). Top: the wallpapers, pictures and videos, as dots in a row
// (wallpapers/Light or wallpapers/Dark, as the Mac's appearance is). Left edge: ReDesk's own desktops.
// Right edge: the battery. Bottom: a wave while sound plays. (The day's line is out for now.)
// Tiling (optional): the Re apps' windows share the middle of the desk, between the gauges.
// Knocks: two to five knocks on the MacBook, each an action.
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
import IOKit.hid
import IOKit.ps
import IOKit.pwr_mgt
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import Network
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
    Corner(word: "PLAY", app: "RePlay", bundle: "com.artursavytskyi.resound", left: true, top: false),
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
    /// .youtube: a link to a video on YouTube, played straight from there (YouTubeWallpaper)
    static let videos = ["mp4", "mov", "m4v", "youtube"]

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
        // a YouTube one sets no picture: it is on while the desktop still has the one it came over
        if let youtube = youtubeOn, url.lastPathComponent == UserDefaults.standard.string(forKey: youtubeOverKey) {
            return youtube
        }
        // by name: the same picture may have been set from the repo's folder rather than the app's
        let name = url.lastPathComponent
        return all.firstIndex { $0.lastPathComponent == name || still(of: $0).lastPathComponent == name }
    }

    /// the desktop's picture a YouTube wallpaper came over, while it is on
    private static let youtubeOverKey = "youtubeOver"
    /// the YouTube wallpaper last chosen in this appearance
    private static var youtubeOn: Int? {
        let chosen = UserDefaults.standard.string(forKey: chosenKey)
        return all.firstIndex { $0.pathExtension == "youtube" && $0.lastPathComponent == chosen }
    }

    static func show(_ index: Int, fading duration: Double = Crossfade.duration) {
        guard all.indices.contains(index) else { return }
        let url = all[index]
        UserDefaults.standard.set(url.lastPathComponent, forKey: chosenKey)
        if url.pathExtension == "youtube" {
            let under = NSScreen.screens.first.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            UserDefaults.standard.set(under?.lastPathComponent, forKey: youtubeOverKey)
        }
        // what is on the desktop now stays over the new wallpaper a moment, then fades away
        let old = LiveWallpaper.shared.url != nil ? LiveWallpaper.shared.handOver() : (windows: Crossfade.cover(), video: [])
        defer { Crossfade.lift(old.windows, keeping: old.video, over: duration) }
        if url.pathExtension == "youtube" {
            // no picture of it ever: the wallpaper before stays until the stream moves over it
            LiveWallpaper.shared.play(url)
        } else if isVideo(url) {
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
            if frozen { player?.pause(); remux?.pause() } else { player?.play(); remuxAgain() }
        }
    }

    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var windows: [NSWindow] = []
    private(set) var url: URL?
    /// a YouTube stream: looked after (a fresh link before YouTube's runs out, or after it fails)
    private var watch: Timer?

    func play(_ url: URL) {
        guard url != self.url else { return }
        stop()
        self.url = url
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
        if url.pathExtension == "youtube" {
            // no picture of it: the wallpaper before stays until YouTube has said where the stream is and it moves
            layout()
            stream(url, into: player)
            return
        }
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        layout()
        if !frozen { player.play() }
    }

    /// A YouTube video straight from YouTube: a live one as it goes, any other round and round.
    private func stream(_ link: URL, into player: AVQueuePlayer) {
        YouTubeWallpaper.resolve(link) { [weak self] stream in
            guard let self, self.player === player else { return }
            guard let stream else {
                // no answer now (offline, or YouTube asking to confirm it's no bot): asked again later and
                // later still, a minute, two, four… up to half an hour, so as not to be taken for one
                self.misses += 1
                return self.watchStream(link, player, after: min(60 * pow(2, Double(self.misses - 1)), 1800), waiting: true)
            }
            self.misses = 0
            YouTubeWallpaper.note("\(link.deletingPathExtension().lastPathComponent): stream from \(stream.url.host ?? "?")"
                + (stream.live ? ", live" : "") + (stream.remux ? ", through ffmpeg" : ""))
            if stream.remux {
                self.remuxed(stream, link, player)
            } else {
                self.remux?.stop()
                self.remux = nil
                let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
                self.show(AVPlayerItem(asset: asset), in: player, looping: !stream.live,
                          from: stream.live ? 0 : YouTubeWallpaper.start(stream.duration))
            }
            // YouTube's links last some six hours: a fresh one well before
            self.watchStream(link, player, after: 4 * 3600)
        }
    }

    /// the YouTube video ffmpeg passes on, when it comes so
    private var remux: Remux?

    /// The VP9 video through ffmpeg, from where the one before was (the same video with an older link, or paused),
    /// its files served on this Mac; once a few seconds of it are there, played as a live stream.
    private func remuxed(_ stream: YouTubeWallpaper.Stream, _ link: URL, _ player: AVQueuePlayer) {
        let old = remux
        let at = old?.position ?? YouTubeWallpaper.start(stream.duration)
        old?.pause()
        let remux = Remux(stream, at: at)
        remux.failed = { [weak self, weak remux] in
            // the link likely out of date: a fresh one, on from here
            guard let self, let remux, self.remux === remux, self.player === player else { return }
            self.stream(link, into: player)
        }
        self.remux = remux
        if frozen || resting { return }
        remux.run()
        LocalFiles.shared.start { [weak self] port in
            guard let self, self.remux === remux, self.player === player else { return }
            guard let port else { return YouTubeWallpaper.note("  no local server") }
            self.whenReady(remux, waited: 0) {
                old?.stop()
                guard let url = URL(string: "http://127.0.0.1:\(port)/\(remux.name)/live.m3u8") else { return }
                self.show(AVPlayerItem(url: url), in: player, looping: false)
            }
        }
    }

    private func whenReady(_ remux: Remux, waited: Double, then go: @escaping () -> Void) {
        guard self.remux === remux else { return }
        if remux.ready || waited > 30 { return go() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.whenReady(remux, waited: waited + 0.5, then: go)
        }
    }

    /// After a pause (⌘⇧M, the displays asleep): ffmpeg goes on from where it stopped.
    private func remuxAgain() {
        guard let remux, !remux.running, let link = url, let player, !frozen, !resting else { return }
        remuxed(remux.stream, link, player)
    }

    /// `from`: where the video starts, and where it starts again at its end (a minute in, YouTubeWallpaper.start)
    private func show(_ item: AVPlayerItem, in player: AVQueuePlayer, looping: Bool, from start: Double = 0) {
        looper = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = nil
        player.removeAllItems()
        player.insert(item, after: nil)
        if looping {
            // round and round: AVPlayerLooper doesn't take a stream, so back to the start at its end
            player.actionAtItemEnd = .none
            ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                           object: item, queue: .main) { [weak player] _ in
                player?.seek(to: CMTime(seconds: start, preferredTimescale: 600))
            }
        }
        if start > 0 {
            // a minute in before it moves (AVFoundation seeks once the stream is ready)
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { [weak self, weak player] _ in
                DispatchQueue.main.async {
                    guard let self, let player, self.player === player, !self.frozen, !self.resting else { return }
                    player.play()
                }
            }
        } else if !frozen && !resting {
            player.play()
        }
        // how it went, a little later
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak player] in
            guard let player, let item = player.currentItem else { return YouTubeWallpaper.note("  no item after 20 s") }
            let event = item.accessLog()?.events.last
            YouTubeWallpaper.note("  after 20 s: item \(item.status.rawValue), \(player.timeControlStatus.rawValue) \(player.reasonForWaitingToPlay?.rawValue ?? ""), "
                + "\(Int(item.presentationSize.width))×\(Int(item.presentationSize.height)), \(Int(event?.numberOfBytesTransferred ?? 0) / 1000) kB"
                + (item.error.map { ", error \($0.localizedDescription)" } ?? "")
                + (item.errorLog()?.events.last.map { ", log \($0.errorStatusCode) \($0.errorComment ?? "") at \(($0.uri ?? "?").prefix(70))" } ?? ""))
        }
    }

    /// YouTube's answers missed in a row
    private var misses = 0
    /// a YouTube video's end, watched to start it again
    private var ended: NSObjectProtocol?

    /// Asks YouTube again after `after` seconds; while a stream plays, sooner, at the minute, when it has failed or
    /// stopped (`waiting`: none yet, only the time counts).
    private func watchStream(_ link: URL, _ player: AVQueuePlayer, after: TimeInterval, waiting: Bool = false) {
        watch?.invalidate()
        let due = Date().addingTimeInterval(after)
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] timer in
            guard let self, self.player === player else { return timer.invalidate() }
            let failed = !waiting && (player.currentItem == nil || player.currentItem?.status == .failed
                || (!self.frozen && !self.resting && player.timeControlStatus == .paused))
            if failed || Date() >= due {
                timer.invalidate()
                self.stream(link, into: player)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    func stop() {
        watch?.invalidate()
        watch = nil
        remux?.stop()
        remux = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = nil
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
        watch?.invalidate()
        watch = nil
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
    func pause() { resting = true; player?.pause(); remux?.pause() }
    func resume() { resting = false; if !frozen { player?.play(); remuxAgain() } }

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
            if let url, url.pathExtension != "youtube", let still = Crossfade.picture(Wallpapers.still(of: url), for: screen) {
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
        // a YouTube stream has no still: the old wallpaper waits for it (YouTube takes some seconds to answer)
        let youtube = LiveWallpaper.shared.url?.pathExtension == "youtube"
        if waited < (youtube ? 30 : 1.5) && !shown {
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
            case 34: KeysPopup.shared.close(); SettingsPopup.shared.toggle()
            case 35: SettingsPopup.shared.close(); KeysPopup.shared.toggle()
            case 51: Desktops.shared.step(-1)
            case 52: Desktops.shared.step(1)
            case 53: Desktops.shared.take(-1)
            case 54: Desktops.shared.take(1)
            default: break
            }
            return noErr
        }, 1, &spec, nil, nil)
        let modifiers = UInt32(controlKey | optionKey)
        let all = keys.map { ($0.id, $0.key, modifiers) } + shifted.map { ($0.id, $0.key, modifiers | UInt32(shiftKey)) }
            + commanded.map { ($0.id, $0.key, modifiers | UInt32(cmdKey)) }
            + [(UInt32(31), kVK_ANSI_T, UInt32(cmdKey | shiftKey)), (UInt32(32), kVK_ANSI_M, UInt32(cmdKey | shiftKey)),
               (UInt32(33), kVK_ANSI_L, UInt32(cmdKey | controlKey)),
               (UInt32(34), kVK_ANSI_Comma, modifiers), (UInt32(35), kVK_ANSI_Slash, modifiers),
               // ⌥⌘↑ / ↓: the desktop above / below; with ⇧ the window in front goes along
               (UInt32(51), kVK_UpArrow, UInt32(optionKey | cmdKey)), (UInt32(52), kVK_DownArrow, UInt32(optionKey | cmdKey)),
               (UInt32(53), kVK_UpArrow, UInt32(optionKey | cmdKey | shiftKey)), (UInt32(54), kVK_DownArrow, UInt32(optionKey | cmdKey | shiftKey))]
        for (number, key, mods) in all {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x5244_534B), id: number),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

/// ⌘ keys, only while one of the Re apps is in front (elsewhere they keep their usual meaning):
/// ⌘⇧↑ / ⌘⇧↓ wallpapers, ⌘↑ the window fills the screen, ⌘↓ the desk's middle, ⌘1…⌘8 an arrangement,
/// ⌘0 Almost Full on / off.
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

    /// F, S, H, N with the desk in front: the app of that letter's corner
    private static let letters = [kVK_ANSI_F: 0, kVK_ANSI_S: 1, kVK_ANSI_P: 2, kVK_ANSI_H: 2, kVK_ANSI_N: 3]

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
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        if flags.isEmpty, let corner = letters[Int(event.getIntegerValueField(.keyboardEventKeycode))],
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0, deskInFront() {
            return { ReDesk.open(corners[corner]) }
        }
        guard flags.contains(.maskCommand),
              tiledApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else { return nil }
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let arrow = key == kVK_UpArrow ? 1 : key == kVK_DownArrow ? -1 : 0
        if flags == [.maskCommand, .maskShift], arrow != 0 {
            return { Wallpapers.step(-arrow) }
        }
        guard flags == .maskCommand else { return nil }
        // ⌘0: Almost Full on / off
        if key == kVK_ANSI_0 { return { Tiler.shared.almostFull.toggle() } }
        // ⌘9: Flush on / off
        if key == kVK_ANSI_9 { return { Tiler.shared.flush.toggle() } }
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

    static func tell(_ windows: [(element: AXUIElement, frame: NSRect)], separate: Bool) {
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
            let info: [String: Any] = ["pid": Int(pid), "corners": corners, "edges": edges,
                                       "x": Double(r.minX), "y": Double(top - r.maxY), "w": Double(r.width), "h": Double(r.height)]
            DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
        }
    }
}

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

    /// Almost Full: the windows share nearly the whole screen (under the menu bar, `tileGap` from the
    /// edges) instead of the desk's middle, in any arrangement, with the apps across the top as in Full Screen
    var almostFull = UserDefaults.standard.bool(forKey: "almostFull") {
        didSet {
            UserDefaults.standard.set(almostFull, forKey: "almostFull")
            retile()
            NotificationCenter.default.post(name: .arrangementChanged, object: nil)
        }
    }

    /// Flush (⌘9): no room between the windows, and only the outer corners of them all rounded, as one window
    var flush = UserDefaults.standard.bool(forKey: "flushTiles") {
        didSet {
            UserDefaults.standard.set(flush, forKey: "flushTiles")
            retile()
            NotificationCenter.default.post(name: .arrangementChanged, object: nil)
        }
    }

    /// whether the apps go across the top: Full Screen, or Almost Full
    var showsApps: Bool { on && (arrangement == .full || almostFull) }

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
        // no longer tiled: every window round again
        WindowJoins.tell(order.compactMap { w in frame(of: w.element).map { (w.element, $0) } }, separate: true)
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

    /// Now (another desktop in sight): the windows looked at again, and tiled if they changed.
    func lookNow() {
        guard on, AXIsProcessTrusted() else { return }
        animation?.invalidate()
        animation = nil
        look()
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
            .filter { tiledApps.contains($0.bundleIdentifier ?? "") && !$0.isHidden
                && Desktops.shared.desktop(of: $0) == Desktops.shared.current }
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

    /// Where the windows share: the desk's middle, the whole screen in Full Screen, nearly all of it in Almost Full.
    private func tilingArea() -> NSRect? {
        guard let screen = NSScreen.screens.first else { return nil }
        let layout = Layout(area: screen.visibleFrame)
        if arrangement == .full { return layout.area }
        // Almost Full: right under the top (the menu bar, or the apps' strip where it hides), `tileGap` from the other edges
        let almost = NSRect(x: layout.area.minX + edgeGap, y: layout.area.minY + edgeGap,
                            width: layout.area.width - edgeGap * 2, height: layout.area.height - edgeGap)
        return almostFull ? almost : layout.tiles
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
        // each app told which of its corners to round (all, but while Flush); stacked, each window is alone
        WindowJoins.tell(zip(order, slots).map { ($0.element, $1) }, separate: !flush || arrangement.stacks)
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
            // again where they now are: an app takes the word only for the place its window is in
            WindowJoins.tell(moves.map { ($0.window.element, $0.to) }, separate: !self.flush || self.arrangement.stacks)
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
        Shape(names: ["com.apple.coregraphics.ArrowS", "com.apple.coregraphics.Arrow", "com.apple.coregraphics.ArrowCtx"],
              day: "cursor-arrow-night", night: "cursor-arrow-night", hotspot: CGPoint(x: 1, y: 1), rimmed: true),
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

    /// The picture at each scale the screen may want (1×, 2×, 3×, 4×).
    private static func images(_ name: String, rimmed: Bool = false) -> [CGImage]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
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
            let rim = CGFloat(side) * 0.04
            let whole = CGRect(x: 0, y: 0, width: side, height: side)
            let place = whole.insetBy(dx: rim, dy: rim)
            func layer(_ color: CGColor, from source: CGImage?) -> CGImage? {
                guard let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                c.interpolationQuality = .high
                if let source {
                    c.draw(source, in: whole)
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
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y))
        }
    }
}

/// Full Screen's way between the apps: FILE  SURF  PLAY  NOTE across the top of the screen, in the apps'
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

    /// distance between dots, left to right
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
        let first = bounds.midX - spacing * CGFloat(Wallpapers.all.count - 1) / 2
        return NSPoint(x: first + spacing * CGFloat(i), y: bounds.midY)
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let nearest = Wallpapers.all.indices.min { abs(centre($0).x - x) < abs(centre($1).x - x) }
        if let nearest, abs(centre(nearest).x - x) <= spacing / 2 { Wallpapers.show(nearest) }
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

// ── desktops: ReDesk's own, one above another ──

/// ReDesk's own desktops, one above another (⌥⌘↑ / ⌥⌘↓; with ⇧ the focused window goes along). Each of the
/// Re apps is on one of them; the apps of the others are hidden, and tiling lays out only this one's. As many
/// as are used, and an empty one under them to take a window to (emptied ones go). Going down the windows
/// rise and fade away while the next desktop's rise into their places; going up, the other way.
final class Desktops {
    static let shared = Desktops()
    /// how far the windows slide, going and coming
    static let slide: CGFloat = 90

    /// each app's desktop, by bundle identifier
    private var place = UserDefaults.standard.dictionary(forKey: "desktopOf") as? [String: Int] ?? [:]
    private(set) var current = UserDefaults.standard.integer(forKey: "desktop")
    /// switching now: an app shown by it is no reason to switch again
    private var switching = false

    private var running: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { tiledApps.contains($0.bundleIdentifier ?? "") }
    }

    func desktop(of app: NSRunningApplication) -> Int { place[app.bundleIdentifier ?? ""] ?? current }

    /// the desktops in use, the one in sight among them, and the empty one under them
    var count: Int {
        let used = running.map(desktop).max() ?? -1
        return max(used + 2, current + 1)
    }

    func start() {
        normalize()
        // the apps of the other desktops out of sight from the start
        for app in running where desktop(of: app) != current && !app.isHidden { app.hide() }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            // a new app on the desktop in sight
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, tiledApps.contains(id) else { return }
            self.place[id] = self.current
            self.changed()
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.changed()
        }
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            // an app of another desktop brought forward (⌘Tab, the Dock, its corner word): to its desktop
            guard let self, !self.switching, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  tiledApps.contains(app.bundleIdentifier ?? ""), self.desktop(of: app) != self.current else { return }
            self.go(to: self.desktop(of: app))
        }
    }

    /// ⌥⌘↑ / ⌥⌘↓: the desktop above or below
    func step(_ by: Int) {
        let to = current + by
        guard to >= 0, to < count else { return }
        go(to: to)
    }

    /// ⌥⌘⇧↑ / ⌥⌘⇧↓: the app in front to the desktop above or below, and there with it
    func take(_ by: Int) {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, tiledApps.contains(id) else { return }
        let to = current + by
        guard to >= 0, to < count else { return }
        place[id] = to
        go(to: to, keeping: app)
    }

    func go(to desktop: Int, keeping kept: NSRunningApplication? = nil) {
        guard desktop != current else { return }
        let down = desktop > current
        let going = running.filter { self.desktop(of: $0) == current && $0 != kept && !$0.isHidden }
        let coming = running.filter { self.desktop(of: $0) == desktop && $0 != kept }
        switching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.switching = false }
        current = desktop
        normalize()
        // going down, everything rises: the windows going up and away, the coming ones up from under
        let rise = down ? Self.slide : -Self.slide
        for app in going {
            let windows = Self.windows(of: app)
            Self.slide(windows, by: rise)
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.artursavytskyi.re.windows"), object: "hide \(app.processIdentifier)", userInfo: nil, deliverImmediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // hidden (an app that didn't hear it, at once): back where they were, for the next time
                if !app.isHidden { app.hide() }
                for (window, frame) in windows { setFrame(of: window, to: frame, exact: true) }
            }
        }
        for app in coming {
            let shown = !app.isHidden
            app.unhide()
            guard !shown else { continue }
            // a moment for the windows to be there again; they fade in (the app does), from under their places
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                let windows = Self.windows(of: app)
                for (window, frame) in windows { setFrame(of: window, to: frame.offsetBy(dx: 0, dy: -rise), exact: true) }
                if !Tiler.shared.on { Self.slide(windows.map { ($0.0, $0.1.offsetBy(dx: 0, dy: -rise)) }, by: rise) }
            }
        }
        // tiling: this desktop's windows to their places (the coming ones glide up into theirs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Tiler.shared.lookNow() }
        // in front: the window taken along, else the app with the biggest window here; on an empty desktop
        // the desk itself (so F, S, H, N open the apps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let kept { kept.activate(); return }
            let biggest = coming.max { a, b in
                let area = { (app: NSRunningApplication) in Self.windows(of: app).map { $0.1.width * $0.1.height }.max() ?? 0 }
                return area(a) < area(b)
            }
            if let biggest { biggest.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        }
        NotificationCenter.default.post(name: .desktopsChanged, object: nil)
    }

    /// emptied desktops gone (but the one in sight), the rest counted from 0, kept
    private func normalize() {
        let apps = running
        var known: [String: Int] = [:]
        for app in apps { if let id = app.bundleIdentifier { known[id] = desktop(of: app) } }
        let used = Set(known.values).union([current]).sorted()
        let index = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
        place = known.mapValues { index[$0] ?? 0 }
        current = index[current] ?? 0
        UserDefaults.standard.set(place, forKey: "desktopOf")
        UserDefaults.standard.set(current, forKey: "desktop")
    }

    private func changed() {
        normalize()
        NotificationCenter.default.post(name: .desktopsChanged, object: nil)
    }

    /// an app's standard windows and where they are
    static func windows(of app: NSRunningApplication) -> [(AXUIElement, NSRect)] {
        let windows = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.compactMap { w in
            guard attribute(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole, let f = frame(of: w) else { return nil }
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
/// A small web server for this Mac alone, on 127.0.0.1, for the remuxed YouTube streams' files: AVFoundation
/// plays HLS over HTTP only.
final class LocalFiles {
    static let shared = LocalFiles()
    let folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReDesk-YouTube", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    private(set) var port: UInt16?
    private var listener: NWListener?
    private var waiting: [(UInt16?) -> Void] = []
    private let queue = DispatchQueue(label: "ReDesk.files")

    /// Starts it once, then `done(port)` on the main thread (nil if it couldn't).
    func start(_ done: @escaping (UInt16?) -> Void) {
        if let port { return done(port) }
        waiting.append(done)
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return answer(nil) }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: DispatchQueue.main.async { self?.port = listener.port?.rawValue; self?.answer(self?.port) }
            case .failed, .cancelled: DispatchQueue.main.async { self?.listener = nil; self?.port = nil; self?.answer(nil) }
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func answer(_ port: UInt16?) {
        let all = waiting
        waiting = []
        all.forEach { $0(port) }
    }

    /// One GET, one file (only from the folder), then the connection closes.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [folder] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let words = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
            var body: Data?
            var type = "application/octet-stream"
            if words.count >= 2, words[0] == "GET" {
                let parts = words[1].split(separator: "?")[0].split(separator: "/").map(String.init)
                if !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0.hasPrefix(".") }) {
                    let file = parts.reduce(folder) { $0.appendingPathComponent($1) }
                    body = try? Data(contentsOf: file)
                    switch file.pathExtension {
                    case "m3u8": type = "application/vnd.apple.mpegurl"
                    case "mp4", "m4s": type = "video/mp4"
                    default: break
                    }
                }
            }
            let head = body == nil
                ? "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body!.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + (body ?? Data()), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// A YouTube VP9 video passed on by ffmpeg as HLS (fMP4, as it comes, nothing re-encoded), into a folder of
/// LocalFiles: a few seconds of it there at a time, round and round (at the end it starts again, after a
/// discontinuity). It goes when paused; `position` is where to take it up again.
final class Remux {
    let name = UUID().uuidString
    var folder: URL { LocalFiles.shared.folder.appendingPathComponent(name, isDirectory: true) }
    let stream: YouTubeWallpaper.Stream
    /// ffmpeg stopped of itself, not at the end: the link is likely out of date
    var failed: (() -> Void)?
    private var task: Process?
    private var from: Double = 0
    private var since = Date()

    init(_ stream: YouTubeWallpaper.Stream, at: Double) {
        self.stream = stream
        from = at
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var position: Double {
        guard task != nil else { return from }
        let at = from + Date().timeIntervalSince(since)
        return stream.duration > 1 ? at.truncatingRemainder(dividingBy: stream.duration) : at
    }

    var running: Bool { task != nil }

    /// a few segments in, enough for AVFoundation to start with
    var ready: Bool {
        let list = (try? String(contentsOf: folder.appendingPathComponent("live.m3u8"), encoding: .utf8)) ?? ""
        return list.components(separatedBy: "#EXTINF").count > 3
    }

    /// From `position` on.
    func run() {
        guard let ffmpeg = YouTubeWallpaper.ffmpeg else { return }
        let at = from
        since = Date()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffmpeg)
        var arguments = ["-nostdin", "-loglevel", "error"]
        if at > 1 { arguments += ["-ss", String(format: "%.1f", at)] }
        arguments += [
            // as fast as it plays (a few seconds ahead at first): no more of it is fetched than is seen
            "-readrate", "1", "-readrate_initial_burst", "6",
            "-headers", stream.headers.map { "\($0.key): \($0.value)\r\n" }.joined(),
            "-i", stream.url.absoluteString,
            "-map", "0:v:0", "-c", "copy",
            "-f", "hls", "-hls_segment_type", "fmp4", "-hls_time", "2", "-hls_list_size", "15",
            "-hls_flags", "delete_segments+omit_endlist+append_list+discont_start+independent_segments",
            folder.appendingPathComponent("live.m3u8").path,
        ]
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.ended(ended) }
        }
        guard (try? task.run()) != nil else { return }
        self.task = task
    }

    private func ended(_ ended: Process) {
        guard ended === task else { return }
        from = position
        task = nil
        if ended.terminationReason == .exit && ended.terminationStatus == 0 {
            // the end: round again, from the start (a minute in)
            from = YouTubeWallpaper.start(stream.duration)
            run()
        } else {
            YouTubeWallpaper.note("  ffmpeg stopped (\(ended.terminationStatus))")
            failed?()
        }
    }

    func pause() {
        from = position
        let running = task
        task = nil
        running?.terminate()
    }

    func stop() {
        pause()
        try? FileManager.default.removeItem(at: folder)
    }
}

// A link pasted in (the right-click menu's Wallpaper from YouTube…) is kept, not the video: a .youtube file
// with the link in Application Support/ReDesk/YouTube (no picture of the video: the wallpaper before stays until the stream moves). Shown, yt-dlp
// asks YouTube where the stream is: the picture alone (no sound), the best there is up to 4K, and the video
// plays from there, a live one as it goes. yt-dlp comes from Homebrew (brew install yt-dlp).

enum YouTubeWallpaper {
    /// what the adding is doing, for the menu; nil while there is none
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
        alert.informativeText = "Paste a link: the video plays from YouTube in its best quality, without sound."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let link = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeYouTube(link) else { return fail("That isn't a YouTube link.") }
        add(link)
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

    /// Runs a tool; its status and output.
    /// yt-dlp as the user: with a browser's YouTube cookies (YouTube asks anyone else, now and then, to confirm
    /// they're no bot). The one that worked last first, then Safari (it takes Full Disk Access for ReDesk),
    /// Chrome, none; Arc's yt-dlp can't read.
    private static let cookiesKey = "youtubeCookies"
    private static func ask(_ ytdlp: String, _ arguments: [String]) -> (status: Int32, output: String) {
        var browsers = ["safari", "chrome", ""]
        if let last = UserDefaults.standard.string(forKey: cookiesKey) {
            browsers.removeAll { $0 == last }
            browsers.insert(last, at: 0)
        }
        var result: (status: Int32, output: String) = (-1, "")
        for browser in browsers {
            result = run(ytdlp, (browser.isEmpty ? [] : ["--cookies-from-browser", browser]) + arguments)
            if result.status == 0 {
                UserDefaults.standard.set(browser, forKey: cookiesKey)
                return result
            }
        }
        return result
    }

    /// A line in Application Support/ReDesk/YouTube.log: how the streams went (the last 200 lines kept).
    static func note(_ text: String) {
        let file = Wallpapers.stills.appendingPathComponent("YouTube.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append("\(stamp) \(text)")
        try? lines.suffix(200).joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (paths + [environment["PATH"] ?? ""]).joined(separator: ":")
        task.environment = environment
        let pipe = Pipe()
        task.standardOutput = pipe
        let errors = Pipe()
        task.standardError = errors
        guard (try? task.run()) != nil else { return (-1, "") }
        // read side by side: a full pipe would hold yt-dlp up
        var said = Data()
        let reading = DispatchGroup()
        DispatchQueue.global().async(group: reading) { said = errors.fileHandleForReading.readDataToEndOfFile() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        reading.wait()
        for warning in String(decoding: said, as: UTF8.self).split(separator: "\n") where warning.hasPrefix("WARNING") {
            note("  \(warning.prefix(240))")
        }
        if task.terminationStatus != 0 {
            let last = String(decoding: said, as: UTF8.self).split(separator: "\n").last { $0.hasPrefix("ERROR") } ?? "no error said"
            note("yt-dlp \(arguments.prefix(2).joined(separator: " ")): \(last.prefix(200))")
        }
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The best picture YouTube streams (HLS, which AVFoundation plays as it comes), up to 4K, never AV1
    /// (a Mac without its decoder can't play it); any HLS stream if there is no picture alone.
    private static let format = "bv*[protocol^=m3u8][height<=2160][vcodec!^=av01]/bv*[protocol^=m3u8][vcodec!^=av01]/b[protocol^=m3u8]"
    /// With ffmpeg: HLS when it is 4K already, else YouTube's VP9 file over 1080p when there is one (not for a
    /// live video, which has none), else as above.
    private static let formatRemuxing = "bv*[protocol^=m3u8][height>=2160][vcodec!^=av01]/bv*[protocol=https][vcodec^=vp9][height>1080][height<=2160]/" + format

    /// Where a .youtube file's video streams from now: HLS that AVFoundation plays as it is, or (`remux`) the
    /// picture alone as a file, VP9 in WebM, which ffmpeg passes on as HLS (YouTube streams HLS up to 1080p for
    /// most videos, its 1440p and 4K come only so). `headers`: YouTube gives the video to the one it gave the
    /// link to (403 to anyone else).
    struct Stream {
        let url: URL
        let live: Bool
        let headers: [String: String]
        let remux: Bool
        let duration: Double
    }

    static var ffmpeg: String? { tool("ffmpeg") }

    /// Where a YouTube wallpaper starts, and starts again at its end: a minute in (past the titles and the
    /// talk most videos open with), when the video is long enough for it (a minute and a half or more).
    static func start(_ duration: Double) -> Double { duration >= 90 ? 60 : 0 }

    /// On the main thread; nil when YouTube didn't say.
    static func resolve(_ file: URL, then done: @escaping (Stream?) -> Void) {
        guard let ytdlp = tool("yt-dlp"),
              let link = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        else { return done(nil) }
        let choice = ffmpeg == nil ? format : formatRemuxing
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ask(ytdlp, ["-f", choice, "--no-playlist", "--print", "is_live", "--print", "url",
                                     "--print", "%(http_headers)j", "--print", "%(format_id)s %(height)sp %(vcodec)s %(protocol)s",
                                     "--print", "%(available_at|0)s", "--print", "%(duration|0)s", link])
            let lines = result.output.split(separator: "\n").map(String.init)
            guard result.status == 0, lines.count >= 6, let url = URL(string: lines[1]) else {
                return DispatchQueue.main.async { done(nil) }
            }
            let headers = (try? JSONSerialization.jsonObject(with: Data(lines[2].utf8))) as? [String: String] ?? [:]
            note("  format \(lines[3])")
            let stream = Stream(url: url, live: lines[0] == "True", headers: headers,
                                remux: lines[3].hasSuffix(" https"),
                                duration: Double(lines[5]) ?? 0)
            // YouTube gives the video only some seconds after the link (403 till then), as yt-dlp waits too
            let at = Double(lines[4]) ?? 0
            let wait = min(max(at - Date().timeIntervalSince1970 + 0.5, 0), 30)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { done(stream) }
        }
    }

    /// Keeps the link (only the link: no picture of the video) and puts it on the desk.
    static func add(_ link: String) {
        guard progress == nil else { return }
        guard let ytdlp = tool("yt-dlp") else { return fail("It takes yt-dlp: brew install yt-dlp") }
        progress = "looking"
        DispatchQueue.global(qos: .userInitiated).async {
            let info = ask(ytdlp, ["--skip-download", "--no-playlist", "--print", "%(title).80B [%(id)s]",
                                   "--print", "webpage_url", link])
            let lines = info.output.split(separator: "\n").map(String.init)
            guard info.status == 0, lines.count >= 2 else { return fail("YouTube didn't give the video.") }
            let name = lines[0].replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let file = Wallpapers.youtubeFolder.appendingPathComponent(name + ".youtube")
            guard (try? lines[1].write(to: file, atomically: true, encoding: .utf8)) != nil else {
                return fail("It couldn't be kept.")
            }
            DispatchQueue.main.async {
                progress = nil
                Wallpapers.reload()
                if let index = Wallpapers.all.firstIndex(of: file) { Wallpapers.show(index) }
            }
        }
    }

    /// The YouTube wallpaper on the desk goes (its link), and the desk takes the one before it.
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

    /// the birthday diamond, just under the life line
    private var corner: NSPoint {
        NSPoint(x: bounds.midX, y: bounds.midY - 9 - 24)
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

    /// A life of 90 years as a line like the day's on the desk, MEMENTO MORI over it: filled as far as lived, a mark at
    /// its middle (45). Without a birthday, nothing filled.
    private func drawLife() {
        let width = bounds.width * 0.24
        let line = NSRect(x: bounds.midX - width / 2, y: bounds.midY - 9, width: width, height: 18)
        var gone = 0.0
        if let birthday, let end = Calendar.current.date(byAdding: .year, value: LockFace.years, to: birthday) {
            gone = Date().timeIntervalSince(birthday) / end.timeIntervalSince(birthday)
        }
        drawBar(in: NSRect(x: line.minX, y: line.midY - barWidth / 2, width: line.width, height: barWidth), filled: gone, vertical: false)
        strong.setFill()
        NSRect(x: line.midX - 0.75, y: line.minY, width: 1.5, height: line.height).fill()
        let title = NSAttributedString(string: "MEMENTO MORI", attributes: [
            .font: lockLetters, .kern: 0.4 * 14, .foregroundColor: ink(0.5),
        ])
        let t = title.size()
        title.draw(at: NSPoint(x: line.midX - t.width / 2 + 0.2 * 14, y: line.maxY + 14))
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

/// The screen's brightness follows the lid: open (from about 100°) it is the brightness the user chose,
/// closing it dims the screen down to nearly dark at 20°. The angle comes from the hinge's sensor (a HID
/// sensor of Apple's, 0x05AC:0x8104, on the MacBooks that have one), the brightness goes through
/// DisplayServices; neither is public. Set by hand (the keys, Control Center, auto-brightness), the
/// brightness becomes the new open one.
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

    private var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    private func brightness() -> Float? {
        var value: Float = 0
        guard let getBrightness, getBrightness(display, &value) == 0 else { return nil }
        return value
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
        base = nil
        pace(fast: false)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // the user's brightness back
        if let base, let setBrightness { _ = setBrightness(display, base) }
        base = nil
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
        guard let angle = angle(), let now = brightness() else { return }
        let eased = smooth.map { $0 + (angle - $0) * 0.18 } ?? angle
        smooth = eased
        let share = share(eased)
        if base == nil {
            base = share > 0.25 ? min(1, now / share) : now
            shown = now
        } else if let shown, abs(shown - now) > 0.02, Date().timeIntervalSince(setAt) > 1,
                  share > 0.25, CGDisplayIsAsleep(display) == 0 {
            // changed by something else (and not mid-way through a change of ours): what the user wants
            base = min(1, now / share)
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

// ── knocks: two or three knocks on the MacBook, each its own action ──

/// What a number of knocks does.
enum KnockAction: String, CaseIterable {
    case none, lock, playPause, mute, screenshot, hideWindows, closeWindows, nextWallpaper, freezeWallpaper, blurWallpaper, file, surf, hear, note

    var title: String {
        switch self {
        case .none: return "Nothing"
        case .lock: return "Lock Screen"
        case .playPause: return "Play / Pause"
        case .mute: return "Mute"
        case .screenshot: return "Screenshot"
        case .hideWindows: return "Hide / Show Windows"
        case .closeWindows: return "Close All Windows"
        case .nextWallpaper: return "Next Wallpaper"
        case .freezeWallpaper: return "Pause Wallpaper"
        case .blurWallpaper: return "Blur Wallpaper"
        case .file: return "Open ReFile"
        case .surf: return "Open ReSurf"
        case .hear: return "Open RePlay"
        case .note: return "Open ReNote"
        }
    }

    func run() {
        switch self {
        case .none: break
        case .lock: LockScreen.shared.show()
        case .playPause: Self.mediaKey(16)  // NX_KEYTYPE_PLAY
        case .mute: Self.mediaKey(7)        // NX_KEYTYPE_MUTE
        case .screenshot: Self.keys(kVK_ANSI_3, [.maskCommand, .maskShift])
        case .hideWindows:  // any shown: all hidden; all hidden: all shown again
            // each app of this desktop fades its own windows out and hides, or shows them again fading in
            // (the other desktops' stay hidden)
            let apps = Self.reApps(), hide = apps.contains { !$0.isHidden }
            for app in apps {
                if hide {
                    DistributedNotificationCenter.default().postNotificationName(
                        .init("com.artursavytskyi.re.windows"), object: "hide \(app.processIdentifier)", userInfo: nil, deliverImmediately: true)
                } else {
                    app.unhide()
                }
            }
            // an app that didn't hear it (an older build): at once, without the fade
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                for app in apps where app.isHidden != hide { _ = hide ? app.hide() : app.unhide() }
            }
        case .closeWindows:  // the Re apps fade theirs out and close them; the others, at once through Accessibility
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.artursavytskyi.re.windows"), object: "close", userInfo: nil, deliverImmediately: true)
            Self.others().filter { !tiledApps.contains($0.bundleIdentifier ?? "") }.forEach(Self.closeWindows)
        case .nextWallpaper: Wallpapers.step(1)
        case .freezeWallpaper: LiveWallpaper.shared.frozen.toggle()
        case .blurWallpaper: WallpaperBlur.on.toggle()
        case .file: ReDesk.open(corners[0])
        case .surf: ReDesk.open(corners[1])
        case .hear: ReDesk.open(corners[2])
        case .note: ReDesk.open(corners[3])
        }
    }

    /// the Re apps (ReFile, ReSurf, RePlay, ReNote, ReBook) running on the desktop in sight
    private static func reApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            tiledApps.contains($0.bundleIdentifier ?? "") && Desktops.shared.desktop(of: $0) == Desktops.shared.current
        }
    }

    /// the apps with windows, but ReDesk
    private static func others() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
    }

    /// Each of the app's windows closed with its own close button (the app keeps running; a window with
    /// unsaved changes asks first, as it always does). Needs the Accessibility permission.
    private static func closeWindows(of app: NSRunningApplication) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            var button: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        }
    }

    /// a media key (play, mute…) pressed and let go, as the keyboard's own
    private static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data = (key << 16) | ((down ? 0xa : 0xb) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// a key with modifiers (⌘⇧3: the system's own screenshot, saved as its settings say)
    private static func keys(_ key: Int, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// Knocks on the MacBook (its side, the palm rest, the lid): two or three in a row, each count its own
/// action (right click › Knocks). The Mac's motion sensor feels them: an accelerometer and a gyroscope of
/// Apple's in the SPU (HID usage page 0xFF00, usages 3 and 9, about 800 readings a second; undocumented, no
/// root needed), read on a thread of its own. Each reading is split into the body's motion (about 1 to 40 Hz)
/// and the knock (faster): a knock rings the Mac, moving it swings it. Knocks within half a second of each other
/// are one gesture; it is done half a second after the last. None counts within 0.35 s of typing, a click or a
/// scroll (they shake the Mac too), nor while locked.
final class Knocks {
    static let shared = Knocks()

    var on: Bool {
        get { UserDefaults.standard.object(forKey: "knocks") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "knocks"); newValue ? start() : stop() }
    }

    /// the counts that do something: two to five (a single knock happens by chance too easily)
    static let counts = [2, 3, 4, 5]
    static let defaults: [Int: KnockAction] = [2: .playPause, 3: .lock]

    func action(_ count: Int) -> KnockAction {
        KnockAction(rawValue: UserDefaults.standard.string(forKey: "knock\(count)") ?? "") ?? Self.defaults[count] ?? .none
    }

    func set(_ count: Int, _ action: KnockAction) {
        UserDefaults.standard.set(action.rawValue, forKey: "knock\(count)")
    }

    /// how light a knock still counts: 0 firm, 1 medium, 2 light
    var sensitivity: Int {
        get { UserDefaults.standard.object(forKey: "knockSensitivity") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "knockSensitivity"); tune() }
    }
    static let sensitivities = ["Firm", "Medium", "Light"]

    /// the motion sensor is there (the MacBooks from the M1 Pro and the M2 on)
    lazy var available: Bool = !services(usage: 3).isEmpty

    /// set for ReDesk --lid-test: each knock felt goes here instead
    var testing: ((Double) -> Void)?

    private var thread: Thread?
    private var loop: CFRunLoop?
    private var lastInput = Date.distantPast
    private var monitor: Any?

    private func services(usage: Int) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let page = IORegistryEntryCreateCFProperty(service, "PrimaryUsagePage" as CFString, nil, 0)?.takeRetainedValue() as? Int
            let use = IORegistryEntryCreateCFProperty(service, "PrimaryUsage" as CFString, nil, 0)?.takeRetainedValue() as? Int
            if page == 0xFF00 && use == usage { out.append(service) } else { IOObjectRelease(service) }
        }
        return out
    }

    func start() {
        guard thread == nil, available, on || testing != nil else { return }
        tune()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] _ in
            self?.lastInput = Date()
        }
        let thread = Thread { [weak self] in self?.listen() }
        thread.name = "ReDesk knocks"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func stop() {
        if let loop { CFRunLoopStop(loop) }
        loop = nil
        thread = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // ── on the sensor's thread ──

    /// One sensor's readings, split: the body's motion and the knock.
    private final class Stream {
        private var slow = SIMD3<Double>(repeating: .nan)
        private var fast = SIMD3<Double>(repeating: .nan)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

        func push(_ value: SIMD3<Double>) -> (motion: Double, knock: Double) {
            if slow.x.isNaN { slow = value; fast = value }
            slow += (value - slow) * 0.01
            fast += (value - fast) * 0.25
            let m = fast - slow, k = value - fast
            return ((m * m).sum().squareRoot(), (k * k).sum().squareRoot())
        }
    }

    /// The usual: the strongest of each 50 ms, over the last two seconds, the quieter third's top.
    /// A knock and its ringing take a few of those 50 ms; they don't move it.
    private final class Usual {
        private var blocks = [Double](repeating: 0, count: 40)
        private var index = 0
        private var block = 0.0
        private var samples = 0
        private(set) var level = 0.0

        func add(_ size: Double) {
            block = max(block, size)
            samples += 1
            guard samples == 40 else { return }
            blocks[index % blocks.count] = block
            index += 1
            samples = 0
            block = 0
            let filled = blocks.prefix(min(index, blocks.count)).sorted()
            level = filled[filled.count / 3]
        }
    }

    private let knockUsual = Usual()
    private let accel = Stream()
    private let gyro = Stream()
    private var count = 0
    private var gyroCount = 0
    /// the gyroscope's motion over the last 0.45 s: a swing (the Mac moved), not a knock
    private var gyroMotion = [Double](repeating: 0, count: 360)
    private var secondKnock = 0.0
    private var secondMotion = 0.0
    var logSeconds = false
    private var due: Int?
    private var knockPeak = 0.0
    private var motionPeak = 0.0
    private var quietUntil = 0
    private var lastKnock = -10_000
    private var lastPeak = 0.0
    /// a knock: this many times the usual, and this many g at least (by sensitivity)
    private var times = 6.0
    private var floor = 0.007

    private func tune() {
        let s = min(max(sensitivity, 0), 2)
        times = [8, 6, 5][s]
        floor = [0.012, 0.007, 0.0045][s]
    }

    private func listen() {
        // the sensor's drivers report only when asked to (once a millisecond)
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS {
            while case let driver = IOIteratorNext(iterator), driver != 0 {
                for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 1000)] {
                    IORegistryEntrySetCFProperty(driver, key as CFString, value as CFNumber)
                }
                IOObjectRelease(driver)
            }
            IOObjectRelease(iterator)
        }
        var devices: [IOHIDDevice] = []
        for (usage, stream) in [(3, accel), (9, gyro)] {
            for service in services(usage: usage) {
                defer { IOObjectRelease(service) }
                guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service),
                      IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
                let context = Unmanaged.passUnretained(self).toOpaque()
                if usage == 3 {
                    IOHIDDeviceRegisterInputReportCallback(device, stream.buffer, 64, { context, _, _, _, _, report, length in
                        Unmanaged<Knocks>.fromOpaque(context!).takeUnretainedValue().accelReport(report, length)
                    }, context)
                } else {
                    IOHIDDeviceRegisterInputReportCallback(device, stream.buffer, 64, { context, _, _, _, _, report, length in
                        Unmanaged<Knocks>.fromOpaque(context!).takeUnretainedValue().gyroReport(report, length)
                    }, context)
                }
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
                devices.append(device)
            }
        }
        loop = CFRunLoopGetCurrent()
        CFRunLoopRun()
        for device in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    /// x, y, z: three little-endian 16.16 numbers from the report's sixth byte
    private static func xyz(_ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) -> SIMD3<Double>? {
        guard length >= 18 else { return nil }
        func at(_ o: Int) -> Double {
            Double(Int32(bitPattern: UInt32(report[o]) | UInt32(report[o + 1]) << 8 | UInt32(report[o + 2]) << 16 | UInt32(report[o + 3]) << 24)) / 65536
        }
        return SIMD3(at(6), at(10), at(14))
    }

    private func gyroReport(_ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        guard let value = Self.xyz(report, length) else { return }
        let (motion, _) = gyro.push(value)
        gyroMotion[gyroCount % gyroMotion.count] = motion
        gyroCount += 1
        secondMotion = max(secondMotion, motion)
    }

    /// A knock: the ringing well above the usual; looked at 60 ms later. If the Mac swung meanwhile (the
    /// gyroscope over 15°/s) or the ringing was small beside the motion, the Mac was moved, not knocked.
    /// Just after a knock its own ringing is no new one: the next must be at least 0.4 of it.
    private func accelReport(_ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        guard let value = Self.xyz(report, length) else { return }
        let (motion, knock) = accel.push(value)
        count += 1
        knockUsual.add(knock)
        secondKnock = max(secondKnock, knock)
        if count % 800 == 0 {
            if logSeconds {
                let line = String(format: "second: knock max %.4fg (usual %.4f), turn max %.1f°/s", secondKnock, knockUsual.level, secondMotion)
                DispatchQueue.main.async { Knocks.log(line) }
            }
            secondKnock = 0
            secondMotion = 0
        }
        if let at = due {
            knockPeak = max(knockPeak, knock)
            motionPeak = max(motionPeak, motion)
            guard count >= at else { return }
            due = nil
            quietUntil = count + 64
            let turned = gyroMotion.max() ?? 0
            let peak = knockPeak, ratio = knockPeak / max(motionPeak, 0.0001)
            guard turned < 15, ratio > 0.4 else {
                let line = String(format: "moved, not knocked: %.3fg, turn %.0f°/s, ring/motion %.2f", peak, turned, ratio)
                DispatchQueue.main.async { Knocks.log(line) }
                return
            }
            lastKnock = count
            lastPeak = peak
            DispatchQueue.main.async { self.felt(peak) }
            return
        }
        guard count > 1600, count > quietUntil, knock > max(knockUsual.level * times, floor) else { return }
        if count - lastKnock < 240 && knock < lastPeak * 0.4 { return }
        due = count + 48
        knockPeak = knock
        motionPeak = motion
    }

    // ── on the main thread ──

    private var knocks = 0
    private var firstAt = Date.distantPast

    private var lastAt = Date.distantPast
    private var done: DispatchWorkItem?

    private func felt(_ peak: Double) {
        if let testing { return testing(peak) }
        let now = Date()
        guard on, !LockScreen.shared.shown, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
        if now.timeIntervalSince(lastAt) > 0.5 { knocks = 0; firstAt = now }
        knocks += 1
        lastAt = now
        Self.log(String(format: "knock %d, %.3fg", knocks, peak))
        done?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        done = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// half a second after the last knock: the gesture is done
    private func finish() {
        let count = knocks
        knocks = 0
        // typed, clicked or scrolled from just before the first knock on: the keys shook it, not a knock
        guard lastInput < firstAt.addingTimeInterval(-0.35) else {
            return Self.log("\(count) knocks, but typing or clicking around them: nothing")
        }
        let action = Self.counts.contains(count) ? self.action(count) : .none
        Self.log("\(count) knocks → \(action.title)")
        action.run()
    }

    /// ~/Library/Application Support/ReDesk/Knocks.log: each knock felt, how hard, and what it did
    static func log(_ line: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReDesk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Knocks.log")
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
// ── a snap of the fingers: the lock screen, or what is chosen ──

/// The microphone, listened to for a snap of the fingers or a clap right at the screen: a click so loud only
/// one that near makes it (`loud`), mostly
/// high (over 2 kHz), short (gone within 40 ms) and alone (quiet just before). Then, if nothing was typed or
/// clicked just before or after (a key's click is much like it), its action (the lock screen at first). Nothing is recorded:
/// each 2.5 ms of sound is only measured. While it listens macOS shows its orange microphone dot.
final class Snap {
    static let shared = Snap()
    /// how loud a snap must be (of full scale): a snap or clap at the screen measured 0.2 to 1, the room's noise up to 0.05
    static let loud: Float = 0.1

    var on: Bool {
        get { UserDefaults.standard.object(forKey: "snapLock") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "snapLock"); listening = newValue; refresh() }
    }

    /// Blowing on the Mac (Settings › Screen): the microphone hears wind, loud and low, held a moment.
    var blowOn: Bool {
        get { UserDefaults.standard.object(forKey: "blow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "blow"); blowing = newValue; refresh() }
    }

    /// what blowing does: any of the knocks' actions; at first, Hide / Show Windows
    var blowAction: KnockAction {
        get { KnockAction(rawValue: UserDefaults.standard.string(forKey: "blowAction") ?? "") ?? .hideWindows }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "blowAction") }
    }

    /// how loud blowing must be (of full scale, all of the sound): the room and talking stay well under it
    static let blowLoud: Float = 0.1

    /// the microphone on while a snap or blowing is listened for, off when neither
    private func refresh() { on || blowOn ? start() : stop() }

    /// what a snap does (Settings › Screen): any of the knocks' actions; at first, the lock screen
    var action: KnockAction {
        get { KnockAction(rawValue: UserDefaults.standard.string(forKey: "snapAction") ?? "") ?? .lock }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "snapAction") }
    }

    private let engine = AVAudioEngine()
    private var running = false
    private var monitor: Any?
    private var lastInput = Date.distantPast

    func start() {
        listening = on
        blowing = blowOn
        guard on || blowOn, !running else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { if granted { self.start() } }
            }
            return
        case .authorized: break
        default: return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        rate = format.sampleRate
        frame = Int(rate / 400)
        let rc = 1 / (2 * Double.pi * 2000), dt = 1 / rate
        alpha = Float(rc / (rc + dt))
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in self?.hear(buffer) }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return
        }
        running = true
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.lastInput = Date()
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // ── on the audio thread ──

    private var rate = 48000.0
    private var frame = 120
    private var alpha: Float = 0.8
    private var previous: Float = 0
    private var high: Float = 0
    private var sumHigh: Float = 0
    private var sumAll: Float = 0
    private var inFrame = 0
    /// each 2.5 ms: how loud its high part was, and how much of it was high
    private var loud = [Float](repeating: 0, count: 256)
    private var share = [Float](repeating: 0, count: 256)
    private var frames = 0
    private var due: Int?
    private var quietUntil = 0
    private var blocks = [Float](repeating: 0, count: 50)
    private var block: Float = 0
    private var usual: Float = 0.001
    /// the same for all of the sound, for blowing
    private var blocksAll = [Float](repeating: 0, count: 50)
    private var blockAll: Float = 0
    private var usualAll: Float = 0.001
    /// what is listened for (set on the main thread, read here)
    private var listening = true
    private var blowing = true
    /// blowing now: its loud low frames, how loud and how high they were, the frames since the last one
    private var blowFrames = 0
    private var blowLevel: Float = 0
    private var blowHigh: Float = 0
    private var blowGap = 0
    private var blowDone = false

    private func hear(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        for i in 0..<Int(buffer.frameLength) {
            let x = samples[i]
            high = alpha * (high + x - previous)
            previous = x
            sumHigh += high * high
            sumAll += x * x
            inFrame += 1
            if inFrame == frame { measured() }
        }
    }

    private func at(_ ring: [Float], _ n: Int) -> Float { ring[(n + 256 * 64) % 256] }

    private func measured() {
        let level = (sumHigh / Float(frame)).squareRoot()
        let all = (sumAll / Float(frame)).squareRoot()
        sumHigh = 0; sumAll = 0; inFrame = 0
        let n = frames
        loud[n % 256] = level
        share[n % 256] = all > 0 ? level / all : 0
        frames += 1
        // the room's usual: the strongest of each 20 ms over the last second, the quieter third's top
        block = max(block, level)
        blockAll = max(blockAll, all)
        if frames % 8 == 0 {
            blocks[(frames / 8) % blocks.count] = block
            block = 0
            usual = blocks.sorted()[blocks.count / 3]
            blocksAll[(frames / 8) % blocksAll.count] = blockAll
            blockAll = 0
            usualAll = blocksAll.sorted()[blocksAll.count / 3]
        }
        if blowing && frames > 400 { blow(all: all, high: all > 0 ? level / all : 1) }
        guard listening else { due = nil; return }
        if let start = due {
            guard n >= start + 24 else { return }
            due = nil
            quietUntil = n + 80
            let peak = (start..<(start + 4)).map { at(loud, $0) }.max() ?? 0
            let before = ((start - 40)..<(start - 1)).map { at(loud, $0) }.max() ?? 0
            let after = ((start + 16)..<(start + 24)).map { at(loud, $0) }.max() ?? 0
            let high = at(share, start)
            let snap = peak > Snap.loud && before < peak * 0.25 && after < peak * 0.3 && high > 0.35
            let line = String(format: "%@: peak %.3f (usual %.4f), before %.2f, after %.2f, high %.2f",
                              snap ? "snap" : peak > Snap.loud ? "no snap" : "too soft", peak, usual, before / peak, after / peak, high)
            DispatchQueue.main.async {
                Snap.log(line)
                if snap { self.snapped() }
            }
            return
        }
        guard frames > 400, n > quietUntil, level > max(usual * 12, 0.03) else { return }
        due = n
    }

    /// Blowing on the microphone is wind: loud, nearly all of it low (under 2 kHz), and held. Frames like that
    /// with gaps of under 0.1 s are one breath; 0.4 s of them is blowing, done once a breath. Each breath of
    /// 0.1 s or more goes to the log, measured.
    private func blow(all: Float, high: Float) {
        if all > max(usualAll * 8, Snap.blowLoud) && high < 0.3 {
            blowFrames += 1
            blowLevel += all
            blowHigh += high
            blowGap = 0
            if blowFrames == 160 && !blowDone {
                blowDone = true
                DispatchQueue.main.async { self.blown() }
            }
        } else if blowFrames > 0 {
            blowGap += 1
            guard blowGap > 40 else { return }
            if blowFrames >= 40 {
                let line = String(format: "breath: %.2f s, loud %.3f (usual %.4f), high %.2f%@", Double(blowFrames) / 400,
                                  blowLevel / Float(blowFrames), usualAll, blowHigh / Float(blowFrames), blowDone ? ", blown" : "")
                DispatchQueue.main.async { Snap.log(line) }
            }
            blowFrames = 0; blowLevel = 0; blowHigh = 0; blowGap = 0; blowDone = false
        }
    }

    // ── on the main thread ──

    /// blowing: its action, unless locked or the displays asleep
    private func blown() {
        guard !LockScreen.shared.shown, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return Snap.log("blown, but locked: nothing") }
        Snap.log("blown → \(blowAction.title)")
        blowAction.run()
    }

    private var heardAt = Date.distantPast

    /// a snap: the lock screen, unless keys or clicks were near it (looked at again a quarter second on)
    private func snapped() {
        heardAt = Date()
        let at = heardAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.heardAt == at else { return }
            let gap = abs(self.lastInput.timeIntervalSince(at))
            guard gap > 0.4, !LockScreen.shared.shown, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
                return Snap.log(String(format: "nothing: input %.2f s away, locked already %@", gap, LockScreen.shared.shown ? "yes" : "no"))
            }
            Snap.log("→ \(self.action.title)")
            self.action.run()
        }
    }

    /// ~/Library/Application Support/ReDesk/Snap.log: each click heard, measured, and what came of it
    static func log(_ line: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReDesk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Snap.log")
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// ── the two popups: Settings (⌃⌥, or a right click) and Keys (⌃⌥/), every Re app's keys ──

/// The Re apps' popups (as ReNote's INFO): the paper, its grain and a 2pt line round it, in the middle of the
/// screen, everything else blurred behind; the heading in Noto Sans JP spaced wide, the words in Kurale.
/// Light or dark as the Mac is. Esc, the same keys again, or a click beside it closes it.
class Popup: NSPanel {
    /// the paper's colours, as the apps' --bg, --text and --line
    static var paper: NSColor { Appearance.dark ? NSColor(white: 0x1d / 255.0, alpha: 1) : NSColor(white: 0xF4 / 255.0, alpha: 1) }
    static var text: NSColor { Appearance.dark ? NSColor(white: 0x80 / 255.0, alpha: 1) : NSColor(white: 0x47 / 255.0, alpha: 1) }
    static var line: NSColor { Appearance.dark ? NSColor(white: 0x74 / 255.0, alpha: 1) : NSColor(red: 0x57 / 255.0, green: 0x58 / 255.0, blue: 0x5A / 255.0, alpha: 1) }

    static let fonts: Void = {
        for name in ["Kurale"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "woff") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        _ = letterFont
    }()
    static func noto(_ size: CGFloat) -> NSFont { _ = fonts; return NSFont(name: "NotoSansJP-Regular", size: size) ?? .systemFont(ofSize: size, weight: .light) }
    static func kurale(_ size: CGFloat) -> NSFont { _ = fonts; return NSFont(name: "Kurale-Regular", size: size) ?? NSFont(name: "Kurale", size: size) ?? .systemFont(ofSize: size) }
    static let grain = Bundle.main.image(forResource: "noise")

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
    override func resignKey() { super.resignKey(); close() }
    override func close() { super.close(); veil.orderOut(nil) }

    /// the popup's content: built anew each time it shows (and when a choice changes what it shows)
    func build() -> NSView { NSView() }

    /// how wide it is on this screen
    func width(on screen: NSRect) -> CGFloat { frame.width }

    func toggle() { isVisible ? close() : show() }

    func show() {
        refresh()
        if let screen = NSScreen.main {
            veil.setFrame(screen.frame, display: true)
            veil.appearance = NSAppearance(named: Appearance.dark ? .darkAqua : .aqua)
            veil.orderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func refresh() {
        actions = []
        // the lists a choice opens, light or dark with the paper
        appearance = NSAppearance(named: Appearance.dark ? .darkAqua : .aqua)
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
        NSTextField(labelWithAttributedString: NSAttributedString(string: words.uppercased(), attributes: [
            .font: Self.noto(18), .foregroundColor: Self.text, .kern: 7.2,
        ]))
    }

    /// a section's name: small, spaced, quiet
    func caption(_ words: String) -> NSTextField {
        NSTextField(labelWithAttributedString: NSAttributedString(string: words.uppercased(), attributes: [
            .font: Self.noto(11), .foregroundColor: Self.text.withAlphaComponent(0.6), .kern: 2.2,
        ]))
    }

    func words(_ words: String, size: CGFloat = 14, alpha: CGFloat = 1) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: words)
        field.font = Self.kurale(size)
        field.textColor = Self.text.withAlphaComponent(alpha)
        field.isSelectable = false
        return field
    }

    /// keys, as the apps write them: Noto Sans JP, small, quieter
    func keys(_ keys: String) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: NSAttributedString(string: keys, attributes: [
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
        button.attributedTitle = NSAttributedString(string: title.uppercased(), attributes: [
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

/// the popup's sheet of paper
final class PaperView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Popup.paper.setFill()
        bounds.fill()
        if let grain = Popup.grain {
            // as the apps: at night the grain is multiplied into the paper (background-blend-mode: multiply)
            NSColor(patternImage: grain).setFill()
            bounds.fill(using: Appearance.dark ? .multiply : .sourceOver)
        }
        Popup.line.setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        edge.lineWidth = 2
        edge.stroke()
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
    static let shared = SettingsPopup(width: 560)

    override func build() -> NSView {
        var views: [NSView] = [heading("Re:Desk")]
        func section(_ name: String, _ rows: [NSView]) {
            views.append(divider())
            views.append(caption(name))
            views.append(contentsOf: rows)
        }

        var desk: [NSView] = [toggleRow("Tile windows", Tiler.shared.on, note: "⌃⌥T") { Tiler.shared.on = $0 }]
        if Tiler.shared.on && !AXIsProcessTrusted() {
            desk.append(buttonRow("Tiling needs Accessibility", "Allow", indent: 18) { Tiler.openAccessibilitySettings() })
        }
        let arrangements = Arrangement.allCases
        desk.append(choiceRow("Arrangement", arrangements.map(\.title), arrangements.firstIndex(of: Tiler.shared.arrangement) ?? 0,
                              indent: 18, note: "⌘1…⌘8") { Tiler.shared.choose(arrangements[$0]) })
        desk.append(toggleRow("Almost full", Tiler.shared.almostFull, indent: 18, note: "⌘0") { Tiler.shared.almostFull = $0 })
        desk.append(toggleRow("Flush", Tiler.shared.flush, indent: 18, note: "⌘9") { Tiler.shared.flush = $0 })
        desk += [
            toggleRow("Ink cursors", InkCursors.on) { InkCursors.on = $0 },
            toggleRow("Dark appearance", Appearance.dark, note: "⌘⇧T") { if $0 != Appearance.dark { Appearance.toggle() } },
            toggleRow("Open at login", SMAppService.mainApp.status == .enabled) { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {
                    SMAppService.openSystemSettingsLoginItems()
                }
            },
        ]
        section("Desk", desk)

        var wallpaper: [NSView] = []
        if let progress = YouTubeWallpaper.progress {
            wallpaper.append(row("YouTube", words(progress, alpha: 0.6)))
        } else {
            wallpaper.append(buttonRow("Wallpaper from YouTube", "Add") { [weak self] in self?.close(); YouTubeWallpaper.ask() })
        }
        if let index = Wallpapers.current, Wallpapers.youtube.contains(Wallpapers.all[index]) {
            wallpaper.append(buttonRow("This wallpaper", "Remove") { [weak self] in self?.close(); YouTubeWallpaper.removeCurrent() })
        }
        wallpaper.append(toggleRow("Blur wallpaper", WallpaperBlur.on) { WallpaperBlur.on = $0 })
        wallpaper.append(toggleRow("Video wallpaper stands still", LiveWallpaper.shared.frozen, note: "⌘⇧M") { LiveWallpaper.shared.frozen = $0 })
        section("Wallpaper", wallpaper)

        var screen: [NSView] = [
            buttonRow("Lock screen", "Lock", note: "⌃⌘L") { [weak self] in self?.close(); LockScreen.shared.show() },
            toggleRow("Snap or clap", Snap.shared.on) { Snap.shared.on = $0 },
        ]
        if Snap.shared.on {
            let all = KnockAction.allCases
            screen.append(choiceRow("Snap does", all.map(\.title), all.firstIndex(of: Snap.shared.action) ?? 0, indent: 18) {
                Snap.shared.action = all[$0]
            })
        }
        screen.append(toggleRow("Blow on the Mac", Snap.shared.blowOn) { Snap.shared.blowOn = $0 })
        if Snap.shared.blowOn {
            let all = KnockAction.allCases
            screen.append(choiceRow("Blowing does", all.map(\.title), all.firstIndex(of: Snap.shared.blowAction) ?? 0, indent: 18) {
                Snap.shared.blowAction = all[$0]
            })
        }
        if LidLight.shared.available {
            screen.append(toggleRow("Brightness by lid", LidLight.shared.on) { LidLight.shared.on = $0 })
        }
        section("Screen", screen)

        if Knocks.shared.available {
            var taps: [NSView] = []
            taps.append(toggleRow("Knocks on the Mac", Knocks.shared.on) { Knocks.shared.on = $0 })
            if Knocks.shared.on {
                let all = KnockAction.allCases
                for count in Knocks.counts {
                    taps.append(choiceRow("\(count) knocks", all.map(\.title), all.firstIndex(of: Knocks.shared.action(count)) ?? 0, indent: 18) {
                        Knocks.shared.set(count, all[$0])
                    })
                }
                taps.append(choiceRow("Sensitivity", Knocks.sensitivities, Knocks.shared.sensitivity, indent: 18) { Knocks.shared.sensitivity = $0 })
            }
            section("Knocks", taps)
        }

        views.append(divider())
        let footer = NSStackView(views: [words("⌃⌥, settings  ·  ⌃⌥/ keys", size: 13, alpha: 0.4), NSView(), button("Quit") { _ in NSApp.terminate(nil) }])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        views.append(footer)
        let stack = column(views, spacing: 12)
        stack.setCustomSpacing(26, after: views[0])
        return stack
    }
}

/// Keys: every Re app's keys at once, an app to a column.
final class KeysPopup: Popup {
    static let shared = KeysPopup(width: 1400)

    typealias Keys = [(String, String)]
    static let apps: [(name: String, parts: [(String?, Keys)])] = [
        ("Re:Desk", [
            (nil, [("⌃⌥,", "settings"), ("⌃⌥/", "these keys"), ("⌃⌘L", "lock screen"), ("⌘⇧T", "light / dark"),
                   ("⌘⇧M", "video wallpaper still / moving")]),
            ("Windows", [("⌃⌥ ← → ↑ ↓", "focus the nearest window"), ("⌃⌥⇧ ← → ↑ ↓", "trade places with it"),
                         ("⌃⌥⌘ ← → ↑ ↓", "resize the window"), ("⌃⌥T", "tiling on / off"), ("⌃⌥Space", "next arrangement"),
                         ("⌃⌥↩", "the window becomes the main one")]),
            ("On the desk", [("F / S / P / N", "ReFile / ReSurf / RePlay / ReNote")]),
            ("Desktops", [("⌥⌘↑ / ⌥⌘↓", "the desktop above / below"), ("⌥⌘⇧↑ / ⌥⌘⇧↓", "take the window there")]),
            ("In the Re apps", [("⌘1 … ⌘8", "an arrangement"), ("⌘0", "almost full on / off"), ("⌘9", "flush on / off"), ("⌘↑ / ⌘↓", "fill the screen / the desk"),
                                ("⌘⇧↑ / ⌘⇧↓", "previous / next wallpaper")]),
            ("On the Mac", [("2 – 5 knocks", "as chosen in settings"), ("snap or clap", "lock screen")]),
        ]),
        ("Re:File", [
            (nil, [("↑ / ↓", "select"), ("→ / Enter", "open"), ("←", "the folder above"), ("/", "search"), ("C / L", "views"), ("⌃⌘1 – 4", "sort: name, kind, date, size"),
                   ("N", "new folder"), ("I", "info"), ("Backspace", "move to the Trash")]),
        ]),
        ("Re:Surf", [
            (nil, [("⌘T", "new tab"), ("⌘L", "address"), ("⌘W", "close tab"), ("⌃Tab", "next tab"), ("⌘[ / ⌘]", "back / forward"),
                   ("⌘R", "reload"), ("⌘D", "favourite"), ("⌘F", "video fills the page"), ("⌘E", "e-ink"), ("⌘I", "info"), ("⌘J", "ReChat")]),
            ("Search", [("A / I / V", "all / images / videos"), ("F", "the same in Marginalia"), ("← / →", "previous / next page"),
                        ("↑ / ↓  Enter", "choose, open")]),
            ("ReChat", [("Enter", "send"), ("⇧Enter", "new line")]),
        ]),
        ("Re:Play", [
            (nil, [("Space", "play / pause"), ("F7 F8 F9", "previous / play / next"), ("↑ ↓ ← →", "move"), ("Enter", "play"),
                   ("1 – 4", "tabs"), ("/", "search"), ("S / R", "shuffle / repeat"), ("Q", "queue"), ("N", "new playlist"), ("I", "info"), ("O", "open a video")]),
        ]),
        ("Re:Note", [
            ("Notes", [("↑ / ↓", "select a note"), ("← / →", "another space"), ("N", "new note"), ("E / Enter", "edit"),
                       ("/  ⌘F", "search"), ("Backspace", "delete"), ("Esc", "home")]),
            ("A note", [("⌘S", "save"), ("⌥← / ⌥→", "previous / next note"), ("Esc", "back")]),
            ("Writing", [("⌘B", "highlight"), ("⌘Z", "undo"), ("⌘⇧Z  ⌃Y", "redo")]),
        ]),
    ]

    override func width(on screen: NSRect) -> CGFloat { min(1500, screen.width - 80) }

    override func build() -> NSView {
        var columns: [NSView] = []
        for app in Self.apps {
            var views: [NSView] = [heading(app.name), divider()]
            for (name, list) in app.parts {
                if let name { views.append(caption(name)) }
                for (key, what) in list {
                    let line = NSStackView(views: [keys(key), NSView(), words(what, size: 14)])
                    line.orientation = .horizontal
                    line.alignment = .firstBaseline
                    line.spacing = 12
                    views.append(line)
                }
            }
            let column = column(views, spacing: 9)
            for (i, view) in views.enumerated() where view is NSTextField && i > 0 { column.setCustomSpacing(9, after: views[i - 1]) }
            column.setCustomSpacing(16, after: views[0])
            column.setCustomSpacing(16, after: views[1])
            columns.append(column)
        }
        let row = NSStackView(views: columns)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 44
        let footer = words("⌃⌥/ or Esc closes  ·  ⌃⌥, settings", size: 13, alpha: 0.4)
        let all = NSStackView(views: [row, footer])
        all.orientation = .vertical
        all.alignment = .centerX
        all.spacing = 30
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: all.widthAnchor).isActive = true
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
        // the wallpapers across the top, where the day's line was (the day is out for now)
        windows.append(DeskWindow(view: wallpapers) { [wallpapers] l in
            let width = l.area.width * 0.24
            let count = CGFloat(max(Wallpapers.all.count - 1, 1))
            wallpapers.spacing = min(52, width / count)
            return NSRect(x: l.area.midX - width / 2 - wallpapers.spacing / 2, y: l.dayLine - 9,
                          width: width + wallpapers.spacing, height: 18)
        })
        // the desktops on the left edge, around its middle (room for eight)
        windows.append(DeskWindow(view: DesktopsView()) { l in
            let height = DesktopsView.spacing * 8
            return NSRect(x: l.leftX - columnWidth / 2, y: l.area.midY - height / 2, width: columnWidth, height: height)
        })
        windows.append(DeskWindow(view: battery) { l in
            NSRect(x: l.rightX - columnWidth / 2, y: l.area.midY - l.sideLength / 2, width: columnWidth, height: l.sideLength)
        })
        // the day line's twin at the bottom, between PLAY and NOTE; only to look at, clicks go through
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
            self?.showPieces()
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
        LidLight.shared.start()
        Knocks.shared.start()
        Snap.shared.start()
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
        windows.forEach { $0.redrawFading() }
        stripWindow.redrawFading()
        // an open popup turns with it
        for popup in [SettingsPopup.shared, KeysPopup.shared] as [Popup] where popup.isVisible { popup.refresh() }
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
        showPieces(animated: false)
        LiveWallpaper.shared.layout()
        WallpaperBlur.refresh()
        Tiler.shared.retile()
        showBar()
    }

    /// The desk's own pieces (the corner words, the dots, the day line, the battery, the wave): gone in
    /// Almost Full, where only the apps across the top stay; they fade out and back.
    private func showPieces(animated: Bool = true) {
        let hidden = Tiler.shared.on && Tiler.shared.almostFull
        for window in windows {
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
        guard full && menuBarHides, let screen = NSScreen.screens.first, screen.frame.maxY > screen.visibleFrame.maxY else {
            return stripWindow.orderOut(nil)
        }
        let frame = NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY,
                           width: screen.frame.width, height: screen.frame.maxY - screen.visibleFrame.maxY)
        stripWindow.setFrame(frame, display: true)
        stripWindow.orderFront(nil)
    }
}

// ReDesk --lid-test: four seconds of the motion sensor, written to Knocks.log; no desk
if CommandLine.arguments.contains("--lid-test") {
    Knocks.shared.logSeconds = true
    Knocks.shared.testing = { Knocks.log(String(format: "felt %.3fg", $0)) }
    Knocks.shared.start()
    RunLoop.main.run(until: Date().addingTimeInterval(4.2))
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
    exit(0)
}

let app = NSApplication.shared
let desk = Desk()
app.delegate = desk
app.setActivationPolicy(.accessory)
app.run()
