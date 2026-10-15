import Foundation

/// How the beat grid is made.
public enum BeatMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The tracked beats: follow the music's own timing, so beat lengths vary a little.
    case detected
    /// A straight line through the tracked beats: every beat exactly as long as the others.
    case steady
    public var id: String { rawValue }
    public var title: String { self == .detected ? "Detected" : "Steady" }
}

/// The beats the video is cut on (song seconds). Starts as the detected or a steady grid and can
/// then be edited by hand: move one beat, shift them all, delete or insert beats.
public struct BeatGrid: Codable, Sendable, Equatable {
    /// Beat times (song seconds), strictly increasing.
    public private(set) var times: [Double]
    /// `downbeat[i]`: beat `i` starts a bar.
    public private(set) var downbeat: [Bool]

    /// Two beats never get closer than this.
    public static let minGap = 0.05

    public init(times: [Double], downbeat: [Bool]) {
        precondition(times.count == downbeat.count)
        self.times = times
        self.downbeat = downbeat
    }

    /// The beats the tracker found.
    public static func detected(_ m: MusicAnalysis) -> BeatGrid {
        BeatGrid(times: m.beats, downbeat: m.beats.indices.map(m.isDownbeat))
    }

    /// An evenly spaced grid fitted to the tracked beats (least squares over beat numbers, so a
    /// skipped or doubled beat in the tracking doesn't bend the line). With `bpm`, that tempo is used
    /// instead of the fitted one, keeping the beat nearest to `anchor` in place.
    public static func steady(_ m: MusicAnalysis, bpm: Double? = nil, anchor: Double? = nil) -> BeatGrid {
        let (fitStart, fitPeriod) = fit(m.beats) ?? (0, 60 / max(m.bpm, 1))
        var start = fitStart, period = fitPeriod
        if let bpm, bpm > 0 {
            period = 60 / bpm
            let a = anchor ?? fitStart
            // keep the fitted beat nearest the anchor where it is
            let k = ((a - fitStart) / fitPeriod).rounded()
            start = fitStart + k * fitPeriod
        }
        // extend over the whole song
        let first = start - (start / period).rounded(.down) * period
        var times = [Double]()
        var t = first
        while t < m.duration {
            times.append(t)
            t += period
        }
        // bars: the phase whose beats land nearest the tracked downbeats
        let downs = m.downbeats
        var phase = 0
        if let d = downs.first, let i = times.indices.min(by: { abs(times[$0] - d) < abs(times[$1] - d) }) { phase = i % MusicAnalysis.beatsPerBar }
        return BeatGrid(times: times, downbeat: times.indices.map { $0 % MusicAnalysis.beatsPerBar == phase })
    }

    /// (time of beat 0, period) of the evenly spaced grid that most tracked beats sit on.
    ///
    /// The tracker sometimes slips phase (locking onto off-beats in a breakdown, say), so neither a
    /// plain least-squares line nor counting beats gap by gap is safe: both get pulled or miscount
    /// across a slip. Instead the period is the one at which the beats are most phase-coherent
    /// (largest resultant of their phase vectors; slipped beats point elsewhere and cancel rather
    /// than bias), and the line is then refit by least squares to the beats within 50 ms of it.
    static func fit(_ beats: [Double]) -> (Double, Double)? {
        guard beats.count >= 2 else { return nil }
        let gaps = zip(beats, beats.dropFirst()).map { $1 - $0 }.sorted()
        let rough = gaps[gaps.count / 2]
        guard rough > 0 else { return nil }
        // the median gap is quantised to the analysis hop (≈ 0.3 % here), so search ±3 % around it,
        // finely enough that the grid drifts well under a beat over the whole song
        let span = max(beats.last! - beats.first!, rough)
        let steps = min(4_000, max(200, Int(0.06 * span / rough * 20)))
        var best = (period: rough, r: -1.0, phase: 0.0)
        for k in 0...steps {
            let p = rough * (0.97 + 0.06 * Double(k) / Double(steps))
            var c = 0.0, s = 0.0
            for t in beats {
                let a = 2 * Double.pi * t / p
                c += cos(a)
                s += sin(a)
            }
            let r = c * c + s * s
            if r > best.r { best = (p, r, atan2(s, c)) }
        }
        var period = best.period
        var offset = (best.phase / (2 * .pi)) * period
        for _ in 0..<2 {
            // the beats on the current line, numbered on it, refit
            var xs = [Double](), ys = [Double]()
            for t in beats {
                let k = ((t - offset) / period).rounded()
                if abs(t - (offset + k * period)) <= 0.05 {
                    xs.append(k)
                    ys.append(t)
                }
            }
            guard xs.count >= max(2, beats.count / 4), let (o, p) = leastSquares(xs, ys), p > 0 else { break }
            (offset, period) = (o, p)
        }
        return (offset, period)
    }

