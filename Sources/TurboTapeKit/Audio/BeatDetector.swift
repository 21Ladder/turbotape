import Accelerate

/// Beats and onsets of a piece of music.
///
/// ```text
/// mono ─► STFT (≈46 ms Hann, ¼ hop) ─► log-magnitude spectral flux = onset envelope
///      ─► tempo: autocorrelation of the envelope, 50–200 BPM, log-Gaussian prior at 120 BPM
///      ─► beats: dynamic programming (onset strength + penalty on beat-to-beat deviation from
///         the period, squared log ratio), backtracked from the strongest end
/// ```
///
/// Additions for cutting video: a low-band (< 150 Hz, kick drum) envelope to find the downbeat
/// phase, and the envelope's peaks as onsets that cuts can snap to.
public struct BeatTrack: Sendable, Equatable {
    public var bpm: Double
    /// Beat times (seconds) at the attack, increasing.
    public var beats: [Double]
    /// Onset strength at each beat (envelope standard deviations).
    public var beatStrengths: [Float]
    /// Low-band (kick) onset strength at each beat.
    public var beatLowStrengths: [Float]
    /// Strong onsets anywhere (seconds), increasing; includes off-beat hits.
    public var onsets: [Double]
}

public enum BeatDetector {
    /// Below this normalised autocorrelation at the beat period there is no usable pulse.
    static let minPulse = 0.1
    /// Onsets weaker than this (in envelope standard deviations) are not snap targets.
    static let onsetThreshold: Float = 1.5

    /// STFT frame: the power of two nearest to 46 ms (1024 at 22.05 kHz).
    static func onsetFrame(_ sampleRate: Double) -> Int {
        let n = max(sampleRate * 0.046, 256)
        return 1 << Int(log2(n).rounded())
    }

    /// Onset strength per hop: half-wave rectified log-magnitude spectral flux, normalised to unit
    /// standard deviation. `low` is the same restricted to bins below 150 Hz.
    static func onsetEnvelopes(_ x: [Float], sampleRate: Double) -> (full: [Float], low: [Float], n: Int, hop: Int) {
        let n = onsetFrame(sampleRate)
        let hop = n / 4
        let frames = x.count >= n ? (x.count - n) / hop + 1 : 1
        let bins = n / 2 + 1
        let lowBins = max(2, Int(150 * Double(n) / sampleRate))
        let fft = RealFFT(n: n)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        var frame = [Float](repeating: 0, count: n)
        var mag = [Float](repeating: 0, count: bins)
        var prev = [Float](repeating: 0, count: bins)
        var cur = [Float](repeating: 0, count: bins)
        var full = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        x.withUnsafeBufferPointer { xp in
            for t in 0..<frames {
                let s = t * hop
                let avail = max(0, min(n, xp.count - s))
                for i in 0..<n { frame[i] = i < avail ? xp[s + i] * window[i] : 0 }
                fft.magnitudes(frame, into: &mag)
                for k in 0..<bins { cur[k] = log(1 + 1000 * mag[k]) }
                if t > 0 {
                    var f: Float = 0, l: Float = 0
                    for k in 0..<bins {
                        let d = max(cur[k] - prev[k], 0)
                        f += d
                        if k < lowBins { l += d }
                    }
                    full[t] = f
                    low[t] = l
                }
                swap(&prev, &cur)
            }
        }
        return (normalised(full), normalised(low), n, hop)
    }

    private static func normalised(_ env: [Float]) -> [Float] {
        guard !env.isEmpty else { return env }
        let mean = vDSP.mean(env)
        let sd = sqrt(vDSP.meanSquare(env) - mean * mean)
        return sd > 0 ? vDSP.divide(env, sd) : env
    }

    /// Beat period in envelope frames (50–200 BPM, prior centred at 120 BPM).
    static func tempo(_ env: [Float], frameRate: Double) -> Double? {
        let mean = vDSP.mean(env)
        let e = vDSP.add(-mean, env)
        let lo = max(2, Int((frameRate * 60 / 200).rounded(.down)))
        let hi = min(Int((frameRate * 60 / 50).rounded(.up)), e.count / 2)
        guard hi > lo + 2 else { return nil }
        func ac(_ lag: Int) -> Double {
            e.withUnsafeBufferPointer { p in
                let len = e.count - lag
                let d = vDSP.dot(UnsafeBufferPointer(rebasing: p[0..<len]), UnsafeBufferPointer(rebasing: p[lag..<lag + len]))
                return Double(d) / Double(len)
            }
        }
        let raw = (lo - 1...hi + 1).map(ac)
        var best = -Double.greatestFiniteMagnitude, bk = 0
        for k in 1..<raw.count - 1 {
            let bpm = 60 * frameRate / Double(lo - 1 + k)
            let w = raw[k] * exp(-0.5 * pow(log2(bpm / 120), 2))
            if w > best { best = w; bk = k }
        }
        guard best > 0, raw[bk] > minPulse * ac(0) else { return nil }
        // parabolic refinement on the raw autocorrelation
        let (a, b, c) = (raw[bk - 1], raw[bk], raw[bk + 1])
        let den = a - 2 * b + c
        let d = den < 0 ? min(max(0.5 * (a - c) / den, -0.5), 0.5) : 0
        return Double(lo - 1 + bk) + d
    }

