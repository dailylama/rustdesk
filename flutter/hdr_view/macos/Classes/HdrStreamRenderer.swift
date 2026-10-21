import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import VideoToolbox

/// Decodes Annex-B HEVC access units (Main10, BT.2020/PQ) with VideoToolbox
/// and draws them into an EDR CAMetalLayer.
///
/// In EDR a value of 1.0 is the display's own SDR white at its current
/// brightness. The shader converts PQ to nits and divides by `whiteNits`, the
/// PQ level at which the host placed its SDR white, so host white lands on the
/// Mac's white exactly. Brighter content uses the headroom macOS reports
/// (`headroom`), with a soft roll-off near the limit.
public final class HdrStreamRenderer {
    public let layer: CAMetalLayer

    /// PQ nits of the host's SDR white (host option `hdr-reference-white`).
    public var whiteNits: Float = 203

    /// Current EDR headroom of the screen (maximumExtendedDynamicRangeColorComponentValue).
    public var headroom: Float {
        get { lock.lock(); defer { lock.unlock() }; return headroomValue }
        set { lock.lock(); headroomValue = max(newValue, 1); lock.unlock() }
    }

    public private(set) var presented = 0
    public private(set) var dropped = 0

    private let lock = NSLock()
    private var headroomValue: Float = 1
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var waitingForKeyframe = true
    private var decodeErrors = 0

