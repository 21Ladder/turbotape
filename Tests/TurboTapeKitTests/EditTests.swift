import Foundation
import Testing
@testable import TurboTapeKit

/// Fixtures that need no decoding: a 120 BPM beat grid and fake clip analyses.
enum Fixture {
    static let musicURL = URL(fileURLWithPath: "/music.mp3")

    static func music(bpm: Double = 120, seconds: Double = 90, energy: (Int) -> Float = { i in i % 32 < 16 ? 0.2 : 0.9 }) -> MusicAnalysis {
        let beats = stride(from: 0.5, to: seconds, by: 60 / bpm).map { $0 }
        return MusicAnalysis(duration: seconds, bpm: bpm, beats: beats, downbeatPhase: 0,
                             onsets: beats.map { $0 + 0.11 }, beatEnergy: beats.indices.map(energy),
                             waveform: [], waveformRate: 50)
    }

    static func clip(_ name: String, duration: Double, shots: [Double] = [], score: (Double) -> Float = { _ in 0.6 }) -> ClipAnalysis {
        let times = stride(from: 0.1, to: duration, by: 0.2).map { $0 }
        let info = ClipInfo(url: URL(fileURLWithPath: "/clips/\(name).mov"), duration: duration, width: 1920, height: 1080,
                            frameRate: 30, isHDR: false, fileSize: 1, modified: .distantPast)
        return ClipAnalysis(info: info, sampleTimes: times, scores: times.map(score), shotStarts: shots,
                            focusX: times.map { _ in 0.5 }, thumbnails: [], thumbnailStride: 2)
    }

    static let clips = [
        clip("a", duration: 20, shots: [8]),
        clip("b", duration: 6),
        clip("c", duration: 40, shots: [10, 25], score: { $0 > 30 ? 0.95 : 0.4 }),
        clip("d", duration: 1.2),
    ]

    static func plan(seed: UInt64 = 1, keeping: [Segment] = [], pace: Pace = .normal, clips: [ClipAnalysis] = clips) throws -> Timeline {
        let m = music()
        return try EditPlanner.plan(music: m, musicURL: musicURL, start: m.beats[8], end: m.beats[8] + 30,
                                    clips: clips, settings: PlanSettings(pace: pace), seed: seed, keeping: keeping)
    }

    static var durations: [URL: Double] { Dictionary(uniqueKeysWithValues: clips.map { ($0.url, $0.duration) }) }
}

