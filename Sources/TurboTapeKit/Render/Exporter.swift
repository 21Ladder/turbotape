import AVFoundation

/// Renders a `RenderPlan` to a file: the composition is read through the same compositor as the
/// preview and written with the hardware H.264 encoder; the music is gained toward the preset's
/// loudness on the way.
public enum Exporter {
    public struct Report: Sendable {
        public var url: URL
        public var seconds: Double
        public var musicGainDB: Double
    }

    /// `gain` is linear (see `musicGain`). Writes to a temporary file, then moves it to `url`.
    public static func export(_ plan: RenderPlan, fps: Int, gain: Float, preset: ExportPreset = .shortsReels, to url: URL,
                              progress: (@Sendable (Double) -> Void)? = nil) async throws -> Report {
        let t0 = Date()
        let fm = FileManager.default
        // on the destination's volume: `replaceItemAt` cannot replace across volumes (an existing
        // file on an external drive would fail to save)
        let tmpDir = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                  appropriateFor: url.deletingLastPathComponent(), create: true)) ?? fm.temporaryDirectory
        let tmp = tmpDir.appendingPathComponent("turbotape-\(UUID().uuidString).mp4")
        defer {
            try? fm.removeItem(at: tmp)
            if tmpDir != fm.temporaryDirectory { try? fm.removeItem(at: tmpDir) }
        }

        let reader = try AVAssetReader(asset: plan.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: plan.duration)
        let videoTracks = plan.composition.tracks(withMediaType: .video)
        let audioTracks = plan.composition.tracks(withMediaType: .audio)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        videoOut.videoComposition = plan.videoComposition
        videoOut.alwaysCopiesSampleData = false
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: preset.pcmSettings)
        audioOut.audioMix = plan.audioMix
        guard reader.canAdd(videoOut), reader.canAdd(audioOut) else { throw TurboTapeError.exportFailed("cannot read composition") }
        reader.add(videoOut)
        reader.add(audioOut)

        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: preset.videoSettings(fps: fps))
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: preset.audioSettings)
        videoIn.expectsMediaDataInRealTime = false
        audioIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn), writer.canAdd(audioIn) else { throw TurboTapeError.exportFailed("cannot write H.264/AAC") }
        writer.add(videoIn)
        writer.add(audioIn)

        guard reader.startReading() else { throw TurboTapeError.exportFailed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw TurboTapeError.exportFailed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        let total = plan.duration.seconds
        let pump = Pump(reader: reader, writer: writer, lanes: [
            .init(videoOut, videoIn, "video") { sample in
                progress?(min(1, sample.presentationTimeStamp.seconds / total))
                return sample
            },
            .init(audioOut, audioIn, "audio") { sample in
                applyGain(gain, to: sample)
                return sample
            },
        ])
        do {
            try await withTaskCancellationHandler {
                try await pump.run()
            } onCancel: {
                pump.cancel()
            }
            try Task.checkCancellation()
        } catch {
            writer.cancelWriting()
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw TurboTapeError.exportFailed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)") }
        if reader.status == .failed { throw TurboTapeError.exportFailed(reader.error?.localizedDescription ?? "reader") }

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        progress?(1)
        return Report(url: url, seconds: Date().timeIntervalSince(t0), musicGainDB: 20 * log10(Double(gain)))
    }

    /// Linear gain that brings the music excerpt to the preset's loudness without pushing its
    /// peak over the ceiling.
    public static func musicGain(_ timeline: Timeline, preset: ExportPreset = .shortsReels) async throws -> Float {
        let range = CMTimeRange(start: CMTime(seconds: timeline.musicStart, preferredTimescale: 48_000),
                                duration: CMTime(seconds: timeline.duration, preferredTimescale: 48_000))
        let audio = try await AudioDecoder.decode(url: timeline.music, sampleRate: preset.audioSampleRate, channels: 2, timeRange: range)
        let lufs = Loudness.integrated(audio.channels, sampleRate: audio.sampleRate)
        return Loudness.normalizationGain(lufs: lufs, peak: Loudness.samplePeak(audio.channels),
                                          target: preset.targetLUFS, ceilingDB: preset.peakCeiling)
    }

    /// Scale interleaved float PCM in place (the reader hands us our own copy).
    static func applyGain(_ gain: Float, to sample: CMSampleBuffer) {
        guard gain != 1, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var data: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &data) == noErr,
              let data, CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) else { return }
        data.withMemoryRebound(to: Float.self, capacity: length / 4) { p in
            for i in 0..<length / 4 { p[i] = min(max(p[i] * gain, -1), 1) }
        }
    }
}

