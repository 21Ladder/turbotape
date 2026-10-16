import Foundation

public enum Pace: String, CaseIterable, Codable, Sendable, Identifiable {
    case chill, normal, hype
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    /// Multiplier on the number of beats per cut.
    var factor: Double {
        switch self {
        case .chill: 2
        case .normal: 1
        case .hype: 0.5
        }
    }
}

public struct PlanSettings: Sendable, Equatable {
    public var fps: Int
    public var pace: Pace
    /// No shot shorter than this (seconds); at fast tempos beats are merged.
    public var minShot: Double

    public init(fps: Int = 30, pace: Pace = .normal, minShot: Double = 0.35) {
        self.fps = fps
        self.pace = pace
        self.minShot = minShot
    }
}

/// Turns music + analysed clips into a `Timeline`. Pure and deterministic: the same inputs and
/// seed always give the same edit.
public enum EditPlanner {
    /// Plan the excerpt `[start, end)` of the song, cutting on `beats` (the detected beats when nil).
    /// Segments in `keeping` (pinned by the user) stay exactly as they are; only the gaps between
    /// them are cut and filled again.
    public static func plan(music: MusicAnalysis, musicURL: URL, start: Double, end: Double,
                            clips: [ClipAnalysis], beats: BeatGrid? = nil, settings: PlanSettings = PlanSettings(),
                            seed: UInt64, keeping: [Segment] = []) throws -> Timeline {
        let grid = beats ?? .detected(music)
        let usable = clips.filter { $0.duration >= settings.minShot }
        guard !usable.isEmpty else { throw TurboTapeError.noUsableClips }
        let fps = settings.fps
        let total = Int(((end - start) * Double(fps)).rounded())
        guard total > 0 else { throw TurboTapeError.musicTooShort }
        var rng = SplitMix64(seed: seed)

        // pinned segments that still fit, sorted; the rest of the timeline is free
        let pins = keeping.filter { $0.startFrame >= 0 && $0.endFrame <= total }.sorted { $0.startFrame < $1.startFrame }
        var gaps = [Range<Int>]()
        var f = 0
        for p in pins {
            if p.startFrame > f { gaps.append(f..<p.startFrame) }
            f = max(f, p.endFrame)
        }
        if f < total { gaps.append(f..<total) }

        // beat grid in output frames
        let beatFrames = grid.times.map { Int((($0 - start) * Double(fps)).rounded()) }
        let energy = grid.times.map(music.energy(at:))
        var slots = [Range<Int>]()
        for gap in gaps {
            slots += cutSlots(gap, beatFrames: beatFrames, energy: energy, downbeat: grid.downbeat, settings: settings, rng: &rng)
        }

        // fill the slots in timeline order, pinned segments interleaved
        var picker = ClipPicker(clips: usable, fps: fps)
        for p in pins { picker.markUsed(p) }
        var segments = pins
        var nextID = (pins.map(\.id).max() ?? -1) + 1
        for slot in slots {
            let before = segments.last { $0.endFrame == slot.lowerBound }?.clip
            let after = segments.first { $0.startFrame == slot.upperBound }?.clip
            for part in try picker.fill(slot, avoiding: [before, after].compactMap { $0 }, rng: &rng) {
                segments.append(Segment(id: nextID, clip: part.clip, sourceStart: part.sourceStart, startFrame: part.frames.lowerBound, frameCount: part.frames.count))
                nextID += 1
            }
        }
        segments.sort { $0.startFrame < $1.startFrame }
        return Timeline(fps: fps, music: musicURL, musicStart: start, frameCount: total, segments: segments, seed: seed)
    }

