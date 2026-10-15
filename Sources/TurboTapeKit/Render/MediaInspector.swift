import AVFoundation

/// What an exported file actually contains (for the CLI and tests).
public struct MediaReport: Sendable {
    public var duration: Double
    public var videoCodec: String
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var videoBitrate: Double
    public var audioCodec: String
    public var audioSampleRate: Double
    public var audioChannels: Int
    public var loudness: Double

    public var summary: String {
        String(format: "%@ %dx%d %.2f fps %.1f Mbps · %@ %.0f Hz %dch · %.2f s · %.1f LUFS",
               videoCodec, width, height, frameRate, videoBitrate / 1e6, audioCodec, audioSampleRate, audioChannels, duration, loudness)
    }
}

public enum MediaInspector {
    public static func inspect(_ url: URL) async throws -> MediaReport {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw TurboTapeError.noVideoTrack(url) }
        let (size, fps, rate, vfmt) = try await v.load(.naturalSize, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
        var report = MediaReport(duration: duration, videoCodec: fourCC(vfmt.first.map(CMFormatDescriptionGetMediaSubType)),
                                 width: Int(size.width), height: Int(size.height), frameRate: Double(fps), videoBitrate: Double(rate),
                                 audioCodec: "-", audioSampleRate: 0, audioChannels: 0, loudness: -.infinity)
        if let a = try await asset.loadTracks(withMediaType: .audio).first, let fmt = try await a.load(.formatDescriptions).first {
            report.audioCodec = fourCC(CMFormatDescriptionGetMediaSubType(fmt))
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                report.audioSampleRate = asbd.mSampleRate
                report.audioChannels = Int(asbd.mChannelsPerFrame)
            }
            let pcm = try await AudioDecoder.decode(url: url, sampleRate: 48_000, channels: 2)
            report.loudness = Loudness.integrated(pcm.channels, sampleRate: pcm.sampleRate)
        }
        return report
    }

    static func fourCC(_ code: FourCharCode?) -> String {
        guard let code else { return "?" }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }
}
