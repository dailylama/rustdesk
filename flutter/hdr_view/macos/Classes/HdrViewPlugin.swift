import Cocoa
import FlutterMacOS

/// Renderers of the live HDR views, by the key Dart passed at creation
/// ("<session id>-<display>"). Rust submits frames from its video thread.
final class HdrViewRegistry {
    static let shared = HdrViewRegistry()
    private let lock = NSLock()
    private var renderers: [String: HdrStreamRenderer] = [:]

    func set(_ key: String, _ renderer: HdrStreamRenderer?) {
        lock.lock()
        renderers[key] = renderer
        lock.unlock()
    }

    func get(_ key: String) -> HdrStreamRenderer? {
        lock.lock()
        defer { lock.unlock() }
        return renderers[key]
    }

    private var missingLogged: Set<String> = []

    func logMissing(_ key: String) {
        lock.lock()
        let first = missingLogged.insert(key).inserted
        let known = Array(renderers.keys)
        lock.unlock()
        if first { hdrLog("no view for key %@, views: %@", key, known.description) }
    }

    func remove(_ key: String, ifSame renderer: HdrStreamRenderer) {
        lock.lock()
        if renderers[key] === renderer { renderers[key] = nil }
        lock.unlock()
    }
}

/// Layer-backed view with the renderer's EDR CAMetalLayer as a sublayer sized
/// to the view. It never takes mouse events, so Flutter keeps all input
/// handling. While on screen it keeps the renderer's headroom and scale
/// current.
final class HdrNativeView: NSView {
    let key: String
    let renderer = HdrStreamRenderer()
    private var headroomTimer: Timer?
    private var loggedSize = CGSize.zero

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(renderer.layer)
        HdrViewRegistry.shared.set(key, renderer)
        hdrLog("created view %@", key)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitLayer()
    }

    override func layout() {
        super.layout()
        fitLayer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fitLayer()
    }

    private func fitLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.contentsScale = window?.backingScaleFactor ?? 2
        renderer.layer.frame = bounds
        CATransaction.commit()
        if bounds.size != loggedSize {
            loggedSize = bounds.size
            hdrLog("%@ frame %.0fx%.0f scale %.1f", key, bounds.width, bounds.height,
                  renderer.layer.contentsScale)
        }
    }

    private func updateHeadroom() {
        let value = window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        renderer.headroom = Float(value)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        headroomTimer?.invalidate()
        headroomTimer = nil
        if window == nil {
            HdrViewRegistry.shared.remove(key, ifSame: renderer)
        } else {
            HdrViewRegistry.shared.set(key, renderer)
            fitLayer()
            updateHeadroom()
            headroomTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.updateHeadroom()
            }
        }
    }
}

final class HdrViewFactory: NSObject, FlutterPlatformViewFactory {
    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        let key = (args as? [String: Any])?["key"] as? String ?? "view-\(viewId)"
        return HdrNativeView(key: key)
    }

    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

public class HdrViewPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        registrar.register(HdrViewFactory(), withId: "rustdesk/hdr_view")
    }
}

/// Called from Rust with one Annex-B HEVC access unit. Returns false when no
/// view is registered under `key` or the unit was dropped.
@_cdecl("HdrViewSubmit")
public func HdrViewSubmit(_ key: UnsafePointer<CChar>, _ data: UnsafePointer<UInt8>, _ len: Int) -> Bool {
    guard len > 0, let renderer = HdrViewRegistry.shared.get(String(cString: key)) else {
        HdrViewRegistry.shared.logMissing(String(cString: key))
        return false
    }
    let accessUnit = Data(bytes: data, count: len)
    return renderer.submit(accessUnit)
}
