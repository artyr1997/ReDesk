import AppKit
import CoreLocation
import CoreWLAN
import Darwin
import IOKit
import IOKit.ps

// ── the dashboard ──
// ⌃⌥D (anywhere): a popup in the desk's look, the Mac as it is now, every second while it is open. Three
// columns: the processors and the memory, the disk and the battery, Wi-Fi (its network, how fast, the ones
// near to join with a click); under them how long the Mac has been on and what works it hardest. Drawn in the
// desk's ink: spaced small captions, a large figure, thin bars as the desk's gauges, the last minute as a line.

/// What the dashboard shows, read from the system.
final class SystemStats {
    // the processors: busy share now, and over the last minute
    private(set) var cpu: Double = 0
    private(set) var cpuHistory: [Double] = []
    private var lastTicks: (busy: UInt64, total: UInt64)?
    let cores = ProcessInfo.processInfo.activeProcessorCount

    // the memory, in bytes
    private(set) var memApp: UInt64 = 0
    private(set) var memWired: UInt64 = 0
    private(set) var memCompressed: UInt64 = 0
    private(set) var memHistory: [Double] = []
    let memTotal = ProcessInfo.processInfo.physicalMemory
    var memUsed: UInt64 { memApp + memWired + memCompressed }
    private(set) var swapUsed: UInt64 = 0
    /// 1 normal, 2 warning, 4 critical
    private(set) var pressure: Int32 = 1

    // the disk
    private(set) var diskFree: Int64 = 0
    private(set) var diskTotal: Int64 = 0
    private(set) var diskName = ""

    // the network: bytes a second in and out, the last minute of each
    private(set) var down: Double = 0
    private(set) var up: Double = 0
    private(set) var downHistory: [Double] = []
    private(set) var upHistory: [Double] = []
    private var lastBytes: (inb: UInt64, outb: UInt64, at: Date)?

    static let keep = 60

    func sample() {
        sampleCPU()
        sampleMemory()
        sampleDisk()
        sampleNetwork()
    }

    private func push(_ v: Double, _ list: inout [Double]) {
        list.append(v)
        if list.count > Self.keep { list.removeFirst(list.count - Self.keep) }
    }

    private func sampleCPU() {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for i in 0..<Int(count) {
            let base = Int(CPU_STATE_MAX) * i
            func t(_ s: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(s)])) }
            let user = t(CPU_STATE_USER), system = t(CPU_STATE_SYSTEM), nice = t(CPU_STATE_NICE), idle = t(CPU_STATE_IDLE)
            busy += user + system + nice
            total += user + system + nice + idle
        }
        if let last = lastTicks, total > last.total {
            cpu = min(1, max(0, Double(busy &- last.busy) / Double(total - last.total)))
            push(cpu, &cpuHistory)
        }
        lastTicks = (busy, total)
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        // as Activity Monitor counts the memory used: the apps' (less what can be purged), wired, compressed
        let inner = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
        memApp = (inner > purgeable ? inner - purgeable : 0) * page
        memWired = UInt64(stats.wire_count) * page
        memCompressed = UInt64(stats.compressor_page_count) * page
        push(Double(memUsed) / Double(max(memTotal, 1)), &memHistory)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { swapUsed = swap.xsu_used }
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { pressure = level }
    }

    private func sampleDisk() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeNameKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
        diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        diskName = v.volumeName ?? ""
    }

    private func sampleNetwork() {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return }
        defer { freeifaddrs(first) }
        var inb: UInt64 = 0, outb: UInt64 = 0
        var p = first
        while let a = p {
            p = a.pointee.ifa_next
            guard let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.pointee.ifa_data else { continue }
            let name = String(cString: a.pointee.ifa_name)
            // the Mac's own ways out: not the loopback, nor the system's tunnels and bridges
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            inb += UInt64(d.ifi_ibytes)
            outb += UInt64(d.ifi_obytes)
        }
        let now = Date()
        if let last = lastBytes {
            let dt = max(0.2, now.timeIntervalSince(last.at))
            // (the counters wrap at 4 GB: a step back counts as nothing)
            down = inb >= last.inb ? Double(inb - last.inb) / dt : 0
            up = outb >= last.outb ? Double(outb - last.outb) / dt : 0
            push(down, &downHistory)
            push(up, &upHistory)
        }
        lastBytes = (inb, outb, now)
    }
}

