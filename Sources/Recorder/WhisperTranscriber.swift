import Foundation
@preconcurrency import AVFoundation

final class WhisperTranscriber: TranscriberBackend {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(pcm: AVAudioPCMBuffer, label: SpeakerLabel) async throws -> [Word] {
        let url = try writeTempAudio(buffer: pcm, label: label)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        let response = try await postToWhisper(audioData: data, filename: url.lastPathComponent)
        return response.words.map { w in
            Word(text: w.word, start: w.start, end: w.end, speaker: label)
        }
    }

    private struct WhisperResponse: Decodable {
        struct WordTiming: Decodable {
            let word: String
            let start: Double
            let end: Double
        }
        let text: String
        let words: [WordTiming]
    }

    private func postToWhisper(audioData: Data, filename: String) async throws -> WhisperResponse {
        let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        func add(field name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        func addFile(name: String, filename: String, mime: String, data: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }

        add(field: "model", value: "whisper-1")
        add(field: "response_format", value: "verbose_json")
        add(field: "timestamp_granularities[]", value: "word")
        addFile(name: "file", filename: filename, mime: "audio/wav", data: audioData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriberError.requestFailed("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: respData.prefix(400), encoding: .utf8) ?? "(binary)"
            throw TranscriberError.requestFailed("HTTP \(http.statusCode): \(snippet)")
        }
        do {
            return try JSONDecoder().decode(WhisperResponse.self, from: respData)
        } catch {
            throw TranscriberError.requestFailed("Decode failed: \(error.localizedDescription)")
        }
    }
}
