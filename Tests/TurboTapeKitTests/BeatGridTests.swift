import Foundation
import Testing
@testable import TurboTapeKit

struct BeatGridTests {
    /// 120 BPM beats with ±15 ms jitter and one beat the tracker skipped.
    static func wobbly() -> MusicAnalysis {
        var rng = SplitMix64(seed: 5)
        var m = Fixture.music()
        var beats = m.beats.map { $0 + (rng.nextUnit() - 0.5) * 0.03 }
        beats.remove(at: 40)
        m.beats = beats
        m.beatEnergy = beats.map { _ in 0.5 }
        return m
    }

    @Test func steadyGridHasEqualBeatsAndTheRightTempo() {
        let g = BeatGrid.steady(Self.wobbly())
        let gaps = zip(g.times, g.times.dropFirst()).map { $1 - $0 }
        #expect(gaps.max()! - gaps.min()! < 1e-9)
        #expect(abs(g.bpm - 120) < 0.2, "bpm \(g.bpm)")
        // on the true grid (0.5 + k·0.5 s) within a few ms despite the jitter and the gap
        for t in g.times { #expect(abs((t - 0.5) / 0.5 - ((t - 0.5) / 0.5).rounded()) * 0.5 < 0.006) }
        #expect(g.times.first! >= 0 && g.times.first! < 0.5 + 1e-9)
        #expect(g.times.last! < Self.wobbly().duration)
    }

    @Test func steadyGridIgnoresPhaseSlipsOfTheTracker() {
        // the tracker slips half a beat for a stretch (locked onto off-beats), then comes back
        var m = Fixture.music()
        m.beats = m.beats.enumerated().map { i, t in (60..<90).contains(i) ? t + 0.25 : t }
        m.beatEnergy = m.beats.map { _ in 0.5 }
        let g = BeatGrid.steady(m)
        #expect(abs(g.bpm - 120) < 0.05, "bpm \(g.bpm)")
        // on the true beats, not halfway towards the slipped ones
        #expect(g.agreement(with: Fixture.music().beats, tolerance: 0.005) > 0.99)
    }

    @Test func agreementMeasuresTheFit() {
        let m = Fixture.music()
        let g = BeatGrid.steady(m)
        #expect(g.agreement(with: m.beats) > 0.99)
        #expect(g.shifted(by: 0.2).agreement(with: m.beats) < 0.01)
    }

    @Test func steadyGridKeepsBarsOnTheDownbeats() {
        let m = Fixture.music()
        let g = BeatGrid.steady(m)
        for d in g.downbeatTimes.prefix(10) {
            #expect(m.downbeats.contains { abs($0 - d) < 0.01 }, "\(d) is not a bar start")
        }
    }

    @Test func steadyTempoOverrideKeepsTheAnchorBeat() {
        let m = Fixture.music()
        let g = BeatGrid.steady(m, bpm: 121, anchor: 30.0)
        #expect(abs(g.bpm - 121) < 1e-6)
        #expect(g.times.contains { abs($0 - 30.0) < 1e-6 })
    }

    @Test func editsMoveShiftDeleteInsert() throws {
        let g = BeatGrid.detected(Fixture.music())
        // one beat moves, the others stay; it can't pass its neighbours
        let moved = g.moving(10, to: g.times[10] + 0.03)
        #expect(abs(moved.times[10] - g.times[10] - 0.03) < 1e-9 && moved.times[11] == g.times[11])
        #expect(g.moving(10, to: 1000).times[10] == g.times[11] - BeatGrid.minGap)
        // all beats shift together
        let shifted = g.shifted(by: -0.02)
        #expect(zip(shifted.times, g.times).allSatisfy { abs($0 - $1 + 0.02) < 1e-9 })
        // delete keeps the other downbeat flags
        let deleted = g.deleting(5)
        #expect(deleted.times.count == g.times.count - 1 && !deleted.times.contains(g.times[5]))
        #expect(deleted.downbeatTimes == g.downbeatTimes.filter { $0 != g.times[5] })
        // insert between two beats, refused right next to one
        let (inserted, i) = try #require(g.inserting(at: g.times[3] + 0.25))
        #expect(inserted.times[i] == g.times[3] + 0.25 && i == 4)
        #expect(g.inserting(at: g.times[3] + 0.01) == nil)
    }

    @Test func plannerCutsOnlyOnTheEditedBeats() throws {
        let m = Fixture.music()
        var g = BeatGrid.steady(m).shifted(by: 0.04)
        for _ in 0..<5 { g = g.deleting(20) }
        let t = try EditPlanner.plan(music: m, musicURL: Fixture.musicURL, start: m.beats[8], end: m.beats[8] + 30,
                                     clips: Fixture.clips, beats: g, seed: 1)
        #expect(t.isValid)
        let frames = Set(g.times.map { t.frame(songTime: $0) })
        for c in t.cutFrames { #expect(frames.contains(c), "cut at \(c) is not on an edited beat") }
    }

    @Test func snapGridFollowsTheEditedBeats() throws {
        let m = Fixture.music()
        let t = try Fixture.plan()
        let g = BeatGrid.detected(m).shifted(by: 0.1)
        let snap = SnapGrid(beats: g, onsets: [], timeline: t)
        #expect(snap.beats.allSatisfy { f in g.times.contains { t.frame(songTime: $0) == f } })
    }
}
