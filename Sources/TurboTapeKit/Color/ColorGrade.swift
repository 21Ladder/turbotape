import CoreGraphics
import Foundation

/// A control point of a tone curve: input `x` → output `y`, both 0…1 (display-encoded values).
public struct CurvePoint: Codable, Sendable, Hashable {
    public var x: Float
    public var y: Float
    public init(_ x: Float, _ y: Float) {
        self.x = x
        self.y = y
    }
}

/// Which curve: the master (luma) curve acts on all three channels, the others on one each.
public enum CurveChannel: Int, CaseIterable, Codable, Sendable, Identifiable {
    case luma, red, green, blue
    public var id: Int { rawValue }
    public var title: String { ["Y", "R", "G", "B"][rawValue] }
}

/// RGB curves for a clip (or for all clips): monotone cubic curves through the control points, applied to the
/// display-encoded picture — first the master curve to every channel, then each colour's own.
/// Each curve has a strength (0 = no effect, 1 = full), like Resolve's per-channel sliders.
public struct ColorGrade: Codable, Sendable, Equatable {
    /// Indexed by `CurveChannel.rawValue`; each sorted by x, at least two points.
    public var curves: [[CurvePoint]]
    /// Strength per channel, 0…1.
    public var intensity: [Float]

    public static let identityCurve = [CurvePoint(0, 0), CurvePoint(1, 1)]
    public static let identity = ColorGrade()

    public init() {
        curves = Array(repeating: Self.identityCurve, count: CurveChannel.allCases.count)
        intensity = Array(repeating: 1, count: CurveChannel.allCases.count)
    }

    public subscript(_ c: CurveChannel) -> [CurvePoint] {
        get { curves[c.rawValue] }
        set { curves[c.rawValue] = newValue.sorted { $0.x < $1.x } }
    }

    public func isIdentity(_ c: CurveChannel) -> Bool {
        intensity[c.rawValue] == 0 || curves[c.rawValue].allSatisfy { abs($0.x - $0.y) < 1e-6 }
    }

    public var isIdentity: Bool { CurveChannel.allCases.allSatisfy(isIdentity) }

    /// Output channel `rgb` (0, 1, 2) for input `x`: master curve, then the colour's own curve,
    /// each blended with the input by its strength.
    func apply(_ x: Float, channel rgb: Int, luts: [[Float]]) -> Float {
        func sample(_ lut: [Float], _ v: Float) -> Float {
            let p = min(max(v, 0), 1) * Float(lut.count - 1)
            let i = Int(p), j = min(i + 1, lut.count - 1)
            return lut[i] + (lut[j] - lut[i]) * (p - Float(i))
        }
        var v = x
        let y = intensity[0]
        if y > 0 { v += (sample(luts[0], v) - v) * y }
        let c = intensity[rgb + 1]
        if c > 0 { v += (sample(luts[rgb + 1], v) - v) * c }
        return v
    }

    /// The curves' lookup tables, one per `CurveChannel`.
    func luts(_ n: Int) -> [[Float]] { curves.map { Curves.monotoneLUT($0, n) } }

    /// One lookup table per output channel (R, G, B) for `grades` applied in order (e.g. the
    /// grade for all clips, then the clip's own), or nil when they change nothing.
    public static func combinedLUT(_ grades: [ColorGrade], n: Int = 1024) -> [[Float]]? {
        let active = grades.filter { !$0.isIdentity }
        guard !active.isEmpty else { return nil }
        let tables = active.map { $0.luts(n) }
        return (0..<3).map { rgb in
            (0..<n).map { i in
                var v = Float(i) / Float(n - 1)
                for (g, t) in zip(active, tables) { v = g.apply(v, channel: rgb, luts: t) }
                return min(max(v, 0), 1)
            }
        }
    }

