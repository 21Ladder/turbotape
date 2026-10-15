/// Shot changes (hard cuts) inside a source clip.
///
/// Each frame is reduced to a
/// `Signature`: a 32×18 grid of mean luma and a 16-bin histogram per RGB channel. The difference
/// of two frames mixes the histogram distance with the mean absolute luma difference of the grids.
/// A hard cut changes both; camera or subject motion moves the grid but keeps the histogram.
///
/// `detectCuts` marks frame *i* as the first frame of a new shot when its difference is above an
/// absolute threshold set by the sensitivity **and** clearly above the local activity (the median
/// of the differences around it). Shots shorter than `minShotFrames` are merged.
public struct FrameSignature: Sendable, Equatable {
    static let gw = 32, gh = 18, bins = 16

    var grid: [Float]
    var hist: [Float]

    /// Reduce an RGBA8 frame (`w`×`h`, row-major, `rowBytes` per row).
    public init(rgba: UnsafeRawBufferPointer, width w: Int, height h: Int, rowBytes: Int) {
        let gw = Self.gw, gh = Self.gh, bins = Self.bins
        var grid = [Float](repeating: 0, count: gw * gh)
        var count = [Float](repeating: 0, count: gw * gh)
        var hist = [Float](repeating: 0, count: 3 * bins)
        guard w > 0, h > 0, rgba.count >= rowBytes * h else {
            self.grid = grid
            self.hist = hist
            return
        }
        let stepX = max(1, w / 256), stepY = max(1, h / 144)
        var n: Float = 0
        let p = rgba.bindMemory(to: UInt8.self)
        for y in stride(from: 0, to: h, by: stepY) {
            let gy = y * gh / h
            for x in stride(from: 0, to: w, by: stepX) {
                let i = y * rowBytes + x * 4
                let r = p[i], g = p[i + 1], b = p[i + 2]
                let gi = gy * gw + x * gw / w
                grid[gi] += 0.2126 * Float(r) + 0.7152 * Float(g) + 0.0722 * Float(b)
                count[gi] += 1
                hist[Int(r) * bins / 256] += 1
                hist[bins + Int(g) * bins / 256] += 1
                hist[2 * bins + Int(b) * bins / 256] += 1
                n += 1
            }
        }
        for i in grid.indices { grid[i] = count[i] > 0 ? grid[i] / count[i] / 255 : 0 }
        let inv = 1 / max(n, 1)
        for i in hist.indices { hist[i] *= inv }
        self.grid = grid
        self.hist = hist
    }

    /// How different two frames look, 0 (identical) … 1.
    public func difference(_ o: FrameSignature) -> Float {
        var h: Float = 0
        for i in hist.indices { h += abs(hist[i] - o.hist[i]) }
        h /= 6  // per channel: half the L1 distance of two distributions is in 0…1
        var g: Float = 0
        for i in grid.indices { g += abs(grid[i] - o.grid[i]) }
        g /= Float(grid.count)
        // the grid term rarely exceeds ~0.5 even between unrelated shots: weigh it up
        return min(max(0.5 * h + 0.5 * min(2 * g, 1), 0), 1)
    }
}

public enum ShotDetector {
    public struct Options: Sendable {
        /// 0 (only the most obvious cuts) … 100 (also subtle ones).
        public var sensitivity: Float = 50
        /// Shortest shot kept, in analysed frames.
        public var minShotFrames = 2
        public init() {}

        var threshold: Float { 0.45 - 0.33 * min(max(sensitivity, 0), 100) / 100 }
    }

    /// Frames that start a new shot. `diffs[i]` is the difference between frame `i - 1` and `i`
    /// (`diffs[0]` is ignored).
    public static func detectCuts(_ diffs: [Float], options opt: Options = Options()) -> [Int] {
        let window = 5
        let thr = opt.threshold
        var cuts = [Int]()
        for i in diffs.indices.dropFirst() {
            let d = diffs[i]
            if d < thr { continue }
            // local activity: median of the neighbours (the candidate itself excluded)
            let lo = max(1, i - window), hi = min(diffs.count, i + window + 1)
            let around = (lo..<hi).filter { $0 != i }.map { diffs[$0] }.sorted()
            let med = around.isEmpty ? 0 : around[around.count / 2]
            if d < 2.5 * med + 0.05 { continue }
            // a local maximum (two-frame dissolves report their larger step once)
            if i + 1 < diffs.count, diffs[i + 1] > d { continue }
            if i > 1, diffs[i - 1] > d, cuts.last != i - 1 { continue }
            if i - (cuts.last ?? 0) < max(opt.minShotFrames, 1) { continue }
            cuts.append(i)
        }
        return cuts
    }
}
