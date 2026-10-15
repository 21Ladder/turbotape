import Testing
@testable import TurboTapeKit

struct ReframePathTests {
    static let times = (0..<100).map { Double($0) * 0.2 + 0.1 }  // 5 samples/s over 20 s

    /// Largest speed (source widths per second) between consecutive keyframes.
    static func peakSpeed(_ p: (times: [Double], values: [Float])) -> Float {
        zip(zip(p.times, p.values), zip(p.times, p.values).dropFirst())
            .map { abs($1.1 - $0.1) / Float($1.0 - $0.0) }.max() ?? 0
    }

    @Test func flickeringSubjectHoldsStill() {
        // detection flips between two objects every sample: no real move
        let raw = Self.times.indices.map { $0 % 2 == 0 ? Float(0.3) : 0.7 }
        let p = ReframePath.keyframes(times: Self.times, raw: raw, start: 4, duration: 2)
        #expect(Set(p.values).count == 1)
    }

    @Test func briefFlipIsIgnored() {
        var raw = [Float](repeating: 0.4, count: Self.times.count)
        for i in 22...24 { raw[i] = 0.9 }  // 0.6 s glance at something else
        let p = ReframePath.keyframes(times: Self.times, raw: raw, start: 4, duration: 2)
        #expect(p.values.allSatisfy { abs($0 - 0.4) < 1e-6 })
    }

    @Test func smallMoveInsideDeadZoneHolds() {
        let raw = Self.times.map { Float(0.5 + 0.02 * $0 / 20) }
        let p = ReframePath.keyframes(times: Self.times, raw: raw, start: 2, duration: 3)
        #expect(Set(p.values).count == 1)
    }

    @Test func realMoveDriftsSlowlyAndSmoothly() {
        // subject walks from left to right fast: 0.2 → 0.8 within 3 s
        let raw = Self.times.map { Float(min(max(0.2 + ($0 - 5) * 0.2, 0.2), 0.8)) }
        let p = ReframePath.keyframes(times: Self.times, raw: raw, start: 5, duration: 3)
        // moves the right way, never back (no searching), starts and ends at rest
        #expect(p.values.last! > p.values.first!)
        #expect(zip(p.values, p.values.dropFirst()).allSatisfy { $1 >= $0 })
        #expect(abs(p.values[1] - p.values[0]) < abs(p.values[p.values.count / 2] - p.values[p.values.count / 2 - 1]))
        // capped: at most maxSpeed on average, 1.5× at the peak of the ease
        #expect(p.values.last! - p.values.first! <= ReframePath.maxSpeed * 3 + 1e-5)
        #expect(Self.peakSpeed(p) <= ReframePath.maxSpeed * 1.5 + 0.01)
        #expect(p.times.first == 5 && abs(p.times.last! - 8) < 1e-9)
    }

    @Test func shotBetweenSamplesUsesNearest() {
        let p = ReframePath.keyframes(times: [0.1, 5.1], raw: [0.2, 0.8], start: 4.9, duration: 0.1)
        #expect(p.values == [0.8, 0.8])
    }

    @Test func noSamplesIsCentred() {
        let p = ReframePath.keyframes(times: [], raw: [], start: 1, duration: 1)
        #expect(p.values == [0.5, 0.5])
    }
}
