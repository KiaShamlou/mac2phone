import Foundation
import AVFoundation

/// Plays the PCM chunks arriving from the Mac, with a small jitter buffer so a
/// late packet on Wi-Fi does not turn into a click.
final class AudioPlayer {

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var format: AVAudioFormat?

    private var ring: UnsafeMutablePointer<Float>
    private let ringCapacity: Int
    private var writeIndex = 0
    private var readIndex = 0
    private let lock = NSLock()
    private var primed = false

    private(set) var isRunning = false
    private(set) var sampleRate: Double = 48000
    private var channels = 2

    /// Roughly 60 ms of slack: enough to ride out normal jitter, short enough
    /// that sound still lines up with what is on screen.
    private var targetFillFrames: Int { Int(sampleRate * 0.06) }

    init() {
        ringCapacity = 48000 * 2 * 2          // two seconds of stereo headroom
        ring = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity)
        ring.initialize(repeating: 0, count: ringCapacity)
    }

    deinit {
        ring.deallocate()
    }

    func configure(sampleRate: Double, channels: Int) {
        guard sampleRate > 0 else { return }
        let changed = sampleRate != self.sampleRate || channels != self.channels
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        if changed && isRunning {
            stop()
            start()
        }
    }

    func start() {
        guard !isRunning else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            return
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels)) else { return }
        self.format = format

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            self.fill(buffers: buffers, frames: Int(frameCount))
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()

        do {
            try engine.start()
            isRunning = true
        } catch {
            engine.detach(node)
            sourceNode = nil
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let node = sourceNode { engine.detach(node) }
        sourceNode = nil
        isRunning = false
        lock.lock()
        readIndex = 0
        writeIndex = 0
        primed = false
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// `pcm` is interleaved little-endian Int16.
    func enqueue(_ pcm: Data) {
        guard isRunning else { return }
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        pcm.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0..<sampleCount {
                let next = (writeIndex + 1) % ringCapacity
                if next == readIndex { break }          // full: drop rather than wrap over unread audio
                ring[writeIndex] = Float(Int16(littleEndian: base[index])) / 32768.0
                writeIndex = next
            }
        }
    }

    private func available() -> Int {
        let used = writeIndex - readIndex
        return used >= 0 ? used : used + ringCapacity
    }

    private func fill(buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        lock.lock()

        if !primed {
            if available() >= targetFillFrames * channels {
                primed = true
            } else {
                lock.unlock()
                for buffer in buffers {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return
            }
        }

        // AVAudioSourceNode with a standard format hands us one buffer per channel.
        for frame in 0..<frames {
            for channel in 0..<buffers.count {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                if readIndex == writeIndex {
                    data[frame] = 0
                    primed = false                        // ran dry: refill before resuming
                } else {
                    data[frame] = ring[readIndex]
                    readIndex = (readIndex + 1) % ringCapacity
                }
            }
        }
        lock.unlock()
    }
}