    /// `y ≈ intercept + slope · x`.
    private static func leastSquares(_ xs: [Double], _ ys: [Double]) -> (intercept: Double, slope: Double)? {
        guard xs.count >= 2 else { return nil }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        return (my - slope * mx, slope)
    }

    public var downbeatTimes: [Double] { times.indices.filter { downbeat[$0] }.map { times[$0] } }

    /// Tempo from the median beat length.
    public var bpm: Double {
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
        return gaps.isEmpty ? 0 : 60 / gaps[gaps.count / 2]
    }

    /// Share (0…1) of `beats` lying within `tolerance` seconds of a beat of this grid — how well a
    /// steady grid matches the tracked beats (a song whose tempo drifts scores low).
    public func agreement(with beats: [Double], tolerance: Double = 0.04) -> Double {
        guard !beats.isEmpty, !times.isEmpty else { return 0 }
        var j = 0, hits = 0
        for b in beats {
            while j + 1 < times.count, times[j + 1] <= b { j += 1 }
            let d = min(abs(times[j] - b), j + 1 < times.count ? abs(times[j + 1] - b) : .infinity)
            if d <= tolerance { hits += 1 }
        }
        return Double(hits) / Double(beats.count)
    }

    /// The beat nearest to `t`.
    public func nearest(to t: Double) -> Int? {
        times.indices.min { abs(times[$0] - t) < abs(times[$1] - t) }
    }

    // MARK: - Edits

    /// Move beat `i` to `t`, kept between its neighbours.
    public func moving(_ i: Int, to t: Double) -> BeatGrid {
        guard times.indices.contains(i) else { return self }
        var g = self
        let lo = i > 0 ? times[i - 1] + Self.minGap : -Double.infinity
        let hi = i + 1 < times.count ? times[i + 1] - Self.minGap : Double.infinity
        g.times[i] = min(max(t, lo), max(lo, hi))
        return g
    }

    /// Every beat `dt` seconds later (earlier when negative).
    public func shifted(by dt: Double) -> BeatGrid {
        var g = self
        g.times = times.map { $0 + dt }
        return g
    }

    public func deleting(_ i: Int) -> BeatGrid {
        guard times.indices.contains(i) else { return self }
        var g = self
        g.times.remove(at: i)
        g.downbeat.remove(at: i)
        return g
    }

    /// Insert a beat at `t` (not a bar start). Returns the grid and the new beat's index, or nil when
    /// `t` is too close to an existing beat.
    public func inserting(at t: Double) -> (grid: BeatGrid, index: Int)? {
        guard !times.contains(where: { abs($0 - t) < Self.minGap }) else { return nil }
        let i = times.firstIndex { $0 > t } ?? times.count
        var g = self
        g.times.insert(t, at: i)
        g.downbeat.insert(false, at: i)
        return (g, i)
    }
}

extension MusicAnalysis {
    /// Loudness (0…1, smoothed over a bar) at song time `t`: that of the nearest tracked beat.
    public func energy(at t: Double) -> Float {
        guard !beats.isEmpty, beatEnergy.count == beats.count else { return 0.5 }
        var lo = 0, hi = beats.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(beats[lo - 1] - t) < abs(beats[lo] - t) { lo -= 1 }
        return beatEnergy[lo]
    }
}
