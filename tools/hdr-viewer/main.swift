// Standalone test for HdrStreamRenderer: plays an Annex-B HEVC Main10 HDR10
// elementary stream in a window, one access unit per 1/60 s, looping.
// Usage: hdr-viewer [path/to/stream.hevc]
import AppKit
import AVFoundation

func splitAccessUnits(_ data: Data) -> [Data] {
    var units: [Data] = []
    var current: [Data] = []
    var hasSlice = false
    let startCode = Data([0, 0, 0, 1])
    func flush() {
        if hasSlice {
            var au = Data()
            for nal in current { au.append(startCode); au.append(nal) }
            units.append(au)
        }
        current = []
        hasSlice = false
    }
    for nal in HdrStreamRenderer.splitAnnexB(data) {
        guard nal.count >= 3 else { continue }
        let type = (nal[nal.startIndex] >> 1) & 0x3F
        let isSlice = type < 32
        let firstSliceInPic = isSlice && (nal[nal.startIndex + 2] & 0x80) != 0
        let startsNewAU = (type >= 32 && type <= 35) || type == 39 || firstSliceInPic
        if startsNewAU && hasSlice { flush() }
        current.append(nal)
        if isSlice { hasSlice = true }
    }
    flush()
    return units
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let renderer = HdrStreamRenderer()
    var units: [Data] = []
    var index = 0
    var timer: DispatchSourceTimer?
    var lastReport = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let path = args.count > 1
            ? args[1]
            : URL(fileURLWithPath: args[0]).deletingLastPathComponent().appendingPathComponent("hdr10_test.hevc").path
        guard let data = FileManager.default.contents(atPath: path) else {
            print("cannot read \(path)")
            exit(1)
        }
        units = splitAccessUnits(data)
        print("loaded \(units.count) access units from \(path)")

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "HDR viewer test"
        let view = NSView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        // Layer-hosted view: assign the layer before enabling wantsLayer.
        view.layer = renderer.layer
        view.wantsLayer = true
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let screen = window.screen {
            print("screen EDR headroom now: \(screen.maximumExtendedDynamicRangeColorComponentValue), "
                + "potential: \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)")
        }

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 60))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func tick() {
        guard !units.isEmpty else { return }
        renderer.submit(units[index])
        index = (index + 1) % units.count
        if Date().timeIntervalSince(lastReport) >= 2 {
            lastReport = Date()
            let headroom = window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0
            print("enqueued \(renderer.enqueued) dropped \(renderer.dropped) "
                + "layer status \(renderer.layer.status.rawValue) EDR headroom \(headroom)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