/// The battery as the system tells it (IOKit's AppleSmartBattery, the power sources); nil on a Mac without one.
struct BatteryInfo {
    var level: Double
    var charging: Bool
    var plugged: Bool
    var full: Bool
    /// minutes to empty (or to full while charging); nil while the system works it out
    var minutes: Int?
    var cycles: Int?
    /// the most it holds now, of what it held new
    var health: Double?
    /// watts in (charging) or out
    var watts: Double?
    var celsius: Double?

    static func read() -> BatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var found: BatteryInfo?
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let now = d[kIOPSCurrentCapacityKey] as? Double, let max = d[kIOPSMaxCapacityKey] as? Double, max > 0 else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let time = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            found = BatteryInfo(level: min(now / max, 1), charging: charging, plugged: plugged, full: d[kIOPSIsChargedKey] as? Bool ?? false,
                                minutes: time.flatMap { $0 > 0 ? $0 : nil })
        }
        guard var battery = found else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any] {
                func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
                battery.cycles = int("CycleCount")
                if let raw = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity"), let design = int("DesignCapacity"), design > 0 {
                    battery.health = min(1, Double(raw) / Double(design))
                }
                if let volts = int("Voltage"), let amps = (d["InstantAmperage"] as? NSNumber) ?? (d["Amperage"] as? NSNumber) {
                    // (a negative current comes as a large unsigned number)
                    let ma = Double(Int64(bitPattern: amps.uint64Value))
                    battery.watts = abs(Double(volts) * ma) / 1_000_000
                }
                if let t = int("Temperature") { battery.celsius = Double(t) / 100 }
            }
        }
        return battery
    }
}

/// Wi-Fi: the network joined, the ones near (looked for now and then, away from the main thread), joining one.
/// The networks' names need Location (the system keeps them from apps without it): asked for once, from here.
final class WiFi: NSObject, CLLocationManagerDelegate {
    struct Near {
        let ssid: String
        let rssi: Int
        let open: Bool
        let known: Bool
    }

    private let client = CWWiFiClient.shared()
    private var location: CLLocationManager?
    private(set) var near: [Near] = []
    private(set) var scanning = false
    private var scannedAt = Date.distantPast
    /// what joining said ("joining…", a failure), shown a moment
    var status: String?
    var changed: () -> Void = {}

    var interface: CWInterface? { client.interface() }
    var on: Bool { interface?.powerOn() ?? false }
    var ssid: String? { interface?.ssid() }
    var rssi: Int { interface?.rssiValue() ?? 0 }
    var rate: Double { interface?.transmitRate() ?? 0 }

    var locationAllowed: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .authorizedAlways || status == .authorized
    }
    var locationDenied: Bool {
        let status = CLLocationManager().authorizationStatus
        return status == .denied || status == .restricted
    }

    /// asks for Location (the system's own question), or opens its settings once it was said no to
    func askLocation() {
        if locationDenied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
            return
        }
        let manager = CLLocationManager()
        manager.delegate = self
        location = manager
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        scannedAt = .distantPast
        scan()
        changed()
    }

    func setPower(_ on: Bool) {
        try? interface?.setPower(on)
        near = []
        if on { scannedAt = .distantPast; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.scan() } }
        changed()
    }

    /// the networks near, every 20 seconds at most
    func scan() {
        guard !scanning, on, Date().timeIntervalSince(scannedAt) > 20, let interface else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let found = (try? interface.scanForNetworks(withName: nil)) ?? []
            let known = Set((interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []).compactMap(\.ssid))
            var best: [String: Near] = [:]
            for n in found {
                guard let ssid = n.ssid, !ssid.isEmpty else { continue }
                let item = Near(ssid: ssid, rssi: n.rssiValue, open: n.supportsSecurity(.none), known: known.contains(ssid))
                if (best[ssid]?.rssi ?? -999) < item.rssi { best[ssid] = item }
            }
            let list = best.values.sorted { $0.rssi > $1.rssi }
            DispatchQueue.main.async {
                self.near = list
                self.scanning = false
                self.scannedAt = Date()
                self.changed()
            }
        }
    }

    /// joins a network: a known or open one as it is, another with the password given (the system's own
    /// networksetup, which keeps it in the keychain as joining from the menu bar does)
    func join(_ ssid: String, password: String?) {
        guard let name = interface?.interfaceName else { return }
        status = tr("joining") + " " + ssid + " …"
        changed()
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            p.arguments = ["-setairportnetwork", name, ssid] + (password.map { [$0] } ?? [])
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try? p.run()
            p.waitUntilExit()
            let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                // networksetup says nothing when it joined
                self.status = said.isEmpty ? nil : tr("couldn't join") + " " + ssid
                self.changed()
                if self.status != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.status = nil; self.changed() }
                }
            }
        }
    }
}

