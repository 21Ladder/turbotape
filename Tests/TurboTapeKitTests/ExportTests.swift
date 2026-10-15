import AVFoundation
import Testing
@testable import TurboTapeKit

struct ExportTests {
    /// A click track written as a WAV file. Each call gets its own file: tests run in parallel, and
    /// a shared path would be deleted and rewritten (at another length) while another test reads it.
    static func musicFile(bpm: Double, seconds: Double) throws -> URL {
        let url = TestVideo.directory().appendingPathComponent("music-\(Int(bpm))-\(UUID().uuidString).wav")
        let (x, _) = Synth.clickTrack(bpm: bpm, seconds: seconds, sampleRate: 44_100)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count))!
        buf.frameLength = buf.frameCapacity
        for c in 0..<2 { for i in x.indices { buf.floatChannelData![c][i] = x[i] * 0.2 } }
        try file.write(from: buf)
        return url
    }

    @Test func endToEndExportMatchesPreset() async throws {
        let musicURL = try Self.musicFile(bpm: 120, seconds: 20)
        let (landscape, _) = try await TestVideo.make(name: "land", shots: [(0, 3), (2, 3)])
        let (portrait, _) = try await TestVideo.make(name: "port", shots: [(1, 4)], width: 180, height: 320)
        let cache = AnalysisCache(directory: TestVideo.directory().appendingPathComponent("cache"))
        var clips = [ClipAnalysis]()
        for u in [landscape, portrait] { clips.append(try await cache.analysis(for: try await MediaLibrary.loadInfo(u))) }
        let music = try await MusicAnalyzer.analyze(url: musicURL)
        let start = music.suggestedStart(length: 6)
        let (s, e) = music.excerpt(start: start, length: 6)
        let timeline = try EditPlanner.plan(music: music, musicURL: musicURL, start: s, end: e, clips: clips, seed: 1)

        var sources = [URL: SourceTrack]()
        for u in [landscape, portrait] { sources[u] = try await SourceTrack.load(u) }
        let plan = try CompositionBuilder.build(timeline, sources: sources, music: try await MusicSource.load(musicURL),
                                                clips: Dictionary(uniqueKeysWithValues: clips.map { ($0.url, $0) }))
        let gain = try await Exporter.musicGain(timeline)
        let out = TestVideo.directory().appendingPathComponent("out.mp4")
        _ = try await Exporter.export(plan, fps: timeline.fps, gain: gain, to: out)

        let r = try await MediaInspector.inspect(out)
        #expect(r.videoCodec == "avc1")
        #expect(r.width == 1080 && r.height == 1920)
        #expect(abs(r.frameRate - 30) < 0.01)
        #expect(r.audioCodec == "aac" && r.audioSampleRate == 48_000 && r.audioChannels == 2)
        #expect(abs(r.duration - timeline.duration) < 0.05, "duration \(r.duration) vs \(timeline.duration)")
        // a click track has huge crest factor: the peak ceiling, not the target, limits the gain
        #expect(r.loudness <= -13.0)
    }

    @Test func cancelledExportStopsCleanly() async throws {
        let musicURL = try Self.musicFile(bpm: 120, seconds: 20)
        let (clipURL, _) = try await TestVideo.make(name: "cancel", shots: [(1, 6)], width: 640, height: 360)
        let clip = try await ClipAnalyzer.analyze(try await MediaLibrary.loadInfo(clipURL))
        let music = try await MusicAnalyzer.analyze(url: musicURL)
        let (s, e) = music.excerpt(start: music.suggestedStart(length: 12), length: 12)
        let t = try EditPlanner.plan(music: music, musicURL: musicURL, start: s, end: e, clips: [clip], seed: 1)
        let plan = try CompositionBuilder.build(t, sources: [clipURL: try await SourceTrack.load(clipURL)],
                                                music: try await MusicSource.load(musicURL), clips: [clipURL: clip])
        let out = TestVideo.directory().appendingPathComponent("cancelled.mp4")
        try? FileManager.default.removeItem(at: out)
        let task = Task { try await Exporter.export(plan, fps: t.fps, gain: 1, to: out) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let started = Date()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 3, "cancel took too long")
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}
