import Foundation
@preconcurrency import AVFoundation
import Speech

@available(macOS 26.0, *)
final class SpeechAnalyzerTranscriber: TranscriberBackend {
    func transcribe(pcm: AVAudioPCMBuffer, label: SpeakerLabel) async throws -> [Word] {
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // Make sure the on-device model is installed for this locale.
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported {
            throw TranscriberError.modelUnavailable("Locale \(locale.identifier) not supported for on-device transcription.")
        }
        if status != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        // Write the PCM buffer to a temp file so SpeechAnalyzer can read it.
        let url = try writeTempAudio(buffer: pcm, label: label)
        defer { try? FileManager.default.removeItem(at: url) }

        let audioFile = try AVAudioFile(forReading: url)

        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            finishAfterFile: true
        )
        _ = analyzer  // keep alive for the duration of result iteration

        var words: [Word] = []
        for try await result in transcriber.results {
            let text = result.text
            for run in text.runs {
                guard let range = run.audioTimeRange else { continue }
                let slice = text[run.range]
                let raw = String(slice.characters)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let start = CMTimeGetSeconds(range.start)
                let end = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration))
                guard start.isFinite, end.isFinite else { continue }
                words.append(Word(text: trimmed, start: start, end: end, speaker: label))
            }
        }
        return words.sorted { $0.start < $1.start }
    }
}
