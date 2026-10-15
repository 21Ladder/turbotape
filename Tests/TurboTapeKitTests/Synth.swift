import Foundation
@testable import TurboTapeKit

/// Deterministic test signals.
enum Synth {
    /// A drum-like click track: a decaying noise burst on every beat plus a low "kick" on every
    /// downbeat (beat `i` with `i % 4 == 0`). The first beat is at `offset` seconds.
    static func clickTrack(bpm: Double, seconds: Double, sampleRate: Double = 22_050, offset: Double = 0.5) -> (samples: [Float], beats: [Double]) {
        var rng = SplitMix64(seed: 7)
        var x = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var beats = [Double]()
        var t = offset, i = 0
        while t < seconds - 0.2 {
            beats.append(t)
            let start = Int(t * sampleRate)
            let isBar = i % 4 == 0
            for k in 0..<Int(0.12 * sampleRate) where start + k < x.count {
                let env = Float(exp(-Double(k) / (0.015 * sampleRate)))
                let noise = Float(rng.nextUnit() * 2 - 1) * 0.35
                let kick = isBar ? Float(sin(2 * .pi * 55 * Double(k) / sampleRate)) * Float(exp(-Double(k) / (0.06 * sampleRate))) * 0.8 : 0
                x[start + k] += env * noise + kick
            }
            t += 60 / bpm
            i += 1
        }
        return (x, beats)
    }

    /// A stereo sine at `dbfs` peak in both channels.
    static func sine(hz: Double, dbfs: Double, seconds: Double, sampleRate: Double = 48_000) -> [[Float]] {
        let a = Float(pow(10, dbfs / 20))
        let ch = (0..<Int(seconds * sampleRate)).map { a * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
        return [ch, ch]
    }
}