    /// Split `gap` into shots on beats: 1–2 beats per cut when the music is loud, a bar when it is
    /// quiet, scaled by the pace; bars favour downbeats.
    static func cutSlots(_ gap: Range<Int>, beatFrames: [Int], energy: [Float], downbeat: [Bool], settings: PlanSettings,
                         rng: inout SplitMix64) -> [Range<Int>] {
        let minFrames = max(2, Int((settings.minShot * Double(settings.fps)).rounded(.up)))
        var cuts = [gap.lowerBound]
        // the beat the gap starts on (or the last one before it; -1 when it starts before the first)
        var beat = (beatFrames.lastIndex { $0 <= gap.lowerBound }) ?? -1
        while true {
            let e = energy.indices.contains(beat) ? energy[beat] : 0.5
            let options: [(beats: Double, weight: Double)] =
                e > 0.66 ? [(1, 1), (2, 2)] :
                e > 0.33 ? [(2, 3), (4, 1)] :
                [(2, 1), (4, 3)]
            let pick = rng.pick(weights: options.map(\.weight)) ?? 0
            var step = max(1, Int((options[pick].beats * settings.pace.factor).rounded()))
            // a long shot ends on a bar line where it can
            if step >= 4 {
                let target = beat + step
                if let bar = (target - 1...target + 1).first(where: { downbeat.indices.contains($0) && downbeat[$0] }) { step = max(1, bar - beat) }
            }
            // never shorter than the minimum shot
            while beat + step < beatFrames.count, beatFrames[beat + step] - cuts.last! < minFrames { step += 1 }
            beat += step
            guard beat < beatFrames.count, beatFrames[beat] < gap.upperBound else { break }
            cuts.append(beatFrames[beat])
        }
        // a short tail joins the previous shot
        if cuts.count > 1, gap.upperBound - cuts.last! < minFrames { cuts.removeLast() }
        cuts.append(gap.upperBound)
        return zip(cuts, cuts.dropFirst()).map { $0..<$1 }
    }
}

/// Picks which clip and which part of it fills a slot.
struct ClipPicker {
    struct Part {
        var clip: URL
        var sourceStart: Double
        var frames: Range<Int>
    }

    let clips: [ClipAnalysis]
    let fps: Int
    private var uses: [URL: Int] = [:]
    private var used: [URL: [Range<Double>]] = [:]
    private var last: URL?

    init(clips: [ClipAnalysis], fps: Int) {
        self.clips = clips
        self.fps = fps
    }

    mutating func markUsed(_ s: Segment) {
        uses[s.clip, default: 0] += 1
        used[s.clip, default: []].append(s.sourceStart..<s.sourceStart + Double(s.frameCount) / Double(fps))
    }

    /// Fill `slot`, splitting it in half when no clip is long enough.
    mutating func fill(_ slot: Range<Int>, avoiding: [URL], rng: inout SplitMix64) throws -> [Part] {
        let length = Double(slot.count) / Double(fps)
        var avoid = Set(avoiding)
        if let last { avoid.insert(last) }
        if let part = pick(slot, length: length, avoiding: avoid, rng: &rng)
            ?? pick(slot, length: length, avoiding: Set(avoiding), rng: &rng)
            ?? pick(slot, length: length, avoiding: [], rng: &rng)  // a single clip: repeats are unavoidable
        {
            markUsed(Segment(id: 0, clip: part.clip, sourceStart: part.sourceStart, startFrame: slot.lowerBound, frameCount: slot.count))
            last = part.clip
            return [part]
        }
        guard slot.count >= 8 else { throw TurboTapeError.noUsableClips }
        let mid = slot.lowerBound + slot.count / 2
        return try fill(slot.lowerBound..<mid, avoiding: avoiding, rng: &rng) + fill(mid..<slot.upperBound, avoiding: avoiding, rng: &rng)
    }

