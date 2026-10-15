/// SplitMix64: tiny, fast and stable across platforms and Swift versions, so the same seed always
/// gives the same edit (unlike `SystemRandomNumberGenerator`).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`.
    public mutating func nextUnit() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    /// Index chosen with probability proportional to `weights` (non-positive weights are never
    /// chosen); nil when all are non-positive.
    public mutating func pick(weights: [Double]) -> Int? {
        let total = weights.reduce(0) { $0 + max($1, 0) }
        guard total > 0 else { return nil }
        var r = nextUnit() * total
        for (i, w) in weights.enumerated() where w > 0 {
            r -= w
            if r < 0 { return i }
        }
        return weights.lastIndex { $0 > 0 }
    }
}
