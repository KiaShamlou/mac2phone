import ReplayKit
import CoreImage
import ImageIO
import AVFoundation

/// ReplayKit owns screen capture and its visible recording indicator.
/// No remote input API is exposed by this host.
final class SampleHandler: RPBroadcastSampleHandler {
    private var server: Server?
    private var sessionIdentity: String?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var lastFrame = 0.0
    private var revocation: DispatchSourceTimer?
    private var audioFormat: (rate: Int, channels: Int)?
    private let lock = NSLock()
    private var paused = false
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            let pairing = try BroadcastState.load()
            sessionIdentity = pairing.identity
            let host = Server(port: pairing.port, pairing: pairing, nativeVideo: false)
            host.requireApproval = true
            host.consumeExternalGrant = { BroadcastState.consume($0, identity: pairing.identity) }
            host.capabilities = {
                ["platform": "ios", "touchMode": "pointer", "screen": true, "control": false,
                 "audioAvailable": true]
            }
            host.currentAudioConfig = { [weak self] in self?.lock.withLock { self?.audioFormat } ?? nil }
            try host.start(); BroadcastState.markActive(identity: pairing.identity); lock.withLock { server = host }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                BroadcastState.markActive(identity: pairing.identity)
                if (try? BroadcastState.load().identity) != pairing.identity {
                    self.end(); self.finishBroadcastWithError(NSError(domain: "Mac2Phone", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Broadcast ended. Its pairing link was revoked."]))
                }
            }
            timer.resume(); revocation = timer
        } catch { end(); finishBroadcastWithError(error) }
    }
    override func broadcastPaused() { lock.withLock { paused = true }; server?.disconnectAll() }
    override func broadcastResumed() { lock.withLock { paused = false } }
    override func broadcastFinished() {
        end()
        if (try? BroadcastState.load().identity) == sessionIdentity { BroadcastState.revoke() }
    }
    private func end() {
        revocation?.cancel(); revocation = nil
        let old = lock.withLock { let old = server; server = nil; return old }
        old?.stop()
    }
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard let host = lock.withLock({ paused ? nil : server }), host.viewers.total > 0 else { return }
        switch sampleBufferType {
        case .video:
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastFrame >= 0.1, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lastFrame = now
            autoreleasepool {
                var image = CIImage(cvPixelBuffer: buffer)
                if let orientation = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                                     attachmentModeOut: nil) as? NSNumber {
                    image = image.oriented(forExifOrientation: orientation.int32Value)
                }
                let scale = min(1, 960 / max(image.extent.width, image.extent.height))
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) {
                    host.send(jpeg: jpeg)
                }
            }
        case .audioApp: sendAudio(sampleBuffer, host: host)
        case .audioMic: break
        @unknown default: break
        }
    }
    /// ReplayKit emits linear PCM; convert float32/Int16 planar or interleaved to wire Int16.
    private func sendAudio(_ sample: CMSampleBuffer, host: Server) {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
        let format = pointer.pointee, channels = Int(format.mChannelsPerFrame)
        guard format.mFormatID == kAudioFormatLinearPCM, (1...2).contains(channels),
              format.mSampleRate >= 8000, format.mSampleRate <= 192000,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return }
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard (floating && format.mBitsPerChannel == 32) || (!floating && format.mBitsPerChannel == 16 && format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0) else { return }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard needed > 0, needed <= 4096 else { return }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { memory.deallocate() }
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        var retained: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &retained) == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let frames = CMSampleBufferGetNumSamples(sample), bytes = floating ? 4 : 2
        guard frames > 0, frames * channels * 2 <= 65536, buffers.count >= (planar ? channels : 1) else { return }
        for channel in 0..<(planar ? channels : 1) {
            guard buffers[channel].mData != nil, Int(buffers[channel].mDataByteSize) >= frames * bytes * (planar ? 1 : channels) else { return }
        }
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames { for channel in 0..<channels {
            let buffer = buffers[planar ? channel : 0].mData!
            let index = planar ? frame : frame * channels + channel
            var value: Int16
            if floating {
                let x = buffer.loadUnaligned(fromByteOffset: index * 4, as: Float.self)
                value = x.isFinite ? Int16(max(-32768, min(32767, x * 32767))) : 0
            } else { value = buffer.loadUnaligned(fromByteOffset: index * 2, as: Int16.self) }
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        } }
        let rate = Int(format.mSampleRate)
        let changed = lock.withLock { () -> Bool in
            let changed = audioFormat?.rate != rate || audioFormat?.channels != channels
            audioFormat = (rate, channels); return changed
        }
        if changed { host.sendAudioConfig(sampleRate: rate, channels: channels) }
        host.send(audio: pcm, ptsMicros: Int64(Server.hostMicros()))
    }
}
