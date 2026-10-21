import AVFoundation
import CoreMedia

/// Feeds Annex-B HEVC access units (Main10, BT.2020/PQ) into an
/// AVSampleBufferDisplayLayer, which decodes them with VideoToolbox and
/// presents them in EDR on HDR-capable displays.
public final class HdrStreamRenderer {
    public let layer: AVSampleBufferDisplayLayer

    /// Optional HDR10 static metadata in the CoreMedia big-endian layouts
    /// (24-byte mastering display colour volume, 4-byte content light level).
    public var masteringDisplayColorVolume: Data?
    public var contentLightLevelInfo: Data?

    public private(set) var enqueued = 0
    public private(set) var dropped = 0

    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var waitingForKeyframe = true

    public init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.isOpaque = true
    }

    /// Returns false when the access unit was dropped.
    @discardableResult
    public func submit(_ accessUnit: Data) -> Bool {
        var mustFlush = layer.status == .failed
        if #available(macOS 11.0, *) { mustFlush = mustFlush || layer.requiresFlushToResumeDecoding }
        if mustFlush {
            if let error = layer.error { NSLog("hdr_view: display layer failed: %@", "\(error)") }
            layer.flush()
            waitingForKeyframe = true
        }

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
                formatDescription = Self.makeFormatDescription(
                    sets, mdcv: masteringDisplayColorVolume, clli: contentLightLevelInfo)
                parameterSets = formatDescription == nil ? [] : sets
            }
        }

        if waitingForKeyframe {
            guard isKey else { dropped += 1; return false }
            waitingForKeyframe = false
        }
        guard let fd = formatDescription, !slices.isEmpty,
              let sample = Self.makeSampleBuffer(slices, format: fd, isKey: isKey) else {
            dropped += 1
            return false
        }
        layer.enqueue(sample)
        enqueued += 1
        return true
    }

    public func reset() {
        layer.flush()
        formatDescription = nil
        parameterSets = []
        waitingForKeyframe = true
    }

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

    static func makeFormatDescription(_ sets: [Data], mdcv: Data?, clli: Data?) -> CMVideoFormatDescription? {
        var ext: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        ]
        if let mdcv = mdcv, mdcv.count == 24 {
            ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = mdcv as CFData
        }
        if let clli = clli, clli.count == 4 {
            ext[kCMFormatDescriptionExtension_ContentLightLevelInfo] = clli as CFData
        }

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

    static func makeSampleBuffer(_ nals: [Data], format: CMVideoFormatDescription, isKey: Bool) -> CMSampleBuffer? {
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
        guard status == noErr, let sample = sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKey {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}
