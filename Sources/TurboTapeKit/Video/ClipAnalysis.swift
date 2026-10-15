import Foundation

/// Per-clip analysis: sampled frame scores, shots, subject position and thumbnails. Cached on disk.
public struct ClipAnalysis: Codable, Sendable {
    /// Bump when the analysis changes, so old caches are ignored.
    public static let version = 3

    public var info: ClipInfo
    /// Source times (seconds) of the analysed samples, increasing.
    public var sampleTimes: [Double]
    /// Quality per sample, 0…1 (sharpness, exposure, motion, aesthetics).
    public var scores: [Float]
    /// Source times where a new shot starts (hard cuts inside the clip), increasing, excluding 0.
    public var shotStarts: [Double]
    /// Raw horizontal centre of interest per sample, 0 (left) … 1 (right), in display orientation.
    /// Noisy on purpose: `ReframePath` decides how the crop moves within a shot.
    public var focusX: [Float]
    /// JPEG thumbnails of every `thumbnailStride`-th sample.
    public var thumbnails: [Data]
    public var thumbnailStride: Int

    public var url: URL { info.url }
    public var duration: Double { info.duration }

    /// Shots as `[start, end)` ranges covering the clip.
    public var shots: [Range<Double>] {
        let bounds = [0] + shotStarts + [duration]
        return zip(bounds, bounds.dropFirst()).compactMap { $0 < $1 ? $0..<$1 : nil }
    }

    /// The thumbnail nearest to source time `t`.
    public func thumbnail(at t: Double) -> Data? {
        thumbnailIndex(at: t).map { thumbnails[$0] }
    }

    /// Index into `thumbnails` of the thumbnail nearest to source time `t`.
    public func thumbnailIndex(at t: Double) -> Int? {
        guard !thumbnails.isEmpty, let i = nearestSampleIndex(t) else { return nil }
        // thumbnail k is sample k·stride: round, not floor, to get the nearest one
        return min(thumbnails.count - 1, Int((Double(i) / Double(max(thumbnailStride, 1))).rounded()))
    }

    public func nearestSampleIndex(_ t: Double) -> Int? {
        guard !sampleTimes.isEmpty else { return nil }
        let lo = min(firstSampleIndex(atOrAfter: t), sampleTimes.count - 1)
        if lo > 0, abs(sampleTimes[lo - 1] - t) < abs(sampleTimes[lo] - t) { return lo - 1 }
        return lo
    }

    /// Index of the first sample at or after `t` (`sampleTimes.count` when there is none).
    func firstSampleIndex(atOrAfter t: Double) -> Int {
        var lo = 0, hi = sampleTimes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sampleTimes[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Mean score of the samples in `[start, start + length]` (the nearest one when none fall inside).
    /// Binary search, not a scan: the planner asks for every candidate window of every clip.
    public func score(start: Double, length: Double) -> Float {
        var sum: Float = 0, n: Float = 0
        let end = start + length, count = min(sampleTimes.count, scores.count)
        var i = firstSampleIndex(atOrAfter: start)
        while i < count, sampleTimes[i] <= end {
            sum += scores[i]
            n += 1
            i += 1
        }
        if n > 0 { return sum / n }
        return nearestSampleIndex(start + length / 2).map { scores[$0] } ?? 0
    }
}
