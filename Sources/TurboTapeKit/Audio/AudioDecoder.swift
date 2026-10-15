import AVFoundation

/// Planar float PCM.
public struct DecodedAudio: Sendable {
    public let sampleRate: Double
    /// One array per channel, all the same length.
    public let channels: [[Float]]

    public var frameCount: Int { channels.first?.count ?? 0 }
    public var duration: Double { Double(frameCount) / sampleRate }

    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Channels averaged to one.
    public func mono() -> [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        var out = [Float](repeating: 0, count: frameCount)
        for c in channels { out.withUnsafeMutableBufferPointer { o in for i in 0..<o.count { o[i] += c[i] } } }
        let k = 1 / Float(channels.count)
        for i in out.indices { out[i] *= k }
        return out
    }
}

public enum AudioDecoder {
    /// Decode the first audio track of any AVFoundation-readable file, resampled to `sampleRate`
    /// and mixed to `channels` channels.
    public static func decode(url: URL, sampleRate: Double, channels: Int, timeRange: CMTimeRange? = nil) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TurboTapeError.noAudioTrack(url)
        }
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw TurboTapeError.readFailed(url, reader.error?.localizedDescription ?? "unknown error")
        }
        var planar = [[Float]](repeating: [], count: channels)
        var scratch = [Float]()
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            scratch.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            let frames = count / channels
            if channels == 1 {
                // the music analysis path: nothing to de-interleave
                planar[0].append(contentsOf: scratch[0..<frames])
                continue
            }
            for c in 0..<channels {
                for f in 0..<frames { planar[c].append(scratch[f * channels + c]) }
            }
        }
        if reader.status == .failed {
            throw TurboTapeError.readFailed(url, reader.error?.localizedDescription ?? "unknown error")
        }
        return DecodedAudio(sampleRate: sampleRate, channels: planar)
    }
}