struct PlannerTests {
    @Test(arguments: [Pace.chill, .normal, .hype])
    func cutsLandOnBeatsAndTotalIsExact(pace: Pace) throws {
        let t = try Fixture.plan(pace: pace)
        #expect(t.isValid)
        #expect(t.frameCount == 900)
        let m = Fixture.music()
        let beatFrames = Set(m.beats.map { t.frame(songTime: $0) })
        for c in t.cutFrames { #expect(beatFrames.contains(c), "cut at frame \(c) is not on a beat") }
        #expect(t.segments.allSatisfy { Double($0.frameCount) / 30 >= 0.35 })
    }

    @Test func paceChangesCutCount() throws {
        let chill = try Fixture.plan(pace: .chill).segments.count
        let hype = try Fixture.plan(pace: .hype).segments.count
        #expect(hype > chill * 2, "hype \(hype) vs chill \(chill)")
    }

    @Test func noConsecutiveSameSource() throws {
        for seed in 1...20 as ClosedRange<UInt64> {
            let t = try Fixture.plan(seed: seed)
            for (a, b) in zip(t.segments, t.segments.dropFirst()) { #expect(a.clip != b.clip, "seed \(seed)") }
        }
    }

    @Test func segmentsStayInsideClipsAndShots() throws {
        let byURL = Dictionary(uniqueKeysWithValues: Fixture.clips.map { ($0.url, $0) })
        for seed in 1...20 as ClosedRange<UInt64> {
            for s in try Fixture.plan(seed: seed).segments {
                let c = byURL[s.clip]!
                let end = s.sourceStart + Double(s.frameCount) / 30
                #expect(s.sourceStart >= 0 && end <= c.duration + 1e-9)
                if c.shots.contains(where: { $0.upperBound - $0.lowerBound >= end - s.sourceStart }) {
                    #expect(c.shots.contains { $0.lowerBound <= s.sourceStart + 1e-9 && end <= $0.upperBound + 1e-9 }, "segment spans a shot cut")
                }
            }
        }
    }

    @Test func everyClipIsUsedBeforeRepeats() throws {
        let t = try Fixture.plan()
        let firstFour = t.segments.prefix(4).map(\.clip)
        // "d" is only 1.2 s long, so it may only fit short slots; the others must all appear early
        #expect(Set(t.segments.prefix(6).map(\.clip)).count >= 3, "\(firstFour)")
        #expect(Set(t.segments.map(\.clip)).count == 4)
    }

    @Test func sameSeedSameTimeline() throws {
        #expect(try Fixture.plan(seed: 9) == Fixture.plan(seed: 9))
        #expect(try Fixture.plan(seed: 9) != Fixture.plan(seed: 10))
    }

    @Test func prefersBetterParts() throws {
        // clip c is great after 30 s: most of its picks should come from there
        var good = 0, all = 0
        for seed in 1...30 as ClosedRange<UInt64> {
            for s in try Fixture.plan(seed: seed).segments where s.clip.lastPathComponent == "c.mov" {
                all += 1
                if s.sourceStart >= 25 { good += 1 }
            }
        }
        #expect(Double(good) / Double(all) > 0.5, "\(good)/\(all)")
    }

    @Test func singleShortClipStillFills() throws {
        let t = try Fixture.plan(clips: [Fixture.clip("only", duration: 0.8)])
        #expect(t.isValid)
    }

    @Test func noClipsThrows() {
        #expect(throws: TurboTapeError.self) { try Fixture.plan(clips: []) }
    }
}

struct EditTests {
    @Test func rollKeepsTotalAndOtherCuts() throws {
        let t = try Fixture.plan()
        let r = TimelineEdits.rollCut(t, before: 3, to: t.segments[3].startFrame + 5, durations: Fixture.durations)
        #expect(r.timeline.isValid)
        #expect(r.timeline.frameCount == t.frameCount)
        var expected = t.cutFrames
        expected[2] += 5
        if !r.clamped { #expect(r.timeline.cutFrames == expected) }
        #expect(r.timeline.segments[2].pinned && r.timeline.segments[3].pinned)
        // the incoming clip's content stays aligned: its in-point moved with the cut
        if !r.clamped { #expect(abs(r.timeline.segments[3].sourceStart - (t.segments[3].sourceStart + 5.0 / 30)) < 1e-9) }
    }

    @Test func rollRespectsMinimumAndSourceBounds() throws {
        let t = try Fixture.plan()
        let r = TimelineEdits.rollCut(t, before: 1, to: -100, durations: Fixture.durations)
        #expect(r.clamped)
        #expect(r.timeline.isValid)
        #expect(r.timeline.segments[0].frameCount >= TimelineEdits.minFrames)
        let far = TimelineEdits.rollCut(t, before: 1, to: 10_000, durations: Fixture.durations)
        #expect(far.clamped && far.timeline.isValid)
        let s = far.timeline.segments[0]
        #expect(s.sourceStart + Double(s.frameCount) / 30 <= Fixture.durations[s.clip]! + 1e-9)
        #expect(far.timeline.segments[1].frameCount >= TimelineEdits.minFrames)
    }

    @Test func slipKeepsPlaceAndClamps() throws {
        let t = try Fixture.plan()
        let s = t.segments[2]
        let r = TimelineEdits.slip(t, segment: 2, byFrames: 60, duration: Fixture.durations[s.clip])
        #expect(r.timeline.segments[2].startFrame == s.startFrame && r.timeline.segments[2].frameCount == s.frameCount)
        #expect(r.timeline.segments[2].pinned)
        let back = TimelineEdits.slip(t, segment: 2, byFrames: -100_000, duration: Fixture.durations[s.clip])
        #expect(back.clamped && back.timeline.segments[2].sourceStart == 0)
        let fwd = TimelineEdits.slip(t, segment: 2, byFrames: 100_000, duration: Fixture.durations[s.clip])
        #expect(fwd.clamped)
        #expect(abs(fwd.timeline.segments[2].sourceStart + Double(s.frameCount) / 30 - Fixture.durations[s.clip]!) < 1e-9)
    }

    @Test func snapFindsBeatsAndOnsets() throws {
        let t = try Fixture.plan()
        let grid = SnapGrid(music: Fixture.music(), timeline: t)
        let beat = grid.beats[5]
        #expect(grid.snap(beat + 2, radius: 4)?.frame == beat)
        #expect(grid.snap(beat + 3, radius: 4)?.kind == .onset)  // onsets sit 0.11 s (3 frames) after each beat
        #expect(grid.snap(beat + 5, radius: 1) == nil)
        #expect(grid.describe(beat + 2)?.offset == 2)
    }

    @Test func reSnapMovesCutsBackOntoBeats() throws {
        let t = try Fixture.plan()
        let grid = SnapGrid(music: Fixture.music(), timeline: t)
        var off = t
        for i in [2, 5, 8] { off = TimelineEdits.rollCut(off, before: i, to: off.segments[i].startFrame + 2, durations: Fixture.durations).timeline }
        let fixed = TimelineEdits.reSnapAll(off, grid: grid, radius: 2, durations: Fixture.durations)
        #expect(fixed.cutFrames == t.cutFrames)
    }

    @Test func shuffleKeepsPinnedSegments() throws {
        let t = try Fixture.plan(seed: 3)
        var edited = TimelineEdits.slip(t, segment: 4, byFrames: 15, duration: Fixture.durations[t.segments[4].clip]).timeline
        edited = TimelineEdits.rollCut(edited, before: 9, to: edited.segments[9].startFrame + 3, durations: Fixture.durations).timeline
        let pinned = edited.segments.filter(\.pinned)
        #expect(pinned.count >= 2)
        let shuffled = try Fixture.plan(seed: 99, keeping: pinned)
        #expect(shuffled.isValid)
        for p in pinned { #expect(shuffled.segments.contains(p), "pinned segment \(p.id) changed") }
        #expect(shuffled.segments.filter { !$0.pinned } != edited.segments.filter { !$0.pinned })
    }

    @Test func undoIsJustTheOldValue() throws {
        let t = try Fixture.plan()
        let edited = TimelineEdits.rollCut(t, before: 2, to: t.segments[2].startFrame + 4, durations: Fixture.durations).timeline
        #expect(edited != t)
        // the app's undo stores the previous value; encoding round-trips exactly
        for value in [t, edited] {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(Timeline.self, from: data) == value)
        }
    }
}
