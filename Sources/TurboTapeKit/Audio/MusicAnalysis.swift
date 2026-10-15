import Accelerate
import Foundation

/// Everything the planner and the UI need to know about the music.
public struct MusicAnalysis: Codable, Sendable, Equatable {
    public var duration: Double
    public var bpm: Double
    /// Beat times (seconds), increasing.
    public var beats: [Double]
    /// `beats[i]` starts a bar when `i % 4 == downbeatPhase`.
    public var downbeatPhase: Int
    /// Strong onsets (seconds), including off-beat hits; snap targets for manual cuts.
    public var onsets: [Double]
    /// Loudness per beat, 0 (quietest parts of the song) … 1 (loudest), smoothed over a bar.
    public var beatEnergy: [Float]
    /// Peak envelope for drawing, `waveformRate` values per second, 0…1.
    public var waveform: [Float]
    public var waveformRate: Double

    public static let analysisSampleRate = 22_050.0
    public static let beatsPerBar = 4

    public func isDownbeat(_ i: Int) -> Bool { i % Self.beatsPerBar == downbeatPhase }

    public var downbeats: [Double] { beats.indices.filter(isDownbeat).map { beats[$0] } }

    /// Index of the beat at or after `t`.
    public func beatIndex(atOrAfter t: Double) -> Int? {
        beats.firstIndex { $0 >= t - 1e-6 }
    }

    // MARK: - Choosing the excerpt

    /// The downbeat to start a `length`-second excerpt at: the one whose window is loudest on
    /// average, with a bonus for a jump in energy right at the start (a drop or a chorus).
    public func suggestedStart(length: Double) -> Double {
        let db = beats.indices.filter(isDownbeat)
        guard !db.isEmpty, !beatEnergy.isEmpty else { return 0 }
        var best = beats[db[0]], bestScore = -Float.infinity
        for i in db where beats[i] + length <= duration + 0.5 || i == db[0] {
            let end = beatIndex(atOrAfter: beats[i] + length) ?? beats.count
            let window = beatEnergy[i..<max(i + 1, end)]
            let mean = window.reduce(0, +) / Float(window.count)
            let before = beatEnergy[max(0, i - 8)..<i]
            let after = beatEnergy[i..<min(beats.count, i + 8)]
            let rise = before.isEmpty ? 0 : max(0, after.reduce(0, +) / Float(after.count) - before.reduce(0, +) / Float(before.count))
            let score = mean + 0.5 * rise
            if score > bestScore { bestScore = score; best = beats[i] }
        }
        return best
    }

    /// Excerpt `[start, end)` of roughly `length` seconds: `end` is the downbeat nearest to
    /// `start + length` (so the video ends on a bar line), capped by the song and `maxLength`.
    public func excerpt(start: Double, length: Double, maxLength: Double = 180) -> (start: Double, end: Double) {
        let wanted = min(start + length, duration, start + maxLength)
        let ends = downbeats.filter { $0 > start + 1 && $0 <= min(duration, start + maxLength) }
        guard let nearest = ends.min(by: { abs($0 - wanted) < abs($1 - wanted) }),
              abs(nearest - wanted) <= 60 / bpm * Double(Self.beatsPerBar) / 2 + 0.01
        else { return (start, wanted) }
        return (start, nearest)
    }
}

public enum MusicAnalyzer {
    public static func analyze(url: URL) async throws -> MusicAnalysis {
        let audio = try await AudioDecoder.decode(url: url, sampleRate: MusicAnalysis.analysisSampleRate, channels: 1)
        return try analyze(mono: audio.channels.first ?? [], sampleRate: audio.sampleRate)
    }

    public static func analyze(mono x: [Float], sampleRate: Double) throws -> MusicAnalysis {
        let duration = Double(x.count) / sampleRate
        guard duration >= 4 else { throw TurboTapeError.musicTooShort }
        let track = try BeatDetector.detect(mono: x, sampleRate: sampleRate)
        return MusicAnalysis(
            duration: duration,
            bpm: track.bpm,
            beats: track.beats,
            downbeatPhase: downbeatPhase(track),
            onsets: track.onsets,
            beatEnergy: beatEnergy(x, sampleRate: sampleRate, beats: track.beats),
            waveform: waveform(x, sampleRate: sampleRate, rate: 50),
            waveformRate: 50
        )
    }

    /// The phase (0…3) whose beats hit hardest, weighting the kick band double: bars usually start
    /// on a kick, while the snare on 2 and 4 is often louder across the spectrum.
    static func downbeatPhase(_ t: BeatTrack) -> Int {
        let bar = MusicAnalysis.beatsPerBar
        var score = [Float](repeating: 0, count: bar)
        var count = [Float](repeating: 0, count: bar)
        for i in t.beats.indices {
            score[i % bar] += 2 * t.beatLowStrengths[i] + t.beatStrengths[i]
            count[i % bar] += 1
        }
        let mean = zip(score, count).map { $1 > 0 ? $0 / $1 : 0 }
        return mean.indices.max { mean[$0] < mean[$1] } ?? 0
    }

    /// RMS (dB) between consecutive beats, mapped so the 10th…90th percentile spans 0…1, then
    /// averaged over a bar centred on the beat.
    static func beatEnergy(_ x: [Float], sampleRate: Double, beats: [Double]) -> [Float] {
        guard !beats.isEmpty else { return [] }
        var db = [Float]()
        x.withUnsafeBufferPointer { p in
            for i in beats.indices {
                let a = min(p.count, max(0, Int(beats[i] * sampleRate)))
                let b = min(p.count, i + 1 < beats.count ? Int(beats[i + 1] * sampleRate) : a + Int(0.5 * sampleRate))
                let ms = b > a ? vDSP.meanSquare(UnsafeBufferPointer(rebasing: p[a..<b])) : 0
                db.append(10 * log10(ms + 1e-10))
            }
        }
        let sorted = db.sorted()
        let lo = sorted[sorted.count / 10], hi = sorted[sorted.count * 9 / 10]
        let norm = db.map { hi > lo ? min(max(($0 - lo) / (hi - lo), 0), 1) : 0.5 }
        let r = MusicAnalysis.beatsPerBar / 2
        return norm.indices.map { i in
            let w = norm[max(0, i - r)..<min(norm.count, i + r + 1)]  // centred: r beats either side
            return w.reduce(0, +) / Float(w.count)
        }
    }

    static func waveform(_ x: [Float], sampleRate: Double, rate: Double) -> [Float] {
        let step = max(1, Int(sampleRate / rate))
        var out = [Float]()
        out.reserveCapacity(x.count / step + 1)
        x.withUnsafeBufferPointer { p in
            var i = 0
            while i < p.count {
                out.append(vDSP.maximumMagnitude(UnsafeBufferPointer(rebasing: p[i..<min(p.count, i + step)])))
                i += step
            }
        }
        let peak = out.max() ?? 0
        return peak > 0 ? vDSP.divide(out, peak) : out
    }
}
