import AVFoundation

/// A source clip's loaded video track, kept around so rebuilding the composition after an edit
/// takes milliseconds.
/// AVAssetTrack is immutable once loaded.
public struct SourceTrack: @unchecked Sendable {
    public let asset: AVURLAsset
    public let track: AVAssetTrack
    public let transform: CGAffineTransform
    public let isHDR: Bool

    public static func load(_ url: URL) async throws -> SourceTrack {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw TurboTapeError.noVideoTrack(url) }
        let (transform, traits) = try await track.load(.preferredTransform, .mediaCharacteristics)
        return SourceTrack(asset: asset, track: track, transform: transform, isHDR: traits.contains(.containsHDRVideo))
    }
}

/// The music's loaded audio track.
public struct MusicSource: @unchecked Sendable {
    public let asset: AVURLAsset
    public let track: AVAssetTrack

    public static func load(_ url: URL) async throws -> MusicSource {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TurboTapeError.noAudioTrack(url) }
        return MusicSource(asset: asset, track: track)
    }
}

/// Everything AVFoundation needs to play or export a timeline.
public struct RenderPlan {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix
    public let duration: CMTime

    /// The video composition with other colour curves (`curves[clip]`, none when absent). Cheap:
    /// the composition itself is untouched, so a player item can switch to it without reloading
    /// (no black frame while the new item loads).
    public func videoComposition(curves: [URL: Data]) -> AVMutableVideoComposition {
        // swiftlint:disable:next force_cast
        let vc = videoComposition.mutableCopy() as! AVMutableVideoComposition
        vc.instructions = videoComposition.instructions.map { ins in
            (ins as? ReframeInstruction).map { $0.with(curves: curves[$0.clip]) } ?? ins
        }
        return vc
    }

    /// A player item for the preview (same composition as the export).
    @MainActor public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

public enum CompositionBuilder {
    public static let renderSize = CGSize(width: 1080, height: 1920)

    /// Build the composition for `timeline`. `sources` must hold every clip the timeline uses;
    /// `curves` holds each clip's colour curves (`ColorGrade.curvesData`), absent for none.
    public static func build(_ timeline: Timeline, sources: [URL: SourceTrack], music: MusicSource,
                             clips: [URL: ClipAnalysis], curves: [URL: Data] = [:], renderSize: CGSize = renderSize,
                             fadeOut: Double = 1.5) throws -> RenderPlan {
        let fps = Int32(timeline.fps)
        let comp = AVMutableComposition()
        // A/B tracks: neighbouring segments never share a track, so each keeps its own format
        let tracks = (0..<2).compactMap { _ in comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) }
        guard tracks.count == 2, let audio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TurboTapeError.exportFailed("could not create composition tracks")
        }
        var instructions = [ReframeInstruction]()
        // each clip's median-filtered focus, once per build rather than once per segment
        var filteredFocus = [URL: [Float]]()
        for (i, seg) in timeline.segments.enumerated() {
            guard let src = sources[seg.clip] else { throw TurboTapeError.readFailed(seg.clip, "not loaded") }
            let track = tracks[i % 2]
            let at = CMTime(value: CMTimeValue(seg.startFrame), timescale: fps)
            let dur = CMTime(value: CMTimeValue(seg.frameCount), timescale: fps)
            let from = CMTime(seconds: seg.sourceStart, preferredTimescale: 600 * fps)
            try track.insertTimeRange(CMTimeRange(start: from, duration: dur), of: src.track, at: at)
            let analysis = clips[seg.clip]
            // one calm camera move per shot (see ReframePath)
            var times = [Double](), values = [Float]()
            if let a = analysis, a.info.needsReframe {
                let filtered = filteredFocus[seg.clip] ?? ReframePath.medianFiltered(times: a.sampleTimes, raw: a.focusX)
                filteredFocus[seg.clip] = filtered
                (times, values) = ReframePath.keyframes(times: a.sampleTimes, filtered: filtered, start: seg.sourceStart,
                                                        duration: Double(seg.frameCount) / Double(fps))
            }
            instructions.append(ReframeInstruction(
                timeRange: CMTimeRange(start: at, duration: dur), trackID: track.trackID, clip: seg.clip, sourceStart: seg.sourceStart,
                orientation: ReframeCompositor.orientation(src.transform), isHDR: src.isHDR,
                focusTimes: times, focusValues: values, curves: curves[seg.clip]))
        }
        let total = CMTime(value: CMTimeValue(timeline.frameCount), timescale: fps)
        try audio.insertTimeRange(CMTimeRange(start: CMTime(seconds: timeline.musicStart, preferredTimescale: 48_000), duration: total),
                                  of: music.track, at: .zero)

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = ReframeCompositor.self
        vc.frameDuration = CMTime(value: 1, timescale: fps)
        vc.renderSize = renderSize
        vc.instructions = instructions
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let params = AVMutableAudioMixInputParameters(track: audio)
        let fade = min(fadeOut, timeline.duration / 4)
        if fade > 0 {
            params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: total - CMTime(seconds: fade, preferredTimescale: 600), end: total))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return RenderPlan(composition: comp, videoComposition: vc, audioMix: mix, duration: total)
    }
}