    private func pick(_ slot: Range<Int>, length: Double, avoiding: Set<URL>, rng: inout SplitMix64) -> Part? {
        // windows per clip: inside one shot, not overlapping material already used
        var candidates = [(clip: ClipAnalysis, windows: [(start: Double, score: Float)])]()
        for c in clips where !avoiding.contains(c.url) && c.duration >= length {
            var windows = windowsFor(c, length: length, allowReuse: false)
            if windows.isEmpty { windows = windowsFor(c, length: length, allowReuse: true) }
            if !windows.isEmpty { candidates.append((c, windows)) }
        }
        guard !candidates.isEmpty else { return nil }
        // every clip gets a turn before any repeats
        let fresh = candidates.contains { uses[$0.clip.url, default: 0] == 0 }
        let weights = candidates.map { c -> Double in
            let best = Double(c.windows.map(\.score).max() ?? 0)
            let n = uses[c.clip.url, default: 0]
            return (0.2 + best * best) / Double(1 + 2 * n) * (fresh && n > 0 ? 0.05 : 1)
        }
        guard let ci = rng.pick(weights: weights) else { return nil }
        let windows = candidates[ci].windows
        // strongly prefer the best parts, but not always the very best one
        let wi = rng.pick(weights: windows.map { pow(Double($0.score) + 0.05, 6) }) ?? 0
        return Part(clip: candidates[ci].clip.url, sourceStart: windows[wi].start, frames: slot)
    }

    func windowsFor(_ c: ClipAnalysis, length: Double, allowReuse: Bool) -> [(start: Double, score: Float)] {
        let step = 0.2
        var out = [(start: Double, score: Float)]()
        var ranges = c.shots.filter { $0.upperBound - $0.lowerBound >= length }
        if ranges.isEmpty { ranges = [0..<c.duration] }  // no shot long enough: may span a cut
        for shot in ranges {
            // stay a frame inside the clip's end: the last frame can be missing in some files
            let last = min(shot.upperBound, c.duration - 1 / Double(fps)) - length
            var s = shot.lowerBound
            while s <= last + 1e-9 {
                let w = s..<s + length
                if allowReuse || !(used[c.url] ?? []).contains(where: { $0.overlaps(w) }) {
                    out.append((s, c.score(start: s, length: length)))
                }
                s += step
            }
        }
        return out
    }
}

// MARK: - Single-shot picks (manual edits)

extension EditPlanner {
    /// The best-scoring `length`-second part of `clip` (inside one shot where possible), or nil
    /// when the clip is too short.
    public static func bestStart(in clip: ClipAnalysis, length: Double, fps: Int) -> Double? {
        ClipPicker(clips: [clip], fps: fps).windowsFor(clip, length: length, allowReuse: true)
            .max { $0.score < $1.score }?.start
    }

    /// Shot `i` re-rolled on its own: another clip (not its neighbours', not its own when others
    /// fit), or else another part of a clip, chosen like Generate does. Nil when nothing fits.
    public static func reroll(_ t: Timeline, segment i: Int, clips: [ClipAnalysis], seed: UInt64) -> Timeline? {
        guard t.segments.indices.contains(i) else { return nil }
        let s = t.segments[i]
        var picker = ClipPicker(clips: clips, fps: t.fps)
        // everything already in the video counts as used, so the shot's current part is not picked again
        for seg in t.segments { picker.markUsed(seg) }
        var rng = SplitMix64(seed: seed)
        let neighbours = [i > 0 ? t.segments[i - 1].clip : nil, i + 1 < t.segments.count ? t.segments[i + 1].clip : nil].compactMap { $0 }
        let slot = s.startFrame..<s.endFrame
        for avoid in [neighbours + [s.clip], neighbours, []] {
            var attempt = picker
            guard let parts = try? attempt.fill(slot, avoiding: avoid, rng: &rng), parts.count == 1 else { continue }
            let p = parts[0]
            if p.clip == s.clip && abs(p.sourceStart - s.sourceStart) < 1e-6 { continue }
            var out = t
            out.segments[i].clip = p.clip
            out.segments[i].sourceStart = p.sourceStart
            out.segments[i].pinned = true
            return out
        }
        return nil
    }
}
