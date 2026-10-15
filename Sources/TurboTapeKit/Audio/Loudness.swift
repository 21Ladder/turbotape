import Accelerate

/// ITU-R BS.1770-4 integrated loudness and sample peak.
///
/// The K-weighting stages are derived from their analog prototypes through the bilinear transform, 
/// so any sample rate works; at 48 kHz they reproduce the coefficient table in the recommendation.
public enum Loudness {
    /// Loudness of a mean-square energy (already channel-weighted), in LUFS.
    static func lufs(_ energy: Double) -> Double {
        energy <= 0 ? -.infinity : -0.691 + 10 * log10(energy)
    }

    /// Biquad coefficients `[b0, b1, b2, a1, a2]` of the two K-weighting stages.
    static func kWeighting(_ sampleRate: Double) -> [Double] {
        // stage 1: high-shelf "head" pre-filter
        var k = tan(.pi * 1_681.974_450_955_533 / sampleRate)
        let q1 = 0.707_175_236_955_419_6
        let vh = pow(10, 3.999_843_853_973_347 / 20)
        let vb = pow(vh, 0.499_666_774_154_541_6)
        var a0 = 1 + k / q1 + k * k
        let shelf = [(vh + vb * k / q1 + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q1 + k * k) / a0,
                     2 * (k * k - 1) / a0, (1 - k / q1 + k * k) / a0]
        // stage 2: RLB high-pass
        k = tan(.pi * 38.135_470_876_024_44 / sampleRate)
        let q2 = 0.500_327_037_323_877_3
        a0 = 1 + k / q2 + k * k
        let rlb = [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q2 + k * k) / a0]
        return shelf + rlb
    }

    /// Integrated loudness (LUFS) of planar stereo or mono audio; `-inf` for silence.
    public static func integrated(_ channels: [[Float]], sampleRate: Double) -> Double {
        let sub = Int(sampleRate * 0.1)  // 100 ms sub-blocks; 400 ms gating blocks overlap by 75 %
        guard let len = channels.first?.count, sub > 0, len >= 4 * sub else { return -.infinity }
        let subCount = len / sub
        var subEnergy = [Double](repeating: 0, count: subCount)
        let coeffs = kWeighting(sampleRate)
        for ch in channels {
            guard let setup = vDSP_biquad_CreateSetup(coeffs, 2) else { continue }
            defer { vDSP_biquad_DestroySetup(setup) }
            var delay = [Float](repeating: 0, count: 2 * 2 + 2)
            var y = [Float](repeating: 0, count: len)
            vDSP_biquad(setup, &delay, ch, 1, &y, 1, vDSP_Length(len))
            y.withUnsafeBufferPointer { p in
                for s in 0..<subCount {
                    var sq: Float = 0
                    vDSP_svesq(p.baseAddress! + s * sub, 1, &sq, vDSP_Length(sub))
                    subEnergy[s] += Double(sq)  // channel weight 1.0 for L/R/mono
                }
            }
        }
        var blocks = [Double]()
        for j in 0...(subCount - 4) {
            blocks.append((subEnergy[j] + subEnergy[j + 1] + subEnergy[j + 2] + subEnergy[j + 3]) / Double(4 * sub))
        }
        let absGated = blocks.filter { lufs($0) > -70 }
        guard !absGated.isEmpty else { return -.infinity }
        let relGate = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let gated = absGated.filter { lufs($0) > relGate }
        return lufs(gated.reduce(0, +) / Double(max(gated.count, 1)))
    }

    /// Largest absolute sample value.
    public static func samplePeak(_ channels: [[Float]]) -> Float {
        channels.map { vDSP.maximumMagnitude($0) }.max() ?? 0
    }

    /// Linear gain moving `lufs` toward `target` without pushing `peak` above `ceilingDB` dBFS.
    public static func normalizationGain(lufs: Double, peak: Float, target: Double = -14, ceilingDB: Double = -1) -> Float {
        guard lufs.isFinite, peak > 0 else { return 1 }
        let wanted = pow(10, (target - lufs) / 20)
        let maxGain = pow(10, ceilingDB / 20) / Double(peak)
        return Float(min(wanted, maxGain))
    }
}
