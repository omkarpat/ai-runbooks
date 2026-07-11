import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available to capture."
        }
    }
}

/// Owns the SCStream + AVAssetWriter for one recording. All sample-buffer
/// callbacks land on a single serial queue so appends to the writer inputs are
/// naturally serialized. Produces a `.mov` with one H.264 video track and two
/// AAC audio tracks (system audio + mic on separate tracks — separate tracks
/// matter downstream so SST can transcribe narration cleanly).
actor CaptureEngine {
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private let outputQueue = DispatchQueue(label: "com.getsphere.airunbooks.capture")

    func start(url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        // Exclude our own app (the floating command bar + menu content) so the
        // Runbooks UI never appears in the recording.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let ownApp = content.applications.first { $0.processID == selfPID }
        let filter: SCContentFilter
        if let ownApp {
            filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.width = display.width * 2          // capture at Retina backing scale
        config.height = display.height * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = true               // system audio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true           // macOS 15+ mic capture

        let writer = try RecordingWriter(url: url, width: config.width, height: config.height)
        let stream = SCStream(filter: filter, configuration: config, delegate: writer)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: outputQueue)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: outputQueue)
        try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: outputQueue)

        try await stream.startCapture()
        self.stream = stream
        self.writer = writer
    }

    /// Stops capture and finalizes the file. Returns true if a valid file landed.
    func stop() async -> Bool {
        try? await stream?.stopCapture()
        let ok = await writer?.finish() ?? false
        stream = nil
        writer = nil
        return ok
    }
}

/// SCStream delegate + output sink that drives the AVAssetWriter. Confined to
/// the capture serial queue for all buffer handling.
final class RecordingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput
    private var sessionStarted = false

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000,
        ]
        systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        systemAudioInput.expectsMediaDataInRealTime = true
        micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        micInput.expectsMediaDataInRealTime = true

        super.init()

        if writer.canAdd(videoInput) { writer.add(videoInput) }
        if writer.canAdd(systemAudioInput) { writer.add(systemAudioInput) }
        if writer.canAdd(micInput) { writer.add(micInput) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            guard isCompleteFrame(sampleBuffer) else { return }
            if !sessionStarted {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
            }
            if writer.status == .writing, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }

        case .audio:
            guard sessionStarted, writer.status == .writing, systemAudioInput.isReadyForMoreMediaData else { return }
            systemAudioInput.append(sampleBuffer)

        case .microphone:
            guard sessionStarted, writer.status == .writing, micInput.isReadyForMoreMediaData else { return }
            micInput.append(sampleBuffer)

        @unknown default:
            break
        }
    }

    func finish() async -> Bool {
        guard sessionStarted else { return false }
        videoInput.markAsFinished()
        systemAudioInput.markAsFinished()
        micInput.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = array.first,
              let statusRaw = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw)
        else { return false }
        return status == .complete
    }
}