    /// `combinedLUT` packed as Core Image's `CIColorCurves` wants it: RGB float triples.
    public static func curvesData(_ grades: [ColorGrade], n: Int = 1024) -> Data? {
        guard let lut = combinedLUT(grades, n: n) else { return nil }
        var floats = [Float]()
        floats.reserveCapacity(3 * n)
        for i in 0..<n { floats += [lut[0][i], lut[1][i], lut[2][i]] }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

public enum Curves {
    /// Monotone cubic (Fritsch–Carlson) interpolation through the control points, as a lookup
    /// table of `n` entries over x ∈ [0, 1]. Monotone curves
    /// never overshoot between points, which keeps tone curves well-behaved.
    public static func monotoneLUT(_ points: [CurvePoint], _ n: Int) -> [Float] {
        var pts = points.sorted { $0.x < $1.x }
        // drop points at the same x (keep the first)
        pts = pts.enumerated().filter { i, p in i == 0 || abs(p.x - pts[i - 1].x) >= 1e-6 }.map(\.element)
        guard pts.count >= 2 else {
            if let p = pts.first { return Array(repeating: p.y, count: n) }
            return (0..<n).map { Float($0) / Float(n - 1) }
        }
        let m = pts.count
        let d = (0..<m - 1).map { (pts[$0 + 1].y - pts[$0].y) / max(pts[$0 + 1].x - pts[$0].x, 1e-6) }
        var t = [Float](repeating: 0, count: m)
        t[0] = d[0]
        t[m - 1] = d[m - 2]
        for i in 1..<m - 1 { t[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<m - 1 {
            if abs(d[i]) < 1e-9 {
                t[i] = 0
                t[i + 1] = 0
                continue
            }
            let a = t[i] / d[i], b = t[i + 1] / d[i]
            let h = a * a + b * b
            if h > 9 {
                let k = 3 / h.squareRoot()
                t[i] = k * a * d[i]
                t[i + 1] = k * b * d[i]
            }
        }
        var out = [Float]()
        out.reserveCapacity(n)
        var i = 0
        for j in 0..<n {
            let x = Float(j) / Float(n - 1)
            if x <= pts[0].x { out.append(pts[0].y); continue }
            if x >= pts[m - 1].x { out.append(pts[m - 1].y); continue }
            while pts[i + 1].x <= x { i += 1 }
            let hh = pts[i + 1].x - pts[i].x
            let u = (x - pts[i].x) / hh
            let u2 = u * u, u3 = u2 * u
            let h00 = 2 * u3 - 3 * u2 + 1, h10 = u3 - 2 * u2 + u, h01 = -2 * u3 + 3 * u2, h11 = u3 - u2
            out.append(h00 * pts[i].y + h10 * hh * t[i] + h01 * pts[i + 1].y + h11 * hh * t[i + 1])
        }
        return out
    }
}

/// Luma and RGB histograms of a set of images, for drawing behind the curve editor.
public struct Histogram: Sendable, Equatable {
    public static let bins = 64
    /// Indexed like `CurveChannel`: luma, red, green, blue; each normalised so the tallest bin of
    /// all four is 1.
    public var values: [[Float]]

    public static func compute(_ images: [CGImage]) -> Histogram? {
        guard !images.isEmpty else { return nil }
        var h = Array(repeating: [Float](repeating: 0, count: bins), count: 4)
        let w = 96, hh = 54
        var px = [UInt8](repeating: 0, count: w * hh * 4)
        for image in images {
            let ok = px.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: hh, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: hh))
                return true
            }
            guard ok else { continue }
            for i in 0..<w * hh {
                let r = Int(px[4 * i]), g = Int(px[4 * i + 1]), b = Int(px[4 * i + 2])
                let l = (2126 * r + 7152 * g + 722 * b) / 10_000
                h[0][l * bins / 256] += 1
                h[1][r * bins / 256] += 1
                h[2][g * bins / 256] += 1
                h[3][b * bins / 256] += 1
            }
        }
        // ignore the pure black / white bins when scaling (letterboxes, clipped skies)
        let peak = h.map { $0[1..<bins - 1].max() ?? 0 }.max() ?? 0
        guard peak > 0 else { return nil }
        return Histogram(values: h.map { $0.map { min($0 / peak, 1) } })
    }
}