    public init() {
        layer = CAMetalLayer()
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        if #available(macOS 10.14.3, *) {
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        }
        layer.framebufferOnly = true
        layer.isOpaque = true
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        layer.device = device
        guard let device = device else {
            NSLog("hdr_view: no Metal device")
            return
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "hdr_vertex")
            desc.fragmentFunction = library.makeFunction(name: "hdr_fragment")
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("hdr_view: Metal pipeline failed: %@", "\(error)")
        }
    }

    deinit {
        if let session = session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes and draws one access unit. Returns false when it was dropped.
    @discardableResult
    public func submit(_ accessUnit: Data) -> Bool {
        var vps: Data?, sps: Data?, pps: Data?
        var slices: [Data] = []
        var isKey = false
        for nal in Self.splitAnnexB(accessUnit) {
            guard nal.count >= 2 else { continue }
            let type = (nal[nal.startIndex] >> 1) & 0x3F
            switch type {
            case 32: vps = nal
            case 33: sps = nal
            case 34: pps = nal
            case 35, 36, 37: break  // AUD, end of sequence, end of bitstream
            default:
                if type >= 16 && type <= 21 { isKey = true }
                slices.append(nal)
            }
        }

        if let vps = vps, let sps = sps, let pps = pps {
            let sets = [vps, sps, pps]
            if sets != parameterSets || formatDescription == nil {
                formatDescription = Self.makeFormatDescription(sets)
                parameterSets = formatDescription == nil ? [] : sets
                if let fd = formatDescription, let s = session,
                   !VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: fd) {
                    dropSession()
                }
            }
        }

        if waitingForKeyframe {
            guard isKey else {
                dropped += 1
                if dropped == 1 || dropped % 120 == 0 {
                    NSLog("hdr_view: waiting for keyframe, dropped %d", dropped)
                }
                return false
            }
            waitingForKeyframe = false
            NSLog("hdr_view: keyframe, format description %@", formatDescription == nil ? "missing" : "ok")
        }
        guard let fd = formatDescription, !slices.isEmpty,
              let sample = Self.makeSampleBuffer(slices, format: fd),
              let session = ensureSession(fd) else {
            dropped += 1
            return false
        }

        var shown = false
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self = self else { return }
            if status == noErr, let pixelBuffer = imageBuffer {
                shown = self.draw(pixelBuffer)
            } else {
                self.noteDecodeError(status)
            }
        }
        if status != noErr {
            noteDecodeError(status)
            if status == kVTInvalidSessionErr {
                dropSession()
                waitingForKeyframe = true
            }
        }
        if shown {
            presented += 1
            if presented == 1 || presented % 600 == 0 {
                NSLog("hdr_view: presented %d, drawable %.0fx%.0f, headroom %.2f, white %.0f nits",
                      presented, layer.drawableSize.width, layer.drawableSize.height,
                      headroom, whiteNits)
            }
        } else {
            dropped += 1
        }
        return shown
    }

    public func reset() {
        dropSession()
        formatDescription = nil
        parameterSets = []
        waitingForKeyframe = true
    }

    private func ensureSession(_ fd: CMVideoFormatDescription) -> VTDecompressionSession? {
        if let s = session { return s }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &created)
        if status != noErr {
            NSLog("hdr_view: VTDecompressionSessionCreate failed: %d", status)
            return nil
        }
        session = created
        NSLog("hdr_view: decoder session created")
        return created
    }

    private func dropSession() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
    }

    private func noteDecodeError(_ status: OSStatus) {
        decodeErrors += 1
        if decodeErrors == 1 || decodeErrors % 120 == 0 {
            NSLog("hdr_view: decode error %d (count %d)", status, decodeErrors)
        }
    }

    private func draw(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let pipeline = pipeline, let queue = queue, let cache = textureCache,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return false }
        let scale = layer.contentsScale
        let size = CGSize(width: (layer.bounds.width * scale).rounded(),
                          height: (layer.bounds.height * scale).rounded())
        guard size.width >= 1, size.height >= 1 else { return false }
        if layer.drawableSize != size { layer.drawableSize = size }

        guard let luma = Self.planeTexture(cache, pixelBuffer, plane: 0, format: .r16Unorm),
              let chroma = Self.planeTexture(cache, pixelBuffer, plane: 1, format: .rg16Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma),
              let drawable = layer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var params: [Float] = [whiteNits, headroom]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Float>.stride * params.count, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        // The CVMetalTextures must outlive the GPU work that reads them.
        commands.addCompletedHandler { _ in _ = (luma, chroma) }
        commands.commit()
        return true
    }

    private static func planeTexture(_ cache: CVMetalTextureCache, _ pixelBuffer: CVPixelBuffer,
                                     plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, format,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    // Full-screen triangle; 10-bit studio-range BT.2020 Y'CbCr (MSB-aligned in
    // 16-bit planes) -> PQ R'G'B' -> nits -> EDR linear BT.2020 with SDR white
    // at 1.0, then a soft knee into the current headroom.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };

    vertex VOut hdr_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.pos = float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
        o.uv = p;
        return o;
    }

    struct Params { float white_nits; float headroom; };

    static float3 pq_to_nits(float3 e) {
        const float m1 = 2610.0 / 16384.0;
        const float m2 = 2523.0 / 4096.0 * 128.0;
        const float c1 = 3424.0 / 4096.0;
        const float c2 = 2413.0 / 4096.0 * 32.0;
        const float c3 = 2392.0 / 4096.0 * 32.0;
        float3 p = pow(clamp(e, 0.0, 1.0), 1.0 / m2);
        return 10000.0 * pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
    }

    fragment float4 hdr_fragment(VOut in [[stage_in]],
                                 texture2d<float> luma [[texture(0)]],
                                 texture2d<float> chroma [[texture(1)]],
                                 constant Params& prm [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        const float k = 65535.0 / 64.0;
        float y = (luma.sample(s, in.uv).r * k - 64.0) / 876.0;
        float2 c = (chroma.sample(s, in.uv).rg * k - 512.0) / 896.0;
        float3 e = float3(y + 1.4746 * c.y,
                          y - 0.164553 * c.x - 0.571353 * c.y,
                          y + 1.8814 * c.x);
        float3 lin = pq_to_nits(e) / prm.white_nits;
        float h = max(prm.headroom, 1.0);
        float knee = max(1.0, 0.75 * h);
        float m = max(lin.r, max(lin.g, lin.b));
        if (m > knee && h > knee) {
            float mm = knee + (h - knee) * (1.0 - exp(-(m - knee) / (h - knee)));
            lin *= mm / m;
        }
        return float4(min(lin, float3(h)), 1.0);
    }
    """

    static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(prefix: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                let prefix = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                starts.append((prefix, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var nals: [Data] = []
        for (n, s) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].prefix : bytes.count
            if end > s.payload { nals.append(Data(bytes[s.payload..<end])) }
        }
        return nals
    }

    static func makeFormatDescription(_ sets: [Data]) -> CMVideoFormatDescription? {
        let ext: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]
        let buffers = sets.map { [UInt8]($0) }
        var fd: CMFormatDescription?
        let status: OSStatus = buffers[0].withUnsafeBufferPointer { v in
            buffers[1].withUnsafeBufferPointer { s in
                buffers[2].withUnsafeBufferPointer { p in
                    let pointers = [v.baseAddress!, s.baseAddress!, p.baseAddress!]
                    let sizes = [v.count, s.count, p.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        extensions: ext as CFDictionary,
                        formatDescriptionOut: &fd)
                }
            }
        }
        if status != noErr {
            NSLog("hdr_view: CMVideoFormatDescriptionCreateFromHEVCParameterSets failed: %d", status)
            return nil
        }
        return fd
    }

    static func makeSampleBuffer(_ nals: [Data], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        let length = avcc.count

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block = block else { return nil }
        status = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: length)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var size = length
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr else { return nil }
        return sample
    }
}