final class DashboardPopup: Popup {
    static let shared = DashboardPopup(width: 1000)
    private let board = DashboardView()

    override func width(on screen: NSRect) -> CGFloat { min(1000, screen.width - 80) }
    override func build() -> NSView { board }

    override func show() {
        super.show()
        board.start()
    }

    override func close() {
        board.stop()
        super.close()
    }

    /// --render-popups: a few seconds read, as if it had been open
    func warmUp() {
        board.start()
        let until = Date().addingTimeInterval(3.5)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}

/// The dashboard itself, drawn: what it shows read every second while it is open.
final class DashboardView: NSView, NSTextFieldDelegate {
    private let stats = SystemStats()
    private let wifi = WiFi()
    private var battery: BatteryInfo?
    private var top: [(name: String, cpu: Double)] = []
    private var timer: Timer?
    private var tick = 0
    /// the places to click, found as they were drawn
    private var hits: [(NSRect, () -> Void)] = []
    /// a network's password, typed in its row
    private var password: NSSecureTextField?
    private var asking: String?

    static let height: CGFloat = 560

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        wifi.changed = { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { nil }

    func start() {
        stop()
        stats.sample()
        battery = BatteryInfo.read()
        readTop()
        wifi.scan()
        needsDisplay = true
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        closePassword()
    }

    private func step() {
        tick += 1
        stats.sample()
        if tick % 5 == 0 { battery = BatteryInfo.read() }
        if tick % 3 == 0 { readTop() }
        wifi.scan()
        needsDisplay = true
    }

    /// what works the processors hardest, the first three (ps, away from the main thread)
    private func readTop() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-Aceo", "pcpu=,comm=", "-r"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(3)
            let list = lines.compactMap { line -> (String, Double)? in
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let cpu = Double(parts[0]) else { return nil }
                return (String(parts[1]), cpu)
            }
            DispatchQueue.main.async { self?.top = list.map { (name: $0.0, cpu: $0.1) } }
        }
    }

    // ── drawn ──

    private let gap: CGFloat = 44
    private var colW: CGFloat { (bounds.width - gap * 2) / 3 }

    override func draw(_ dirtyRect: NSRect) {
        hits = []
        let head = NSAttributedString(string: tr("System").uppercased(), attributes: [.font: Popup.noto(18), .foregroundColor: Popup.text, .kern: 7.2])
        head.draw(at: NSPoint(x: 0, y: 0))
        let host = Host.current().localizedName ?? ""
        let hostText = NSAttributedString(string: host, attributes: [.font: Popup.kurale(13), .foregroundColor: Popup.text.withAlphaComponent(0.5)])
        hostText.draw(at: NSPoint(x: bounds.width - hostText.size().width, y: 6))

        let y0: CGFloat = 64, cardH: CGFloat = 200, y1 = y0 + cardH + 40
        let x = [0, colW + gap, (colW + gap) * 2]
        drawCPU(NSRect(x: x[0], y: y0, width: colW, height: cardH))
        drawMemory(NSRect(x: x[0], y: y1, width: colW, height: cardH))
        drawDisk(NSRect(x: x[1], y: y0, width: colW, height: cardH))
        drawBattery(NSRect(x: x[1], y: y1, width: colW, height: cardH))
        drawWiFi(NSRect(x: x[2], y: y0, width: colW, height: y1 + cardH - y0))
        // a thin line down between the columns, as the popups' dividers
        Popup.line.withAlphaComponent(0.15).setFill()
        for cx in [colW + gap / 2, colW * 2 + gap * 1.5] { NSRect(x: cx, y: y0, width: 1, height: y1 + cardH - y0).fill() }
        drawFoot(y: y1 + cardH + 28)
    }

