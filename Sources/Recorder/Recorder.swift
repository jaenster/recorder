import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation

@MainActor
protocol RecorderDelegate: AnyObject {
    func recorder(_ recorder: Recorder, didFailWith error: Error)
    func recorder(_ recorder: Recorder, didFinishTo url: URL)
}

@MainActor
final class Recorder: NSObject {
    weak var delegate: RecorderDelegate?

    private(set) var isRecording = false
    private(set) var currentURL: URL?

    private var stream: SCStream?
    private var streamOutputHandler: StreamOutputHandler?
    private var writer: StereoWriter?

    /// Start recording. `apps` are the SCRunningApplication objects to capture
    /// audio from (typically the chosen app + any of its helper processes).
    /// Optional `titleSuffix` appears in the output filename — used by the
    /// calendar auto-record path to name the file after the meeting title.
    /// Optional `metadata` is written as a sidecar JSON next to the .m4a so
    /// downstream transcription can label speakers by attendee name.
    func start(apps: [SCRunningApplication],
               titleSuffix: String? = nil,
               metadata: RecordingMetadata? = nil) async throws {
        guard !isRecording else { return }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "Recorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        if #available(macOS 15.0, *) {
            config.captureMicrophone = true
            let preferred = Settings.shared.preferredMicID
            let micID = preferred ?? AVCaptureDevice.default(for: .audio)?.uniqueID
            if let micID {
                config.microphoneCaptureDeviceID = micID
            }
        }

        let outURL = makeOutputURL(suffix: titleSuffix)
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let writer = try StereoWriter(outputURL: outURL)
        self.writer = writer
        self.currentURL = outURL
        metadata?.write(forRecording: outURL)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let handler = StreamOutputHandler(writer: writer) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                await self.fail(error)
            }
        }
        try stream.addStreamOutput(handler, type: .audio,
                                   sampleHandlerQueue: handler.audioQueue)
        if #available(macOS 15.0, *) {
            try stream.addStreamOutput(handler, type: .microphone,
                                       sampleHandlerQueue: handler.micQueue)
        }
        self.stream = stream
        self.streamOutputHandler = handler

        try await stream.startCapture()
        isRecording = true
    }

    /// Peak amplitudes per channel since the last call (0…1 linear). Used
    /// to drive the menu-bar VU meter. Returns zeros when not recording.
    func consumePeaks() -> (mic: Float, app: Float) {
        writer?.consumePeaks() ?? (0, 0)
    }

    func stop() async {
        guard isRecording, let stream, let writer else { return }
        isRecording = false
        do { try await stream.stopCapture() } catch { }
        await writer.finish()
        let url = writer.outputURL
        self.stream = nil
        self.writer = nil
        self.streamOutputHandler = nil
        delegate?.recorder(self, didFinishTo: url)
    }

    private func fail(_ error: Error) async {
        guard isRecording else { return }
        await stop()
        delegate?.recorder(self, didFailWith: error)
    }

    private func makeOutputURL(suffix: String?) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        var name = "voice-\(fmt.string(from: Date()))"
        if let suffix, !suffix.isEmpty {
            name += "-" + slug(suffix)
        }
        return recordingsFolderURL().appendingPathComponent("\(name).m4a")
    }

    private func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let parts = s.lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
        return String(parts.joined(separator: "-").prefix(40))
    }
}

/// SCStreamOutput receiver that routes audio buffers to StereoWriter.
/// Lives off the main actor — its callbacks come on the configured sample queues.
final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: StereoWriter
    let onError: (Error) -> Void
    let audioQueue = DispatchQueue(label: "scstream.audio", qos: .userInitiated)
    let micQueue = DispatchQueue(label: "scstream.mic", qos: .userInitiated)

    init(writer: StereoWriter, onError: @escaping (Error) -> Void) {
        self.writer = writer
        self.onError = onError
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .audio:
            writer.append(buffer: sampleBuffer, source: .app)
        case .microphone:
            writer.append(buffer: sampleBuffer, source: .mic)
        case .screen:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}