/// Moves samples from reader outputs to writer inputs, each lane on its own queue, and resumes
/// once every lane has finished (or the first one fails).
private final class Pump: @unchecked Sendable {
    final class Lane: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let queue: DispatchQueue
        let transform: @Sendable (CMSampleBuffer) -> CMSampleBuffer
        /// Only touched on `queue`.
        var finished = false

        init(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput, _ label: String,
             transform: @escaping @Sendable (CMSampleBuffer) -> CMSampleBuffer) {
            self.output = output
            self.input = input
            queue = DispatchQueue(label: "turbotape.export.\(label)")
            self.transform = transform
        }
    }

    let reader: AVAssetReader
    let writer: AVAssetWriter
    let lanes: [Lane]
    private let lock = NSLock()
    private var cancelled = false
    private var remaining = 0
    private var continuation: CheckedContinuation<Void, Error>?
    /// The first lane failure (or cancellation); the export reports it once every lane has stopped.
    private var failure: Error?

    init(reader: AVAssetReader, writer: AVAssetWriter, lanes: [Lane]) {
        self.reader = reader
        self.writer = writer
        self.lanes = lanes
    }

    func cancel() {
        lock.withLock { cancelled = true }
        reader.cancelReading()
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock {
                continuation = cont
                remaining = lanes.count
            }
            for lane in lanes {
                lane.input.requestMediaDataWhenReady(on: lane.queue) { [self] in drain(lane) }
            }
        }
    }

    private func drain(_ lane: Lane) {
        guard !lane.finished else { return }
        while lane.input.isReadyForMoreMediaData {
            if lock.withLock({ cancelled }) { return finish(lane, CancellationError()) }
            guard let sample = lane.output.copyNextSampleBuffer() else {
                return finish(lane, reader.status == .failed ? TurboTapeError.exportFailed(reader.error?.localizedDescription ?? "read failed") : nil)
            }
            if !lane.input.append(lane.transform(sample)) {
                return finish(lane, TurboTapeError.exportFailed(writer.error?.localizedDescription ?? "append failed"))
            }
        }
    }

    /// A lane is done. The export resumes only when every lane has stopped touching the writer:
    /// after a failure the other lanes are told to stop (and the reader is cancelled so they run
    /// dry), and their end is awaited — with a 2 s safety net in case a failed writer never asks
    /// a lane for more data again.
    private func finish(_ lane: Lane, _ error: Error?) {
        lane.finished = true
        lane.input.markAsFinished()
        let (cont, result, firstFailure): (CheckedContinuation<Void, Error>?, Error?, Bool) = lock.withLock {
            remaining -= 1
            var first = false
            if let error, failure == nil {
                failure = error
                cancelled = true
                first = true
            }
            guard remaining == 0, let c = continuation else { return (nil, nil, first) }
            continuation = nil
            return (c, failure, first)
        }
        if firstFailure {
            reader.cancelReading()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                let (c, f): (CheckedContinuation<Void, Error>?, Error?) = lock.withLock {
                    defer { continuation = nil }
                    return (continuation, failure)
                }
                c?.resume(throwing: f ?? CancellationError())
            }
        }
        if let cont {
            if let result { cont.resume(throwing: result) } else { cont.resume() }
        }
    }
}
