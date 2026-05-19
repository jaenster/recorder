import Foundation
@preconcurrency import AVFoundation
import CoreMedia

enum ChannelSplitter {
    /// Decode a stereo audio file into two mono Float32 PCM buffers (left = mic, right = app).
    static func split(url: URL) async throws -> (left: AVAudioPCMBuffer, right: AVAudioPCMBuffer, sampleRate: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw NSError(domain: "ChannelSplitter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio track in \(url.lastPathComponent)"])
        }

        let sampleRate: Double = 48_000
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "ChannelSplitter", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }

        var left: [Float] = []
        var right: [Float] = []

        while reader.status == .reading {
            guard let buffer = output.copyNextSampleBuffer() else { break }
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard let bb = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let st = CMBlockBufferGetDataPointer(bb, atOffset: 0,
                                                  lengthAtOffsetOut: nil,
                                                  totalLengthOut: &length,
                                                  dataPointerOut: &dataPointer)
            guard st == kCMBlockBufferNoErr, let raw = dataPointer, length >= frames * 2 * 4 else { continue }
            let count = length / MemoryLayout<Float>.size
            let buf = raw.withMemoryRebound(to: Float.self, capacity: count) {
                UnsafeBufferPointer(start: $0, count: count)
            }
            left.reserveCapacity(left.count + frames)
            right.reserveCapacity(right.count + frames)
            for f in 0..<frames {
                left.append(buf[f * 2])
                right.append(buf[f * 2 + 1])
            }
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "ChannelSplitter", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "Reader failed"])
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw NSError(domain: "ChannelSplitter", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create mono format"])
        }
        guard let leftBuf = pcmBuffer(samples: left, format: format),
              let rightBuf = pcmBuffer(samples: right, format: format) else {
            throw NSError(domain: "ChannelSplitter", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate PCM buffers"])
        }
        return (leftBuf, rightBuf, sampleRate)
    }

    private static func pcmBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(samples.count)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        guard let channelData = buf.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            channelData.update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }
}
