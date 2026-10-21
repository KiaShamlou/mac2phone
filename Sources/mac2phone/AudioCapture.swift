import Foundation
import CoreAudio
import AudioToolbox
import CoreMedia
import AVFoundation
import AppKit

/// Reads whatever apps play into the Mac2Phone virtual device and hands it out
/// as small, independently playable PCM chunks.
final class AudioCapture {

    /// (Int16 interleaved stereo, pts in microseconds on the host clock)
    var onPCM: ((Data, Int64) -> Void)?

    private(set) var isRunning = false
    private(set) var sampleRate: Double = 48000
    let channels = 2

    /// 256 frames is ~5 ms. Small enough that each chunk fits one datagram, so a
    /// lost packet costs a blip rather than taking a neighbouring chunk with it.
    private let framesPerChunk = 256

    private var unit: AudioUnit?
    private var pending = [Int16]()
    private var pendingStartPTS: Int64 = 0
    private var renderBuffer: UnsafeMutablePointer<Float32>?
    private var renderCapacity = 0

    struct AudioError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let deviceUID = "Mac2PhoneAudioDevice"

    /// Reading any audio input needs microphone consent, even a virtual loopback
    /// that never touches a real microphone. Without it macOS does not fail the
    /// render — it quietly hands back silence, which is impossible to tell from
    /// a broken driver, so ask explicitly and report the answer.
    enum Permission { case granted, denied, pending }

    static func microphonePermission() -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .pending
        }
    }

    /// The consent dialog is only offered to an app that can actually show
    /// one. This is a background agent with no windows, so it has to step
    /// forward for a moment first — otherwise the request is refused on the
    /// spot and the app never even appears in the Microphone list, which has
    /// no way to add one by hand.
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    NSApp.setActivationPolicy(.accessory)
                    completion(granted)
                }
            }
        }
    }

    /// Set once a non-zero sample has been seen, so a permanently silent stream
    /// can be reported as the permission problem it almost always is.
    private(set) var sawSignal = false

    /// The virtual device only exists once the driver is installed.
    static func findDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var uid = deviceUID as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = withUnsafeMutablePointer(to: &uid) { uidPointer -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer,
                                       &size, &deviceID)
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    func start() throws {
        guard !isRunning else { return }
        guard let device = AudioCapture.findDevice() else {
            throw AudioError(message: "Mac2Phone audio device not installed")
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioError(message: "No HAL output audio unit")
        }

        var audioUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &audioUnit), "instantiate")
        guard let audioUnit else { throw AudioError(message: "Audio unit is nil") }

        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)),
                  "enable input")
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)),
                  "disable output")

        var deviceID = device
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "select device")

        // Ask the device what it is running at, then take it in interleaved float.
        var hardwareFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 1, &hardwareFormat, &size)
        sampleRate = hardwareFormat.mSampleRate > 0 ? hardwareFormat.mSampleRate : 48000

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float32>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float32>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &clientFormat,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "set client format")

        var callback = AURenderCallbackStruct(
            inputProc: { refcon, flags, timestamp, bus, frames, _ in
                let capture = Unmanaged<AudioCapture>.fromOpaque(refcon).takeUnretainedValue()
                return capture.render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "set callback")

        try check(AudioUnitInitialize(audioUnit), "initialise")
        try check(AudioOutputUnitStart(audioUnit), "start")

        unit = audioUnit
        isRunning = true
    }

    func stop() {
        guard let audioUnit = unit else { isRunning = false; return }
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        unit = nil
        isRunning = false
        pending.removeAll(keepingCapacity: true)
        sawSignal = false
        renderBuffer?.deallocate()
        renderBuffer = nil
        renderCapacity = 0
    }

    // MARK: - Render

    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        timestamp: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32,
                        frames: UInt32) -> OSStatus {
        guard let audioUnit = unit, let onPCM else { return noErr }

        let needed = Int(frames) * channels
        if renderCapacity < needed {
            renderBuffer?.deallocate()
            renderBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: needed)
            renderCapacity = needed
        }
        guard let renderBuffer else { return noErr }

        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                  mDataByteSize: UInt32(needed * MemoryLayout<Float32>.size),
                                  mData: UnsafeMutableRawPointer(renderBuffer)))

        let status = AudioUnitRender(audioUnit, flags, timestamp, bus, frames, &list)
        guard status == noErr else { return status }

        if pending.isEmpty {
            let host = CMClockMakeHostTimeFromSystemUnits(timestamp.pointee.mHostTime)
            pendingStartPTS = Int64(CMTimeGetSeconds(host) * 1_000_000)
        }

        for index in 0..<needed {
            let sample = renderBuffer[index]
            if !sawSignal && abs(sample) > 0.0005 { sawSignal = true }
            let clamped = max(-1.0, min(1.0, sample))
            pending.append(Int16(clamped * 32767.0))
        }

        let samplesPerChunk = framesPerChunk * channels
        while pending.count >= samplesPerChunk {
            let chunk = Array(pending.prefix(samplesPerChunk))
            pending.removeFirst(samplesPerChunk)
            let data = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
            onPCM(data, pendingStartPTS)
            pendingStartPTS += Int64(Double(framesPerChunk) / sampleRate * 1_000_000)
        }
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        throw AudioError(message: "\(what) failed (\(status))")
    }
}
