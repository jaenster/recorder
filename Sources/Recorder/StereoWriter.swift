import Foundation
import AVFoundation
import CoreMedia

enum AudioSource {
    case mic
    case app
}

/// Accepts mono Float32 samples from two sources (mic, app) and writes them
/// interleaved as a stereo AAC .m4a. Mic → L, app → R.
///
/// Both sources run at the SCStream sample rate (48 kHz) and share a clock,
/// so a FIFO that emits `min(mic, app)` frames per flush is sufficient — no
/// PTS alignment needed. Drop-outs are handled at finish() time by zero-fill.
final class StereoWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "stereo-writer", qos: .userInitiated)

    private let sampleRate: Double = 48_000
    private var micQueue: [Float] = []
    private var appQueue: [Float] = []
    private var totalFrames: Int64 = 0
    private var didStartSession = false

    // Rolling peaks per channel (read by AppDelegate for the level meter).
    private let peakLock = NSLock()
    private var _micPeak: Float = 0
    private var _appPeak: Float = 0

    /// Returns the peak amplitude per channel observed since the last call,
    /// then resets the running peaks. Used to drive the menu-bar VU meter.
    func consumePeaks() -> (mic: Float, app: Float) {
        peakLock.lock()
        defer { peakLock.unlock() }
        let m = _micPeak
        let a = _appPeak
        _micPeak = 0
        _appPeak = 0
        return (m, a)
    }

    let outputURL: URL

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        try? FileManager.default.removeItem(at: outputURL)

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: layoutData(tag: kAudioChannelLayoutTag_Stereo),
            AVEncoderBitRateKey: 64_000,
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        guard writer.startWriting() else {
            throw NSError(domain: "StereoWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: writer.error?.localizedDescription ?? "startWriting failed"])
        }
    }

    func append(buffer: CMSampleBuffer, source: AudioSource) {
        queue.async { [weak self] in
            self?.processBuffer(buffer, source: source)
        }
    }

    func finish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.drainAndFinalize { cont.resume() }
            }
        }
    }

    // MARK: - Private

    private func processBuffer(_ buffer: CMSampleBuffer, source: AudioSource) {
        guard let mono = extractMono(from: buffer) else { return }

        if !didStartSession {
            writer.startSession(atSourceTime: .zero)
            didStartSession = true
        }

        var peak: Float = 0
        for v in mono {
            let a = abs(v)
            if a > peak { peak = a }
        }
        peakLock.lock()
        switch source {
        case .mic:
            if peak > _micPeak { _micPeak = peak }
        case .app:
            if peak > _appPeak { _appPeak = peak }
        }
        peakLock.unlock()

        switch source {
        case .mic: micQueue.append(contentsOf: mono)
        case .app: appQueue.append(contentsOf: mono)
        }
        flushReady()
    }

    private func flushReady() {
        let n = min(micQueue.count, appQueue.count)
        guard n > 0, input.isReadyForMoreMediaData else { return }

        var interleaved = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            interleaved[i * 2] = micQueue[i]
            interleaved[i * 2 + 1] = appQueue[i]
        }
        micQueue.removeFirst(n)
        appQueue.removeFirst(n)

        let pts = CMTimeMake(value: totalFrames, timescale: Int32(sampleRate))
        if let sb = makeSampleBuffer(interleaved: interleaved, frames: n, pts: pts) {
            input.append(sb)
            totalFrames += Int64(n)
        }
    }

    private func drainAndFinalize(_ done: @escaping @Sendable () -> Void) {
        // Zero-fill the shorter side so we don't lose tail audio from the longer side.
        let pad = abs(micQueue.count - appQueue.count)
        if pad > 0 {
            let zeros = [Float](repeating: 0, count: pad)
            if micQueue.count < appQueue.count {
                micQueue.append(contentsOf: zeros)
            } else {
                appQueue.append(contentsOf: zeros)
            }
        }
        flushReady()

        input.markAsFinished()
        writer.finishWriting {
            done()
        }
    }

    // MARK: - CMSampleBuffer extraction

    private func extractMono(from buffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(buffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }
        let asbd = asbdPtr.pointee

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard isFloat, frames > 0, channels > 0 else { return nil }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return nil }

        if isInterleaved {
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let st = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                                  lengthAtOffsetOut: nil,
                                                  totalLengthOut: &length,
                                                  dataPointerOut: &dataPointer)
            guard st == kCMBlockBufferNoErr, let raw = dataPointer else { return nil }
            let count = length / MemoryLayout<Float>.size
            let buf = raw.withMemoryRebound(to: Float.self, capacity: count) {
                UnsafeBufferPointer(start: $0, count: count)
            }
            if channels == 1 { return Array(buf.prefix(frames)) }
            var mono = [Float](repeating: 0, count: frames)
            let inv = 1.0 / Float(channels)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += buf[f * channels + c] }
                mono[f] = sum * inv
            }
            return mono
        } else {
            // Non-interleaved: one AudioBuffer per channel inside the block buffer.
            // Use CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer for safe access.
            var listSize: Int = 0
            var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer,
                bufferListSizeNeededOut: &listSize,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: nil)
            guard status == noErr, listSize > 0 else { return nil }

            let listPtr = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
            defer { listPtr.deallocate() }
            var heldBlockBuffer: CMBlockBuffer?
            status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: listPtr.assumingMemoryBound(to: AudioBufferList.self),
                bufferListSize: listSize,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &heldBlockBuffer)
            guard status == noErr else { return nil }

            let abl = UnsafeMutableAudioBufferListPointer(listPtr.assumingMemoryBound(to: AudioBufferList.self))
            guard abl.count >= 1 else { return nil }

            var mono = [Float](repeating: 0, count: frames)
            let inv = 1.0 / Float(abl.count)
            for c in 0..<abl.count {
                let ab = abl[c]
                guard let data = ab.mData else { continue }
                let ptr = data.bindMemory(to: Float.self, capacity: frames)
                if abl.count == 1 {
                    for f in 0..<frames { mono[f] = ptr[f] }
                } else {
                    for f in 0..<frames { mono[f] += ptr[f] * inv }
                }
            }
            return mono
        }
    }

    // MARK: - Build CMSampleBuffer from Float interleaved samples

    private func makeSampleBuffer(interleaved: [Float], frames: Int, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * 2,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0)
        var formatDesc: CMAudioFormatDescription?
        var st = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc)
        guard st == noErr, let fmt = formatDesc else { return nil }

        let dataSize = interleaved.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard st == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }

        st = interleaved.withUnsafeBufferPointer { buf -> OSStatus in
            CMBlockBufferReplaceDataBytes(
                with: buf.baseAddress!,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: dataSize)
        }
        guard st == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        st = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: frames,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        guard st == noErr else { return nil }
        return sampleBuffer
    }
}

private func layoutData(tag: AudioChannelLayoutTag) -> Data {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = tag
    return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
}
