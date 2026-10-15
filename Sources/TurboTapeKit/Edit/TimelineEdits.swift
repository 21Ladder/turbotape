import Foundation

/// Snap targets for manual cuts, in output frames.
public struct SnapGrid: Sendable, Equatable {
    public var beats: [Int]
    public var halfBeats: [Int]
    public var onsets: [Int]
    /// Beat frames that start a bar.
    public var downbeats: [Int]

    public init(music: MusicAnalysis, timeline: Timeline) {
        self.init(beats: .detected(music), onsets: music.onsets, timeline: timeline)
    }

    public init(beats grid: BeatGrid, onsets songOnsets: [Double], timeline: Timeline) {
        let inRange = { (f: Int) in f > 0 && f < timeline.frameCount }
        beats = grid.times.map { timeline.frame(songTime: $0) }.filter(inRange)
        downbeats = grid.downbeatTimes.map { timeline.frame(songTime: $0) }.filter(inRange)
        halfBeats = zip(grid.times, grid.times.dropFirst()).map { timeline.frame(songTime: ($0 + $1) / 2) }.filter(inRange)
        onsets = songOnsets.map { timeline.frame(songTime: $0) }.filter(inRange)
    }

    public enum Kind: Sendable { case beat, halfBeat, onset }

    /// The target nearest to `frame` within `radius` frames. Beats are preferred: a half-beat or
    /// an onset only wins when it is at least two frames closer than the nearest beat.
    public func snap(_ frame: Int, radius: Int) -> (frame: Int, kind: Kind)? {
        var best: (frame: Int, kind: Kind, d: Int)?
        for (list, kind, bias) in [(beats, Kind.beat, 0), (halfBeats, .halfBeat, 1), (onsets, .onset, 1)] {
            for f in list where abs(f - frame) <= radius {
                let d = abs(f - frame) + bias
                if best == nil || d < best!.d { best = (f, kind, d) }
            }
        }
        return best.map { ($0.frame, $0.kind) }
    }

    /// The beat before / after `frame`.
    public func beat(before frame: Int) -> Int? { beats.last { $0 < frame } }
    public func beat(after frame: Int) -> Int? { beats.first { $0 > frame } }

    /// Which beat (1-based) a frame is on and how far off, e.g. ("beat 17", +2).
    public func describe(_ frame: Int) -> (beat: Int, offset: Int)? {
        guard let i = beats.indices.min(by: { abs(beats[$0] - frame) < abs(beats[$1] - frame) }) else { return nil }
        return (i + 1, frame - beats[i])
    }
}

/// Manual edits. Each returns a new timeline (value semantics make undo trivial) and pins the
/// segments it touches so Shuffle keeps them.
public enum TimelineEdits {
    /// Shortest segment a manual edit may leave.
    public static let minFrames = 4

    public struct Result: Sendable {
        public var timeline: Timeline
        /// The edit hit a limit (minimum length or the end of a source clip).
        public var clamped: Bool
    }

    /// Roll edit: move the cut before `segment` to output frame `target`. The left segment gets
    /// longer and the right one shorter (or the reverse); the total and all other cuts stay put.
    /// The right segment's in-point moves with the cut, so its content stays aligned.
    public static func rollCut(_ t: Timeline, before segment: Int, to target: Int, durations: [URL: Double]) -> Result {
        guard segment > 0, segment < t.segments.count else { return Result(timeline: t, clamped: true) }
        var out = t
        let l = t.segments[segment - 1], r = t.segments[segment]
        let fps = Double(t.fps)
        var lo = l.startFrame + minFrames, hi = r.endFrame - minFrames
        // the left clip cannot play past its end; the right one cannot start before 0
        // (a hair of tolerance: a segment slipped to its clip's end must not lose a frame to rounding)
        if let d = durations[l.clip] { hi = min(hi, l.startFrame + Int(((d - l.sourceStart) * fps + 1e-6).rounded(.down))) }
        lo = max(lo, r.startFrame - Int((r.sourceStart * fps + 1e-6).rounded(.down)))
        // when the limits cross (segments shorter than `minFrames`), never empty either side
        let f = min(max(min(max(target, lo), max(lo, hi)), l.startFrame + 1), r.endFrame - 1)
        let delta = f - r.startFrame
        out.segments[segment - 1].frameCount += delta
        out.segments[segment].startFrame += delta
        out.segments[segment].frameCount -= delta
        out.segments[segment].sourceStart = max(0, r.sourceStart + Double(delta) / fps)
        if delta != 0 {
            out.segments[segment - 1].pinned = true
            out.segments[segment].pinned = true
        }
        return Result(timeline: out, clamped: f != target)
    }

    /// Slip edit: play a different part of the clip in the same place — `sourceStart` moves by
    /// `frames` output frames, position and length on the timeline stay.
    public static func slip(_ t: Timeline, segment: Int, byFrames frames: Int, duration: Double?) -> Result {
        setSourceStart(t, segment: segment, to: (t.segments.indices.contains(segment) ? t.segments[segment].sourceStart : 0) + Double(frames) / Double(t.fps), duration: duration)
    }

    /// Slip to an absolute in-point (seconds), clamped to the clip.
    public static func setSourceStart(_ t: Timeline, segment: Int, to start: Double, duration: Double?) -> Result {
        guard t.segments.indices.contains(segment) else { return Result(timeline: t, clamped: true) }
        var out = t
        let s = t.segments[segment]
        let maxStart = max(0, (duration ?? .infinity) - Double(s.frameCount) / Double(t.fps))
        let v = min(max(start, 0), maxStart)
        out.segments[segment].sourceStart = v
        if v != s.sourceStart { out.segments[segment].pinned = true }
        return Result(timeline: out, clamped: abs(v - start) > 1e-9)
    }

    public static func setPinned(_ t: Timeline, segment: Int, _ pinned: Bool) -> Timeline {
        var out = t
        if out.segments.indices.contains(segment) { out.segments[segment].pinned = pinned }
        return out
    }

    /// Move every cut to the nearest beat or onset within `radius` frames (pins are unchanged).
    public static func reSnapAll(_ t: Timeline, grid: SnapGrid, radius: Int, durations: [URL: Double]) -> Timeline {
        var out = t
        for i in out.segments.indices.dropFirst() {
            let f = out.segments[i].startFrame
            guard let target = grid.snap(f, radius: radius)?.frame, target != f else { continue }
            let pins = (out.segments[i - 1].pinned, out.segments[i].pinned)
            out = rollCut(out, before: i, to: target, durations: durations).timeline
            out.segments[i - 1].pinned = pins.0
            out.segments[i].pinned = pins.1
        }
        return out
    }
}
