import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

/// Captures one display with ScreenCaptureKit at full native pixel resolution.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {

    private let outputQueue = DispatchQueue(label: "mac2phone.capture", qos: .userInteractive)
    private let lifecycleLock = NSLock()
    private var startGeneration: UUID?
    private var running = false
    private var stream: SCStream?
    private var configuration = SCStreamConfiguration()

    /// Called on the capture queue for every new frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStopped: ((Error) -> Void)?

    // Settings — call `applySettings()` to push changes to a live stream.
    var maxWidth: Int = 2560       // 0 = unlimited (true native pixels)
    var fps: Int = 60
    var showsCursor: Bool = true
    var displayIndex: Int = 0

    var isRunning: Bool { lifecycleLock.withLock { running } }
    /// Global CoreGraphics bounds (points) of the mirrored display — used to map touches.
    private(set) var displayBounds: CGRect = .zero
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var pixelSize: (width: Int, height: Int) = (0, 0)

    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func displays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false).displays
    }

    static func describe(_ d: SCDisplay) -> String {
        let mode = CGDisplayCopyDisplayMode(d.displayID)
        let px = mode.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?"
        return "id \(d.displayID)  \(d.width)x\(d.height) pt  \(px) px"
    }

    func start() async throws {
        let generation = UUID()
        let canStart = lifecycleLock.withLock { () -> Bool in
            guard !running, startGeneration == nil else { return false }
            startGeneration = generation
            return true
        }
        guard canStart else { return }
        defer { lifecycleLock.withLock { if startGeneration == generation { startGeneration = nil } } }

        let all = try await ScreenCapturer.displays()
        guard !all.isEmpty else { throw CaptureError(message: "No capturable display found.") }
        let display = all[min(max(displayIndex, 0), all.count - 1)]

        displayBounds = CGDisplayBounds(display.displayID)
        displayID = display.displayID
        configuration = makeConfiguration(for: display)
        pixelSize = (configuration.width, configuration.height)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: configuration, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        // Accept frames delivered during startCapture(), including the only
        // complete frame when the desktop is otherwise static.
        let current = lifecycleLock.withLock { () -> Bool in
            guard startGeneration == generation else { return false }
            stream = s
            return true
        }
        guard current else { return }
        do {
            try await s.startCapture()
        } catch {
            lifecycleLock.withLock { if stream === s { stream = nil; running = false } }
            throw error
        }

        let accepted = lifecycleLock.withLock { () -> Bool in
            guard startGeneration == generation, stream === s else { return false }
            running = true
            return true
        }
        if !accepted { try? await s.stopCapture() }
    }

    func stop() async {
        let previous = lifecycleLock.withLock { () -> SCStream? in
            startGeneration = nil
            running = false
            defer { stream = nil }
            return stream
        }
        if let previous { try? await previous.stopCapture() }
    }

    /// Returns true when the frame geometry changed and encoders must be rebuilt.
    @discardableResult
    func applySettings() async -> Bool {
        guard let s = lifecycleLock.withLock({ stream }),
              let all = try? await ScreenCapturer.displays(), !all.isEmpty else { return false }
        let display = all[min(max(displayIndex, 0), all.count - 1)]
        let old = pixelSize
        let oldDisplay = displayID
        let updated = makeConfiguration(for: display)
        do {
            if display.displayID != oldDisplay {
                try await s.updateContentFilter(SCContentFilter(display: display, excludingWindows: []))
            }
            try await s.updateConfiguration(updated)
            guard lifecycleLock.withLock({ stream === s }) else { return false }
            configuration = updated
            displayBounds = CGDisplayBounds(display.displayID)
            displayID = display.displayID
            pixelSize = (updated.width, updated.height)
            return old != pixelSize || oldDisplay != displayID
        } catch {
            return false
        }
    }

    private func makeConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        // display.width/height are points; the backing store is what we actually want.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let nativeW = mode?.pixelWidth ?? display.width
        let nativeH = mode?.pixelHeight ?? display.height

        // Never send more pixels than the display actually has: upscaling costs
        // bandwidth and adds nothing a viewer can see.
        var w = maxWidth > 0 ? min(maxWidth, nativeW) : nativeW
        var h = Int((Double(w) * Double(nativeH) / Double(nativeW)).rounded())
        // Hardware encoders want even dimensions.
        w -= w % 2
        h -= h % 2

        let c = SCStreamConfiguration()
        c.width = max(2, w)
        c.height = max(2, h)
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.queueDepth = 3   // keep the pipeline shallow: newer frames beat buffered ones
        c.showsCursor = showsCursor
        c.capturesAudio = false
        c.scalesToFit = true
        return c
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, lifecycleLock.withLock({ self.stream === stream }), let onFrame else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let wasCurrent = lifecycleLock.withLock { () -> Bool in
            guard self.stream === stream else { return false }
            running = false
            self.stream = nil
            return true
        }
        if wasCurrent { onStopped?(error) }
    }
}
