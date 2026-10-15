import AVFoundation
import Testing
@testable import TurboTapeKit

struct ColorGradeTests {
    @Test func identityCurveIsIdentity() {
        let lut = Curves.monotoneLUT(ColorGrade.identityCurve, 256)
        for (i, v) in lut.enumerated() { #expect(abs(v - Float(i) / 255) < 1e-5) }
        #expect(ColorGrade.identity.isIdentity)
        #expect(ColorGrade.curvesData([.identity, .identity]) == nil)
    }

    @Test func curvePassesThroughItsPointsWithoutOvershoot() {
        let pts = [CurvePoint(0, 0), CurvePoint(0.25, 0.1), CurvePoint(0.5, 0.6), CurvePoint(0.75, 0.62), CurvePoint(1, 1)]
        let n = 1001
        let lut = Curves.monotoneLUT(pts, n)
        for p in pts { #expect(abs(lut[Int((p.x * Float(n - 1)).rounded())] - p.y) < 1e-4) }
        // monotone points → monotone curve (no wiggle above 0.62 between 0.5 and 0.75)
        #expect(zip(lut, lut.dropFirst()).allSatisfy { $1 >= $0 - 1e-6 })
        #expect(lut[500...750].allSatisfy { $0 <= 0.62 + 1e-5 })
    }

    @Test func masterThenColourAndStrength() throws {
        var g = ColorGrade()
        g[.luma] = [CurvePoint(0, 0.2), CurvePoint(1, 1)]   // lift blacks to 0.2
        g[.red] = [CurvePoint(0, 0), CurvePoint(1, 0.5)]    // halve red
        let lut = try #require(ColorGrade.combinedLUT([g], n: 101))
        // black: master lifts to 0.2, red then halves it
        #expect(abs(lut[0][0] - 0.1) < 1e-4 && abs(lut[1][0] - 0.2) < 1e-4 && abs(lut[2][0] - 0.2) < 1e-4)
        // strength 0 removes a curve's effect, 0.5 goes halfway
        g.intensity[CurveChannel.red.rawValue] = 0
        #expect(abs(try #require(ColorGrade.combinedLUT([g], n: 101))[0][0] - 0.2) < 1e-4)
        g.intensity[CurveChannel.luma.rawValue] = 0.5
        #expect(abs(try #require(ColorGrade.combinedLUT([g], n: 101))[0][0] - 0.1) < 1e-4)
    }

    @Test func clipGradeStacksOnTheGradeForAll() throws {
        var all = ColorGrade(), clip = ColorGrade()
        all[.luma] = [CurvePoint(0, 0), CurvePoint(1, 0.5)]   // everything half as bright
        clip[.luma] = [CurvePoint(0, 0), CurvePoint(0.5, 1)]  // this clip: double (clamped)
        let lut = try #require(ColorGrade.combinedLUT([all, clip], n: 101))
        #expect(abs(lut[1][100] - 1) < 1e-4 && abs(lut[1][50] - 0.5) < 1e-3)
        let onlyAll = try #require(ColorGrade.combinedLUT([all, .identity], n: 101))
        #expect(abs(onlyAll[1][100] - 0.5) < 1e-4)
    }

    @Test func gradedExportChangesThePicture() async throws {
        let musicURL = try ExportTests.musicFile(bpm: 120, seconds: 12)
        let (clipURL, _) = try await TestVideo.make(name: "grade", shots: [(2, 4)])
        let info = try await MediaLibrary.loadInfo(clipURL)
        let clip = try await ClipAnalyzer.analyze(info)
        let music = try await MusicAnalyzer.analyze(url: musicURL)
        let (s, e) = music.excerpt(start: music.suggestedStart(length: 3), length: 3)
        let t = try EditPlanner.plan(music: music, musicURL: musicURL, start: s, end: e, clips: [clip], seed: 1)
        let sources = [clipURL: try await SourceTrack.load(clipURL)]
        var flat = ColorGrade()
        flat[.luma] = [CurvePoint(0, 0.2), CurvePoint(1, 0.2)]  // everything mid-dark grey
        func meanLuma(_ curves: [URL: Data]) async throws -> Double {
            let plan = try CompositionBuilder.build(t, sources: sources, music: try await MusicSource.load(musicURL),
                                                    clips: [clipURL: clip], curves: curves)
            let gen = AVAssetImageGenerator(asset: plan.composition)
            gen.videoComposition = plan.videoComposition
            gen.maximumSize = CGSize(width: 90, height: 160)
            let (img, _) = try await gen.image(at: CMTime(value: 15, timescale: 30))
            let frame = try #require(RGBAFrame(img))
            var sum = 0.0
            for i in 0..<frame.width * frame.height { sum += Double(frame.pixels[4 * i]) + Double(frame.pixels[4 * i + 1]) + Double(frame.pixels[4 * i + 2]) }
            return sum / Double(3 * frame.width * frame.height) / 255
        }
        let plain = try await meanLuma([:])
        let graded = try await meanLuma([clipURL: try #require(ColorGrade.curvesData([flat]))])
        #expect(abs(graded - 0.2) < 0.03, "graded mean \(graded)")
        #expect(abs(plain - 0.2) > 0.05, "plain mean \(plain)")
    }
}