    /// Dynamic-programming beat tracker: frame indices of beats.
    static func trackBeats(_ env: [Float], period: Double) -> [Int] {
        let n = env.count
        guard n > 0 else { return [] }
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let tight = 100.0
        let lo = max(1, Int((period * 0.5).rounded()))
        let hi = Int((period * 2).rounded())
        // penalty depends only on the distance: precompute
        let penalty = (0...hi).map { d -> Double in
            guard d > 0 else { return 0 }
            let r = log(Double(d) / period)
            return tight * r * r
        }
        for t in 0..<n {
            var best = 0.0, arg = -1
            if t >= lo {
                for prev in max(0, t - hi)...(t - lo) {
                    let v = score[prev] - penalty[t - prev]
                    if arg < 0 || v > best { best = v; arg = prev }
                }
            }
            score[t] = Double(env[t]) + (arg < 0 ? 0 : max(best, 0))
            back[t] = arg >= 0 && best > 0 ? arg : -1
        }
        // strongest end within the last period (latest on ties)
        let tail = max(0, n - Int(period.rounded(.up)) - 1)
        var t = tail
        for i in tail..<n where score[i] >= score[t] { t = i }
        var beats = [t]
        while back[t] >= 0 { t = back[t]; beats.append(t) }
        return beats.reversed()
    }

    private static func localMax(_ env: [Float], _ t: Int, _ r: Int) -> Float {
        env[max(0, t - r)..<min(env.count, t + r + 1)].max() ?? 0
    }

    /// Analyse mono audio.
    public static func detect(mono x: [Float], sampleRate: Double) throws -> BeatTrack {
        let (env, low, n, hop) = onsetEnvelopes(x, sampleRate: sampleRate)
        let frameRate = sampleRate / Double(hop)
        guard let period = tempo(env, frameRate: frameRate) else { throw TurboTapeError.noBeat }
        var frames = trackBeats(env, period: period)
        // weak beats at the edges (silence before / after the music) are not beats
        let sorted = frames.map { localMax(env, $0, 2) }.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        while let f = frames.first, localMax(env, f, 2) < 0.3 * median { frames.removeFirst() }
        while let f = frames.last, localMax(env, f, 2) < 0.3 * median { frames.removeLast() }
        // …and edge beats off the grid (the end search can settle on an off-beat)
        func offGrid(_ a: Int, _ b: Int) -> Bool { abs(Double(b - a) / period - 1) > 0.05 }
        while frames.count > 2, offGrid(frames[frames.count - 2], frames[frames.count - 1]) { frames.removeLast() }
        while frames.count > 2, offGrid(frames[0], frames[1]) { frames.removeFirst() }
        guard frames.count >= 4 else { throw TurboTapeError.noBeat }

        // The flux of frame t peaks as soon as an attack enters the newer window, at about
        func seconds(_ t: Int) -> Double { Double(t * hop + n - 3 * hop / 4) / sampleRate }

        var onsets = [Double]()
        if env.count > 6 {
            for t in 3..<env.count - 3 where env[t] >= onsetThreshold && env[t] == localMax(env, t, 3) {
                onsets.append(seconds(t))
            }
        }
        return BeatTrack(
            bpm: 60 * frameRate / period,
            beats: frames.map(seconds),
            beatStrengths: frames.map { localMax(env, $0, 2) },
            beatLowStrengths: frames.map { localMax(low, $0, 2) },
            onsets: onsets
        )
    }
}

/// Forward real FFT magnitudes (unnormalised, like a textbook DFT).
final class RealFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var re: [Float]
    private var im: [Float]

    init(n: Int) {
        precondition(n >= 4 && n & (n - 1) == 0, "FFT size must be a power of two")
        self.n = n
        log2n = vDSP_Length(log2(Double(n)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        re = [Float](repeating: 0, count: n / 2)
        im = [Float](repeating: 0, count: n / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `out` gets `n/2 + 1` bins.
    func magnitudes(_ input: [Float], into out: inout [Float]) {
        let half = n / 2
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // zrip output is 2× the DFT; DC and Nyquist are packed into bin 0
                out[0] = abs(rp[0]) * 0.5
                out[half] = abs(ip[0]) * 0.5
                for k in 1..<half {
                    out[k] = 0.5 * (rp[k] * rp[k] + ip[k] * ip[k]).squareRoot()
                }
            }
        }
    }
}
