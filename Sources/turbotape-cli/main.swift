import Foundation
import TurboTapeKit

let usage = """
usage: turbotape-cli analyze-music <audio>
       turbotape-cli analyze-clips <video or folder>...
       turbotape-cli generate --music <audio> --clips <video or folder>... [--length 30] [--seed 1]
                              [--pace chill|normal|hype] [--start <s>] --out <file.mp4>
       turbotape-cli inspect <file>
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(2)
}

/// `--name value` options; `--clips` takes every value up to the next option.
func options(_ args: ArraySlice<String>) -> [String: [String]] {
    var out = [String: [String]]()
    var key: String?
    for a in args {
        if a.hasPrefix("--") {
            key = String(a.dropFirst(2))
            out[key!, default: []] = []
        } else if let key {
            out[key, default: []].append(a)
        } else {
            fail(usage)
        }
    }
    return out
}

func analyzeClips(_ paths: [String], cache: AnalysisCache) async -> [ClipAnalysis] {
    var out = [ClipAnalysis]()
    for url in MediaLibrary.movieFiles(in: paths.map { URL(fileURLWithPath: $0) }) {
        do {
            let info = try await MediaLibrary.loadInfo(url)
            out.append(try await cache.analysis(for: info))
        } catch {
            print("\(url.lastPathComponent): skipped (\(error.localizedDescription))")
        }
    }
    return out
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "analyze-music" where args.count == 2:
        let t0 = Date()
        let a = try await MusicAnalyzer.analyze(url: URL(fileURLWithPath: args[1]))
        print(String(format: "duration %.2f s, %.1f BPM, %d beats, %d downbeats, %d onsets (%.2f s)",
                     a.duration, a.bpm, a.beats.count, a.downbeats.count, a.onsets.count, Date().timeIntervalSince(t0)))
        print("first beats:", a.beats.prefix(8).map { String(format: "%.3f", $0) }.joined(separator: " "))
        let steady = BeatGrid.steady(a)
        let dev = a.beats.map { b in steady.times.map { abs($0 - b) }.min() ?? 0 }.sorted()
        print(String(format: "steady grid %.2f BPM: detected beats are within %.0f ms of it (median), %.0f ms (90%%), %.0f ms (max)",
                     steady.bpm, dev[dev.count / 2] * 1000, dev[dev.count * 9 / 10] * 1000, dev.last! * 1000))
        for length in [15.0, 30, 60] {
            let (s, e) = a.excerpt(start: a.suggestedStart(length: length), length: length)
            print(String(format: "best %2.0f s excerpt: %.2f … %.2f (%.2f s)", length, s, e, e - s))
        }

    case "analyze-clips" where args.count >= 2:
        let cache = AnalysisCache()
        for url in MediaLibrary.movieFiles(in: args.dropFirst().map { URL(fileURLWithPath: $0) }) {
            let t0 = Date()
            do {
                let info = try await MediaLibrary.loadInfo(url)
                let a = try await ClipAnalyzer.analyze(info)
                cache.store(a)
                let best = a.scores.indices.max { a.scores[$0] < a.scores[$1] }.map { a.sampleTimes[$0] } ?? 0
                print(String(format: "%@: %dx%d %.1f s %.0f fps%@ · %d samples, %d shots, score %.2f (best at %.1f s), focus %.2f…%.2f · %.2f s",
                             url.lastPathComponent, info.width, info.height, info.duration, info.frameRate, info.isHDR ? " HDR" : "",
                             a.sampleTimes.count, a.shots.count, a.scores.reduce(0, +) / Float(a.scores.count), best,
                             a.focusX.min() ?? 0, a.focusX.max() ?? 0, Date().timeIntervalSince(t0)))
            } catch {
                print("\(url.lastPathComponent): skipped (\(error.localizedDescription))")
            }
        }

    case "generate":
        let o = options(args.dropFirst())
        guard let music = o["music"]?.first, let clipPaths = o["clips"], !clipPaths.isEmpty, let out = o["out"]?.first else { fail(usage) }
        let length = Double(o["length"]?.first ?? "30") ?? 30
        let seed = UInt64(o["seed"]?.first ?? "1") ?? 1
        let pace = Pace(rawValue: o["pace"]?.first ?? "normal") ?? .normal
        let t0 = Date()
        let musicURL = URL(fileURLWithPath: music)
        // independent: analyse the music while the clips are analysed
        async let musicAnalysis = MusicAnalyzer.analyze(url: musicURL)
        let clips = await analyzeClips(clipPaths, cache: AnalysisCache())
        let analysis = try await musicAnalysis
        let t1 = Date()
        let start = o["start"]?.first.flatMap(Double.init) ?? analysis.suggestedStart(length: length)
        let (s, e) = analysis.excerpt(start: start, length: length, maxLength: ExportPreset.shortsReels.maxDuration)
        let timeline = try EditPlanner.plan(music: analysis, musicURL: musicURL, start: s, end: e, clips: clips,
                                            settings: PlanSettings(pace: pace), seed: seed)
        print(String(format: "%.1f BPM, excerpt %.2f…%.2f s, %d shots from %d clips (analysis %.2f s)",
                     analysis.bpm, s, e, timeline.segments.count, Set(timeline.segments.map(\.clip)).count, t1.timeIntervalSince(t0)))
        var sources = [URL: SourceTrack]()
        for url in Set(timeline.segments.map(\.clip)) { sources[url] = try await SourceTrack.load(url) }
        let plan = try CompositionBuilder.build(timeline, sources: sources, music: try await MusicSource.load(musicURL),
                                                clips: Dictionary(clips.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a }))
        let gain = try await Exporter.musicGain(timeline)
        let report = try await Exporter.export(plan, fps: timeline.fps, gain: gain, to: URL(fileURLWithPath: out))
        print(String(format: "exported %@ in %.2f s (music gain %+.1f dB)", out, report.seconds, report.musicGainDB))

    case "inspect" where args.count == 2:
        print(try await MediaInspector.inspect(URL(fileURLWithPath: args[1])).summary)

    default:
        fail(usage)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
