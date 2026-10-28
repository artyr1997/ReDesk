// ReDesk: the Re apps and a few quiet gauges on the desktop.
// Corners: the apps as words (a click opens one). Left edge: the wallpapers, as dots.
// Top: the day. Right edge: the battery. Bottom: a wave while sound plays.
// Each piece is a small borderless window just above the desktop icons;
// a right click on any of them can open ReDesk at login or quit it.
import AppKit
import Carbon.HIToolbox
import CoreAudio
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

/// Gauges: the empty part at 25%, the filled part (and the chosen wallpaper) at 50%.
let faint = NSColor.white.withAlphaComponent(0.25)
let strong = NSColor.white.withAlphaComponent(0.5)
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
}

// ── wallpapers ──

enum Wallpapers {
    static let all: [URL] = {
        guard let folder = Bundle.main.url(forResource: "wallpapers", withExtension: nil) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let images = ["jpg", "jpeg", "png", "heic"]
        return files.filter { images.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    static var current: Int? {
        guard let screen = NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        // by name: the same picture may have been set from the repo's folder rather than the app's
        return all.firstIndex { $0.lastPathComponent == url.lastPathComponent }
    }

    static func show(_ index: Int) {
        guard all.indices.contains(index) else { return }
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(all[index], for: screen, options: options)
        }
        NotificationCenter.default.post(name: .wallpaperChanged, object: nil)
    }

    /// One step up or down the list, round and round.
    static func step(_ delta: Int) {
        guard !all.isEmpty else { return }
        let from = current ?? (delta > 0 ? -1 : 0)
        show((from + delta + all.count) % all.count)
    }
}

extension Notification.Name {
    static let wallpaperChanged = Notification.Name("ReDeskWallpaperChanged")
}

/// ⌃⌥↑ / ⌃⌥↓ step through the wallpapers from anywhere (Carbon hot keys need no permissions).
enum HotKeys {
    private static var refs: [EventHotKeyRef?] = []

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            Wallpapers.step(id.id == 1 ? -1 : 1)
            return noErr
        }, 1, &spec, nil, nil)
        let modifiers = UInt32(controlKey | optionKey)
        for (number, key) in [(UInt32(1), kVK_UpArrow), (UInt32(2), kVK_DownArrow)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), modifiers, EventHotKeyID(signature: OSType(0x5244_534B), id: number),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
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
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit ReDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
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
            .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 0.95 : 0.5),
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
            self, selector: #selector(refresh), name: Notification.Name("com.apple.desktop"), object: nil)
    }

    required init?(coder: NSCoder) { nil }

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

/// The mark for "this one" (the strong white) or "now" (solid #ADB5B4).
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

/// A thin rounded bar: `filled` of it in the strong white, from the left (or the bottom), the rest faint.
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
        drawDiamond(at: NSPoint(x: r + (bounds.width - diamondSize) * CGFloat(gone), y: bounds.midY), color: NSColor(srgbRed: 0xAD / 255, green: 0xB5 / 255, blue: 0xB4 / 255, alpha: 1))
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
            NSColor.white.withAlphaComponent(wave.alpha * min(1, strength * 1.6)).setStroke()
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
    }
}

final class Desk: NSObject, NSApplicationDelegate {
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
        // a little under halfway between the top of the screen and the tops of FILE and SURF
        windows.append(DeskWindow(view: day) { l in
            let width = l.area.width * 0.24
            let centre = l.topWord + (l.area.maxY - l.topWord) * 0.35 - 8
            return NSRect(x: l.area.midX - width / 2, y: centre - 9, width: width, height: 18)
        })
        windows.append(DeskWindow(view: battery) { l in
            NSRect(x: l.rightX - columnWidth / 2, y: l.area.midY - l.sideLength / 2, width: columnWidth, height: l.sideLength)
        })
        // the day line's twin at the bottom, between HEAR and NOTE; only to look at, clicks go through
        let waveWindow = DeskWindow(view: wave) { l in
            let width = l.area.width * 0.24
            let centre = l.bottomWord - (l.bottomWord - l.area.minY) * 0.35 + 8
            return NSRect(x: l.area.midX - width / 2, y: centre - 22, width: width, height: 44)
        }
        waveWindow.ignoresMouseEvents = true
        windows.append(waveWindow)

        layout()
        NotificationCenter.default.addObserver(
            self, selector: #selector(layout), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(tick), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            wallpapers, selector: #selector(WallpaperView.refresh), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // a minute of the day is a few pixels at most; the battery moves slower still
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        HotKeys.register()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [wave] _ in wave.set(playing: othersPlaying()) }
    }

    @objc private func tick() {
        day.needsDisplay = true
        battery.level = batteryLevel()
        battery.needsDisplay = true
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
