import Foundation
import Testing
@testable import TurboTapeKit

struct BeatDetectorTests {
    /// One output frame at 30 fps.
    static let tolerance = 1.0 / 30

    @Test(arguments: [90.0, 120.0, 140.0])
    func findsBeatsOfClickTrack(bpm: Double) throws {
        let (x, truth) = Synth.clickTrack(bpm: bpm, seconds: 30)
        let a = try MusicAnalyzer.analyze(mono: x, sampleRate: 22_050)
        #expect(abs(a.bpm - bpm) / bpm < 0.01, "bpm \(a.bpm)")
        // every detected beat sits on a true beat
        for b in a.beats {
            let nearest = truth.min { abs($0 - b) < abs($1 - b) }!
            #expect(abs(nearest - b) <= Self.tolerance, "beat at \(b) is \(nearest - b) s off")
        }
        // and nearly all true beats are found (edges may be trimmed)
        #expect(a.beats.count >= truth.count - 2)
    }

    @Test func fastTempoIsFoundOrHalved() throws {
        // 174 BPM is often felt (and tracked) at 87: either is fine for cutting
        let (x, truth) = Synth.clickTrack(bpm: 174, seconds: 30)
        let a = try MusicAnalyzer.analyze(mono: x, sampleRate: 22_050)
        #expect(abs(a.bpm - 174) / 174 < 0.01 || abs(a.bpm - 87) / 87 < 0.01, "bpm \(a.bpm)")
        for b in a.beats {
            let nearest = truth.min { abs($0 - b) < abs($1 - b) }!
            #expect(abs(nearest - b) <= Self.tolerance)
        }
    }

    @Test func findsDownbeats() throws {
        let (x, truth) = Synth.clickTrack(bpm: 120, seconds: 30)
        let a = try MusicAnalyzer.analyze(mono: x, sampleRate: 22_050)
        let barStarts = Set(stride(from: 0, to: truth.count, by: 4).map { Int((truth[$0] * 30).rounded()) })
        for d in a.downbeats {
            #expect(barStarts.contains(Int((d * 30).rounded())) || barStarts.contains(Int((d * 30).rounded()) - 1) || barStarts.contains(Int((d * 30).rounded()) + 1),
                    "downbeat at \(d) is not a bar start")
        }
    }

    @Test func silenceHasNoBeat() {
        let x = [Float](repeating: 0, count: 22_050 * 10)
        #expect(throws: TurboTapeError.self) { try MusicAnalyzer.analyze(mono: x, sampleRate: 22_050) }
    }

    @Test func excerptEndsOnADownbeat() throws {
        let (x, _) = Synth.clickTrack(bpm: 120, seconds: 60)
        let a = try MusicAnalyzer.analyze(mono: x, sampleRate: 22_050)
        let start = a.suggestedStart(length: 15)
        #expect(a.downbeats.contains(start))
        let (s, e) = a.excerpt(start: start, length: 15)
        #expect(a.downbeats.contains(e))
        #expect(abs((e - s) - 15) <= 1.0 + 1e-9)  // within half a bar at 120 BPM
    }
}

struct LoudnessTests {
    @Test func sineMatchesReference() {
        // BS.1770: a 997 Hz sine at −20 dBFS in both channels of stereo reads −20 LUFS
        let x = Synth.sine(hz: 997, dbfs: -20, seconds: 5)
        let l = Loudness.integrated(x, sampleRate: 48_000)
        #expect(abs(l - -20) < 0.1, "got \(l)")
    }

    @Test func oneChannelIsThreeDecibelsLower() {
        let s = Synth.sine(hz: 997, dbfs: 0, seconds: 5)
        let l = Loudness.integrated([s[0], [Float](repeating: 0, count: s[0].count)], sampleRate: 48_000)
        #expect(abs(l - -3.01) < 0.1, "got \(l)")
    }

    @Test func gainRespectsPeakCeiling() {
        // quiet but peaky: the target would need +10 dB, the peak only allows +0.5 dB
        let g = Loudness.normalizationGain(lufs: -24, peak: Float(pow(10, -1.5 / 20)))
        #expect(abs(20 * log10(Double(g)) - 0.5) < 0.01)
        // loud master: turned down to −14
        let d = Loudness.normalizationGain(lufs: -8, peak: 1)
        #expect(abs(20 * log10(Double(d)) - -6) < 0.01)
    }

    @Test func silenceIsMinusInfinity() {
        #expect(Loudness.integrated([[Float](repeating: 0, count: 48_000)], sampleRate: 48_000) == -.infinity)
    }
}
