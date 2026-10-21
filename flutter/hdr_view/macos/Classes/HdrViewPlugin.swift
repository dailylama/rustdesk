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

    func remove(_ key: String, ifSame renderer: HdrStreamRenderer) {
        lock.lock()
        if renderers[key] === renderer { renderers[key] = nil }
        lock.unlock()
    }
}

/// Layer-hosted view around the renderer's AVSampleBufferDisplayLayer. It
/// never takes mouse events, so Flutter keeps all input handling.
final class HdrNativeView: NSView {
    let key: String
    let renderer = HdrStreamRenderer()

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        layer = renderer.layer
        wantsLayer = true
        HdrViewRegistry.shared.set(key, renderer)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            HdrViewRegistry.shared.remove(key, ifSame: renderer)
        } else {
            HdrViewRegistry.shared.set(key, renderer)
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
        return false
    }
    let accessUnit = Data(bytes: data, count: len)
    return renderer.submit(accessUnit)
}