    private func text(_ s: String, _ font: NSFont, alpha: CGFloat = 1, kern: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: Popup.text.withAlphaComponent(alpha), .kern: kern])
    }

    /// a card's name: small, spaced, quiet (and something on its right, if given)
    private func caption(_ s: String, at p: NSPoint) {
        text(tr(s).uppercased(), Popup.noto(11), alpha: 0.6, kern: 2.2).draw(at: p)
    }

    /// the large figure and its unit after it, smaller
    private func figure(_ value: String, _ unit: String, at p: NSPoint) {
        let v = text(value, Popup.noto(34), alpha: 0.95)
        v.draw(at: p)
        if !unit.isEmpty {
            let u = text(unit, Popup.noto(13), alpha: 0.55, kern: 1)
            u.draw(at: NSPoint(x: p.x + v.size().width + 8, y: p.y + v.size().height - u.size().height - 7))
        }
    }

    private func detail(_ s: String, at p: NSPoint, width: CGFloat, alpha: CGFloat = 0.6) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: s, attributes: [.font: Popup.kurale(13), .foregroundColor: Popup.text.withAlphaComponent(alpha), .paragraphStyle: style])
            .draw(with: NSRect(x: p.x, y: p.y, width: width, height: 20), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// the last minute as a line, the space under it faintly filled
    private func spark(_ values: [Double], in r: NSRect, max top: Double = 1) {
        Popup.line.withAlphaComponent(0.18).setFill()
        NSRect(x: r.minX, y: r.maxY, width: r.width, height: 1).fill()
        guard values.count > 1 else { return }
        let step = r.width / CGFloat(SystemStats.keep - 1)
        let start = r.maxX - step * CGFloat(values.count - 1)
        let line = NSBezierPath()
        for (i, v) in values.enumerated() {
            let p = NSPoint(x: start + step * CGFloat(i), y: r.maxY - r.height * CGFloat(min(1, v / max(top, 0.0001))))
            i == 0 ? line.move(to: p) : line.line(to: p)
        }
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: r.maxX, y: r.maxY))
        fill.line(to: NSPoint(x: start, y: r.maxY))
        fill.close()
        NSColor(white: 1, alpha: 0.07).setFill()
        fill.fill()
        line.lineWidth = 1.2
        line.lineJoinStyle = .round
        NSColor(white: 1, alpha: 0.55).setStroke()
        line.stroke()
        // now: a diamond at the line's end
        if let v = values.last {
            drawDiamond(at: NSPoint(x: r.maxX, y: r.maxY - r.height * CGFloat(min(1, v / max(top, 0.0001)))), color: ink(0.8))
        }
    }

    private func bar(_ filled: Double, in r: NSRect) {
        drawBar(in: NSRect(x: r.minX, y: r.minY, width: r.width, height: barWidth), filled: filled, vertical: false)
    }

    private func gb(_ bytes: Double) -> String {
        let g = bytes / 1_073_741_824
        return g >= 100 ? String(format: "%.0f", g) : String(format: "%.1f", g)
    }

    private func speed(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 1024 { return String(format: "%.0f KB/s", bps / 1024) }
        return String(format: "%.0f B/s", bps)
    }

    private func drawCPU(_ r: NSRect) {
        caption("Processors", at: r.origin)
        figure(String(format: "%.0f", stats.cpu * 100), "%", at: NSPoint(x: r.minX, y: r.minY + 22))
        spark(stats.cpuHistory, in: NSRect(x: r.minX, y: r.minY + 88, width: r.width, height: 56))
        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = tr("cool")
        case .fair: thermal = tr("warm")
        case .serious: thermal = tr("hot")
        case .critical: thermal = tr("too hot")
        @unknown default: thermal = ""
        }
        detail("\(stats.cores) " + tr("cores") + String(format: " · %@ %.2f · ", tr("load"), load[0]) + thermal,
               at: NSPoint(x: r.minX, y: r.minY + 160), width: r.width)
    }

    private func drawMemory(_ r: NSRect) {
        caption("Memory", at: r.origin)
        figure(gb(Double(stats.memUsed)), tr("of") + " " + gb(Double(stats.memTotal)) + " GB", at: NSPoint(x: r.minX, y: r.minY + 22))
        spark(stats.memHistory, in: NSRect(x: r.minX, y: r.minY + 88, width: r.width, height: 56))
        let pressure = stats.pressure >= 4 ? tr("pressure high") : stats.pressure >= 2 ? tr("pressure rising") : tr("pressure low")
        detail(tr("apps") + " \(gb(Double(stats.memApp))) · " + tr("wired") + " \(gb(Double(stats.memWired))) · " + tr("compressed") + " \(gb(Double(stats.memCompressed)))",
               at: NSPoint(x: r.minX, y: r.minY + 160), width: r.width)
        detail(pressure + (stats.swapUsed > 0 ? " · swap \(gb(Double(stats.swapUsed))) GB" : ""), at: NSPoint(x: r.minX, y: r.minY + 180), width: r.width, alpha: 0.45)
    }

    private func drawDisk(_ r: NSRect) {
        caption("Disk", at: r.origin)
        figure(gb(Double(stats.diskFree)), "GB " + tr("free"), at: NSPoint(x: r.minX, y: r.minY + 22))
        let used = stats.diskTotal > 0 ? 1 - Double(stats.diskFree) / Double(stats.diskTotal) : 0
        bar(used, in: NSRect(x: r.minX, y: r.minY + 112, width: r.width, height: 4))
        let pct = text(String(format: "%.0f%% ", used * 100) + tr("used"), Popup.noto(11), alpha: 0.5, kern: 1.5)
        pct.draw(at: NSPoint(x: r.maxX - pct.size().width, y: r.minY + 124))
        detail(tr("of") + " \(gb(Double(stats.diskTotal))) GB · \(stats.diskName)", at: NSPoint(x: r.minX, y: r.minY + 160), width: r.width)
    }

    private func drawBattery(_ r: NSRect) {
        caption("Battery", at: r.origin)
        guard let b = battery else {
            figure("—", "", at: NSPoint(x: r.minX, y: r.minY + 22))
            detail(tr("no battery: on power"), at: NSPoint(x: r.minX, y: r.minY + 160), width: r.width)
            return
        }
        figure(String(format: "%.0f", b.level * 100), "%", at: NSPoint(x: r.minX, y: r.minY + 22))
        bar(b.level, in: NSRect(x: r.minX, y: r.minY + 112, width: r.width, height: 4))
        // charging: a diamond breathing at the bar's end
        if b.charging {
            let phase = 0.5 + 0.5 * cos(Double(tick) * .pi / 2)
            drawDiamond(at: NSPoint(x: r.minX + r.width * CGFloat(b.level), y: r.minY + 112 + barWidth / 2), color: ink(0.4 + 0.5 * phase))
        }
        var state: String
        if b.full { state = tr("full") } else if b.charging { state = tr("charging") } else if b.plugged { state = tr("on power") } else { state = tr("on battery") }
        if let m = b.minutes, !b.full { state += " · " + String(format: "%d:%02d", m / 60, m % 60) + " " + (b.charging ? tr("to full") : tr("left")) }
        let state2 = text(state, Popup.noto(11), alpha: 0.5, kern: 1.5)
        state2.draw(at: NSPoint(x: r.maxX - state2.size().width, y: r.minY + 124))
        var parts: [String] = []
        if let h = b.health { parts.append(tr("health") + String(format: " %.0f%%", h * 100)) }
        if let c = b.cycles { parts.append("\(c) " + tr("cycles")) }
        if let w = b.watts, w > 0.05 { parts.append(String(format: "%.1f W", w)) }
        if let t = b.celsius { parts.append(String(format: "%.0f°", t)) }
        detail(parts.joined(separator: " · "), at: NSPoint(x: r.minX, y: r.minY + 160), width: r.width)
    }

    private func drawWiFi(_ r: NSRect) {
        caption("Wi-Fi", at: r.origin)
        // ON / OFF on the caption's line
        let on = wifi.on
        let toggle = text(tr(on ? "On" : "Off").uppercased(), Popup.noto(11), alpha: on ? 0.9 : 0.45, kern: 2.2)
        let tr_ = NSRect(x: r.maxX - toggle.size().width, y: r.minY, width: toggle.size().width, height: toggle.size().height)
        toggle.draw(at: tr_.origin)
        hits.append((tr_.insetBy(dx: -8, dy: -6), { [weak self] in self?.wifi.setPower(!on) }))

        var y = r.minY + 22
        if !on {
            figure(tr("Off"), "", at: NSPoint(x: r.minX, y: y))
            return
        }
        let name = wifi.ssid
        let shown = name ?? (wifi.rssi != 0 ? tr("joined") : tr("not joined"))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: shown, attributes: [.font: Popup.noto(26), .foregroundColor: Popup.text.withAlphaComponent(0.95), .paragraphStyle: style])
            .draw(with: NSRect(x: r.minX, y: y, width: r.width, height: 40), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        y += 44
        if wifi.rssi != 0 {
            detail(String(format: "%d dBm · %.0f Mb/s", wifi.rssi, wifi.rate), at: NSPoint(x: r.minX, y: y), width: r.width)
        }
        y += 30
        // how fast: down and up, the last minute of each
        let top = max(stats.downHistory.max() ?? 0, stats.upHistory.max() ?? 0, 64 * 1024)
        let half = (r.width - 16) / 2
        caption("↓ " + speed(stats.down), at: NSPoint(x: r.minX, y: y))
        caption("↑ " + speed(stats.up), at: NSPoint(x: r.minX + half + 16, y: y))
        spark(stats.downHistory, in: NSRect(x: r.minX, y: y + 20, width: half, height: 36), max: top)
        spark(stats.upHistory, in: NSRect(x: r.minX + half + 16, y: y + 20, width: half, height: 36), max: top)
        y += 78

        caption("Near", at: NSPoint(x: r.minX, y: y))
        if wifi.scanning { text("⋯", Popup.noto(11), alpha: 0.5).draw(at: NSPoint(x: r.minX + 60, y: y)) }
        y += 24
        if let status = wifi.status {
            detail(status, at: NSPoint(x: r.minX, y: y), width: r.width, alpha: 0.8)
            y += 24
        }
        if name == nil && !wifi.locationAllowed {
            // the names kept from ReDesk until Location is allowed
            detail(tr("The networks' names need Location."), at: NSPoint(x: r.minX, y: y), width: r.width)
            let allow = text(tr(wifi.locationDenied ? "Open settings" : "Allow").uppercased(), Popup.noto(12), alpha: 0.9, kern: 2.4)
            let ar = NSRect(x: r.minX, y: y + 26, width: allow.size().width, height: allow.size().height)
            allow.draw(at: ar.origin)
            hits.append((ar.insetBy(dx: -8, dy: -6), { [weak self] in self?.wifi.askLocation() }))
            return
        }
        let rowH: CGFloat = 26
        for n in wifi.near where y + rowH <= r.maxY {
            let current = n.ssid == name
            let row = NSRect(x: r.minX, y: y, width: r.width, height: rowH)
            if current { drawDiamond(at: NSPoint(x: row.minX + 4, y: row.midY), color: ink(0.8)) }
            let label = NSAttributedString(string: n.ssid + (n.open || n.known ? "" : "  ·"), attributes: [
                .font: Popup.kurale(14), .foregroundColor: Popup.text.withAlphaComponent(current ? 0.95 : 0.7), .paragraphStyle: style,
            ])
            if asking == n.ssid {
                // its password's field stands in the row
                text(n.ssid, Popup.kurale(14), alpha: 0.5).draw(at: NSPoint(x: row.minX + 18, y: row.minY + 3))
            } else {
                label.draw(with: NSRect(x: row.minX + 18, y: row.minY + 3, width: row.width - 70, height: 20), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            // the signal: four short dashes, as many strong as it is strong
            let bars = n.rssi > -55 ? 4 : n.rssi > -65 ? 3 : n.rssi > -75 ? 2 : 1
            for i in 0..<4 {
                let h = CGFloat(4 + i * 3)
                NSColor(white: 1, alpha: i < bars ? 0.6 : 0.18).setFill()
                NSRect(x: row.maxX - 28 + CGFloat(i) * 7, y: row.midY + 7 - h, width: 3, height: h).fill()
            }
            if !current {
                hits.append((row, { [weak self] in self?.tapped(n) }))
            }
            y += rowH
        }
        if wifi.near.isEmpty && !wifi.scanning {
            detail(tr("none found yet"), at: NSPoint(x: r.minX, y: y), width: r.width, alpha: 0.45)
        }
    }

    private func drawFoot(y: CGFloat) {
        Popup.line.withAlphaComponent(0.15).setFill()
        NSRect(x: 0, y: y - 14, width: bounds.width, height: 1).fill()
        let up = Int(ProcessInfo.processInfo.systemUptime)
        let days = up / 86400, hours = up % 86400 / 3600, minutes = up % 3600 / 60
        let upText = days > 0 ? "\(days) d \(hours) h" : hours > 0 ? "\(hours) h \(minutes) m" : "\(minutes) m"
        caption("On for", at: NSPoint(x: 0, y: y))
        text(upText, Popup.kurale(13), alpha: 0.75).draw(at: NSPoint(x: 80, y: y - 2))
        var x: CGFloat = colW + gap
        caption("Hardest at work", at: NSPoint(x: x, y: y))
        x += 150
        for p in top {
            let t = text("\(p.name)  " + String(format: "%.0f%%", p.cpu), Popup.kurale(13), alpha: 0.75)
            t.draw(at: NSPoint(x: x, y: y - 2))
            x += t.size().width + 28
        }
    }

    // ── clicked ──

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = hits.first(where: { $0.0.contains(p) }) { hit.1() }
    }

    override func resetCursorRects() {
        for (r, _) in hits { addCursorRect(r, cursor: .pointingHand) }
    }

    private func tapped(_ n: WiFi.Near) {
        closePassword()
        if n.open || n.known { return wifi.join(n.ssid, password: nil) }
        // a network not known with a password: its field in its row
        asking = n.ssid
        let field = NSSecureTextField(frame: .zero)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Popup.text
        field.font = Popup.kurale(14)
        field.placeholderAttributedString = NSAttributedString(string: tr("password"), attributes: [.font: Popup.kurale(14), .foregroundColor: Popup.text.withAlphaComponent(0.35)])
        field.delegate = self
        password = field
        placePassword()
        addSubview(field)
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    /// the field over its network's row, after its name
    private func placePassword() {
        guard let field = password, let asking, let i = wifi.near.firstIndex(where: { $0.ssid == asking }) else { return }
        let x = (colW + gap) * 2
        let name = text(asking, Popup.kurale(14)).size().width
        // the rows begin under the speeds and NEAR (as drawWiFi lays them)
        let rowsTop: CGFloat = 64 + 22 + 44 + 30 + 78 + 24 + (wifi.status != nil ? 24 : 0)
        let left = min(x + 18 + name + 14, x + colW - 140)
        field.frame = NSRect(x: left, y: rowsTop + CGFloat(i) * 26 + 3, width: x + colW - 36 - left, height: 20)
    }

    private func closePassword() {
        password?.removeFromSuperview()
        password = nil
        asking = nil
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), let field = password, let ssid = asking {
            let typed = field.stringValue
            closePassword()
            if !typed.isEmpty { wifi.join(ssid, password: typed) }
            window?.makeFirstResponder(self)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            closePassword()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    override func layout() {
        super.layout()
        placePassword()
    }
}
