import Foundation

/// The horizontal camera move for one shot of a reframed (landscape) clip.
///
/// The raw subject position from Vision is noisy: it flips between objects from one sample to the
/// next, and following it makes the crop swing around as if searching. So a shot gets one calm
/// move instead: hold still when the subject stays roughly in place, otherwise drift slowly
/// (speed-capped, eased in and out) from where the subject is at the start toward where it ends.
public enum ReframePath {
    /// Median filter half-width (seconds): longer flips than this are real moves.
    static let medianRadius = 0.6
    /// Moves smaller than this (fraction of the source width) are not worth a pan.
    static let deadZone: Float = 0.06
    /// Average drift speed limit (source widths per second). The ease-in-out peaks at 1.5×.
    static let maxSpeed: Float = 0.05
    /// Keyframes per second of the eased path (the compositor interpolates linearly between them).
    static let keyframeRate = 10.0

    /// Keyframes (source time, horizontal centre 0…1) for the shot `[start, start + duration]`
    /// given the clip's raw focus samples. Empty input gives a centred, static shot.
    public static func keyframes(times: [Double], raw: [Float], start: Double, duration: Double) -> (times: [Double], values: [Float]) {
        keyframes(times: times, filtered: medianFiltered(times: times, raw: raw), start: start, duration: duration)
    }

    /// The same, from samples already passed through `medianFiltered` (a clip's filtered series
    /// serves all of its segments).
    static func keyframes(times: [Double], filtered: [Float], start: Double, duration: Double) -> (times: [Double], values: [Float]) {
        let end = start + duration
        // the samples of the shot (or the nearest one when the shot falls between samples)
        var inside = times.indices.filter { times[$0] >= start && times[$0] <= end }
        if inside.isEmpty, let nearest = times.indices.min(by: { abs(times[$0] - (start + end) / 2) < abs(times[$1] - (start + end) / 2) }) {
            inside = [nearest]
        }
        guard !inside.isEmpty else { return ([start, end], [0.5, 0.5]) }

        let values = inside.map { filtered[$0] }
        // where the subject is around the start and around the end of the shot
        let edge = max(1, values.count * 2 / 5)
        let from = median(Array(values.prefix(edge)))
        let to = median(Array(values.suffix(edge)))
        guard abs(to - from) >= deadZone, duration > 0 else {
            let hold = median(values)
            return ([start, end], [hold, hold])
        }
        // drift no faster than the cap, centred between the two positions
        let travel = min(abs(to - from), maxSpeed * Float(duration)) * (to > from ? 1 : -1)
        let mid = (from + to) / 2
        let a = mid - travel / 2, b = mid + travel / 2
        let n = max(2, Int((duration * keyframeRate).rounded(.up)) + 1)
        var kt = [Double](), kv = [Float]()
        for k in 0..<n {
            let u = Double(k) / Double(n - 1)
            let eased = Float(u * u * (3 - 2 * u))  // smoothstep: starts and ends at rest
            kt.append(start + u * duration)
            kv.append(a + (b - a) * eased)
        }
        return (kt, kv)
    }

    /// Median of the samples within `medianRadius` seconds of each sample.
    static func medianFiltered(times: [Double], raw: [Float]) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(raw.count)
        var lo = 0, hi = 0
        for i in raw.indices {
            while times[lo] < times[i] - medianRadius { lo += 1 }
            while hi + 1 < raw.count, times[hi + 1] <= times[i] + medianRadius { hi += 1 }
            out.append(median(Array(raw[lo...hi])))
        }
        return out
    }

    static func median(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0.5 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
