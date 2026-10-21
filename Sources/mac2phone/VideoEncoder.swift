import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Hardware H.264 / HEVC encoder tuned for low-latency screen sharing.
final class VideoEncoder {

    struct Format {
        var codec: UInt8           // Proto.codecH264 / codecHEVC
        var width: Int
        var height: Int
        var nalLengthSize: Int
        var parameterSets: [Data]
    }

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var lastFormatDescription: CMFormatDescription?

    private(set) var width = 0
    private(set) var height = 0

    /// (avcc sample data, isKeyframe, pts in microseconds)
    var onSample: ((Data, Bool, Int64) -> Void)?
    /// Emitted whenever the parameter sets change (first frame, resolution change).
    var onFormat: ((Format) -> Void)?

    var useHEVC = true
    var lowLatency = true
    var bitrate = 20_000_000
    var fps = 60

    var describeMode: String { "\(useHEVC ? "HEVC" : "H.264")\(lowLatency ? " low-latency" : "")" }

    var currentFormat: Format? {
        lock.lock(); defer { lock.unlock() }
        guard let fmt = lastFormatDescription else { return nil }
        return Self.makeFormat(from: fmt, width: width, height: height)
    }

    // MARK: - Session

    func prepare(width: Int, height: Int) {
        teardown()
        self.width = width
        self.height = height

        let codec: CMVideoCodecType = useHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        // Low-latency rate control is the single biggest latency win: without it
        // the encoder holds several frames back to smooth out bitrate.
        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]

        var out: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: sourceAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: VideoEncoder.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &out
        )

        guard status == noErr, let session = out else {
            if lowLatency {
                // Not every encoder/codec pair supports it; retry without.
                lowLatency = false
                prepare(width: width, height: height)
                return
            }
            if useHEVC {
                // Fall back to H.264 if HEVC is unavailable on this machine.
                useHEVC = false
                prepare(width: width, height: height)
            }
            return
        }

        func set(_ key: CFString, _ value: Any) {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }

        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)          // no B-frames: minimum latency
        set(kVTCompressionPropertyKey_ProfileLevel,
            useHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        // Keyframes are big and cause a latency spike; the client asks for one
        // whenever it actually needs it, so periodic ones can be rare.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 30)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 30)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8 * 2, 1] as CFArray)
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, false)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    func teardown() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        lock.lock()
        lastFormatDescription = nil
        lock.unlock()
    }

    func updateBitrate(_ newValue: Int) {
        bitrate = newValue
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: newValue as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [newValue / 8 * 2, 1] as CFArray)
    }

    // MARK: - Encoding

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) {
        guard let session else { return }
        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(session,
                                        imageBuffer: pixelBuffer,
                                        presentationTimeStamp: pts,
                                        duration: .invalid,
                                        frameProperties: properties,
                                        sourceFrameRefcon: nil,
                                        infoFlagsOut: nil)
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard let refcon, status == noErr, let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.handle(sampleBuffer)
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        let isKeyframe: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[CFString: Any]], let first = attachments.first else { return true }
            // Absent or false "not sync" means this IS a sync sample.
            if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { return !notSync }
            return true
        }()

        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            lock.lock()
            let changed = lastFormatDescription == nil || !CMFormatDescriptionEqual(fmt, otherFormatDescription: lastFormatDescription)
            if changed { lastFormatDescription = fmt }
            lock.unlock()
            if changed, let format = Self.makeFormat(from: fmt, width: width, height: height) {
                onFormat?(format)
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return }

        let data = Data(bytes: pointer, count: length)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = pts.isValid ? Int64(CMTimeGetSeconds(pts) * 1_000_000) : 0
        onSample?(data, isKeyframe, micros)
    }

    // MARK: - Parameter sets

    private static func makeFormat(from fmt: CMFormatDescription, width: Int, height: Int) -> Format? {
        let mediaSubType = CMFormatDescriptionGetMediaSubType(fmt)
        let isHEVC = mediaSubType == kCMVideoCodecType_HEVC

        var count = 0
        var nalLength: Int32 = 4
        let probe: OSStatus = isHEVC
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0,
                                                                 parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil,
                                                                 parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: &nalLength)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
                                                                 parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil,
                                                                 parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: &nalLength)
        guard probe == noErr, count > 0 else { return nil }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus = isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: index,
                                                                     parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size,
                                                                     parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: index,
                                                                     parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size,
                                                                     parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { continue }
            sets.append(Data(bytes: pointer, count: size))
        }
        guard !sets.isEmpty else { return nil }

        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        return Format(codec: isHEVC ? Proto.codecHEVC : Proto.codecH264,
                      width: Int(dims.width) > 0 ? Int(dims.width) : width,
                      height: Int(dims.height) > 0 ? Int(dims.height) : height,
                      nalLengthSize: Int(nalLength),
                      parameterSets: sets)
    }

    static func encodeFormatPayload(_ f: Format, displayWidth: Int, displayHeight: Int) -> Data {
        var payload = Data()
        payload.append(f.codec)
        payload.appendUInt32(UInt32(f.width))
        payload.appendUInt32(UInt32(f.height))
        payload.appendUInt32(UInt32(displayWidth))
        payload.appendUInt32(UInt32(displayHeight))
        payload.append(UInt8(f.nalLengthSize))
        payload.append(UInt8(f.parameterSets.count))
        for set in f.parameterSets {
            payload.appendUInt32(UInt32(set.count))
            payload.append(set)
        }
        return payload
    }
}
