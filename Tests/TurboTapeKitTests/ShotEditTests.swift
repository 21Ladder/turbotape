import Foundation
import Testing
@testable import TurboTapeKit

struct ShotEditTests {
    @Test func moveKeepsTheCutsAndMovesTheContents() throws {
        let t = try Fixture.plan(seed: 4)
        let before = t.segments
        let r = try #require(TimelineEdits.moveShot(t, from: 2, to: 6, durations: Fixture.durations))
        let after = r.timeline.segments
        #expect(r.timeline.isValid)
        // the slots (where the cuts are) don't change
        #expect(after.map(\.startFrame) == before.map(\.startFrame) && after.map(\.frameCount) == before.map(\.frameCount))
        // shot 2's content is now at 6, 3…6 moved one to the left, the rest is untouched
        #expect(after[6].clip == before[2].clip && after[6].id == before[2].id && after[6].pinned)
        for k in 2..<6 { #expect(after[k].id == before[k + 1].id && after[k].clip == before[k + 1].clip) }
        for k in after.indices where !(2...6).contains(k) { #expect(after[k] == before[k]) }
        // every clip still fits its (possibly longer) slot
        for s in after { #expect(s.sourceStart + Double(s.frameCount) / 30 <= Fixture.durations[s.clip]! + 1e-9) }
        // moving back to the left works the same way
        let back = try #require(TimelineEdits.moveShot(r.timeline, from: 6, to: 2, durations: Fixture.durations))
        #expect(back.timeline.segments.map(\.id) == before.map(\.id))
    }

    @Test func moveRefusesAClipTooShortForItsNewSlot() throws {
        var t = try Fixture.plan(seed: 4)
        // make shot 0 a 1.2 s clip and give shot 5 a long slot
        t.segments[0].clip = URL(fileURLWithPath: "/clips/d.mov")
        t.segments[0].sourceStart = 0
        let long = t.segments.indices.first { $0 > 0 && Double(t.segments[$0].frameCount) / 30 > 1.2 }
        let target = try #require(long)
        #expect(TimelineEdits.moveShot(t, from: 0, to: target, durations: Fixture.durations) == nil)
    }

    @Test func replacePicksTheBestPartOfTheNewClip() throws {
        let t = try Fixture.plan(seed: 4)
        let c = Fixture.clips[2]  // great after 30 s
        let i = try #require(t.segments.indices.first { t.segments[$0].clip != c.url })
        let out = try #require(TimelineEdits.replaceClip(t, segment: i, with: c))
        let s = out.segments[i]
        #expect(s.clip == c.url && s.pinned && out.isValid)
        #expect(s.sourceStart >= 25, "picked \(s.sourceStart)")
        #expect(s.sourceStart + Double(s.frameCount) / 30 <= c.duration)
        #expect(out.segments.indices.filter { $0 != i }.allSatisfy { out.segments[$0] == t.segments[$0] })
        // too short
        let tiny = Fixture.clip("tiny", duration: 0.2)
        #expect(TimelineEdits.replaceClip(t, segment: i, with: tiny) == nil)
    }

    @Test func rerollChangesOnlyThatShot() throws {
        let t = try Fixture.plan(seed: 4)
        for i in [0, 3, t.segments.count - 1] {
            let out = try #require(EditPlanner.reroll(t, segment: i, clips: Fixture.clips, seed: 77))
            let s = out.segments[i], old = t.segments[i]
            #expect(out.isValid && s.pinned)
            #expect(s.clip != old.clip || abs(s.sourceStart - old.sourceStart) > 1e-6)
            #expect(s.startFrame == old.startFrame && s.frameCount == old.frameCount)
            #expect(out.segments.indices.filter { $0 != i }.allSatisfy { out.segments[$0] == t.segments[$0] })
            // not the same clip as a neighbour (enough clips to avoid it here)
            if i > 0 { #expect(s.clip != out.segments[i - 1].clip) }
            if i + 1 < out.segments.count { #expect(s.clip != out.segments[i + 1].clip) }
        }
        #expect(EditPlanner.reroll(t, segment: 3, clips: Fixture.clips, seed: 77) == EditPlanner.reroll(t, segment: 3, clips: Fixture.clips, seed: 77))
    }
}
