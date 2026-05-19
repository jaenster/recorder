import Foundation
@preconcurrency import AVFoundation

enum SpeakerLabel: String {
    case me = "ME"
    case them = "THEM"
}

struct Word: Sendable {
    let text: String
    let start: Double   // seconds
    let end: Double
    let speaker: SpeakerLabel
}

protocol TranscriberBackend: Sendable {
    func transcribe(pcm: AVAudioPCMBuffer, label: SpeakerLabel) async throws -> [Word]
}

/// Returns true if the buffer has any real audio worth sending to a
/// transcriber. ASR models hallucinate fillers ("okay", "thanks", "I") on
/// near-silent audio, so we gate on peak level before running them.
func channelHasSignal(_ buffer: AVAudioPCMBuffer, peakThresholdDB: Float = -20) -> Bool {
    guard let channel = buffer.floatChannelData?[0] else { return false }
    let n = Int(buffer.frameLength)
    if n == 0 { return false }
    var peak: Float = 0
    for i in 0..<n {
        let v = abs(channel[i])
        if v > peak { peak = v }
    }
    if peak <= 0 { return false }
    let peakDB = 20 * log10(peak)
    return peakDB >= peakThresholdDB
}

enum TranscriberError: Error, LocalizedError {
    case noAPIKey
    case modelUnavailable(String)
    case requestFailed(String)
    case fileWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No OpenAI API key set. Use 'Set OpenAI API key…' in the menu."
        case .modelUnavailable(let s):
            return "Speech model unavailable: \(s)"
        case .requestFailed(let s):
            return "Transcription request failed: \(s)"
        case .fileWriteFailed(let s):
            return "Could not write temp audio file: \(s)"
        }
    }
}

/// Write an in-memory PCM buffer to a temporary file (16-bit PCM WAV) and
/// return the URL. Used to hand off to SpeechAnalyzer and the Whisper upload.
func writeTempAudio(buffer: AVAudioPCMBuffer, label: SpeakerLabel) throws -> URL {
    let tmpDir = FileManager.default.temporaryDirectory
    let url = tmpDir.appendingPathComponent("voice-\(label.rawValue)-\(UUID().uuidString).wav")
    try? FileManager.default.removeItem(at: url)

    // 16-bit PCM mono WAV at the buffer's source sample rate.
    let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: buffer.format.sampleRate,
        channels: 1,
        interleaved: true
    )!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: buffer.format.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    do {
        let file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: .pcmFormatInt16,
                                   interleaved: true)
        // Convert Float32 → Int16 via AVAudioConverter
        guard let converter = AVAudioConverter(from: buffer.format, to: outFormat) else {
            throw TranscriberError.fileWriteFailed("Could not create converter")
        }
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat,
                                      frameCapacity: buffer.frameLength)!
        var error: NSError?
        var done = false
        _ = converter.convert(to: outBuf, error: &error) { _, status in
            if done { status.pointee = .endOfStream; return nil }
            done = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        try file.write(from: outBuf)
        return url
    } catch {
        throw TranscriberError.fileWriteFailed(error.localizedDescription)
    }
}
