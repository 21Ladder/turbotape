import AVFoundation
import Foundation
import Testing
@testable import TurboTapeKit

struct ClipAnalysisTests {
    @Test func findsKnownCuts() async throws {
        let (url, truth) = try await TestVideo.make(name: "cuts", shots: [(0, 2.0), (1, 1.5), (2, 2.5), (3, 1.0), (0, 2.0)])
        let info = try await MediaLibrary.loadInfo(url)
        #expect(info.width == 320 && info.height == 180)
        #expect(info.needsReframe)
        let a = try await ClipAnalyzer.analyze(info)
        #expect(a.shotStarts.count == truth.count, "found \(a.shotStarts), truth \(truth)")
        let step = 1 / ClipAnalyzer.sampleRate(for: info.duration)
        for (found, cut) in zip(a.shotStarts, truth) {
            #expect(abs(found - cut) <= step, "cut at \(cut) found at \(found)")
        }
        #expect(a.thumbnails.count == (a.sampleTimes.count + 1) / 2)
        #expect(a.scores.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func durationIsThePicturesNotTheAudios() async throws {
        let (url, _) = try await TestVideo.make(name: "longaudio", shots: [(1, 2.0)], audioSeconds: 3.5)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.duration).seconds > 3.4)  // the file is as long as its audio
        let info = try await MediaLibrary.loadInfo(url)
        #expect(abs(info.duration - 2.0) < 0.05, "duration \(info.duration)")
    }

    @Test func cacheRoundTrip() async throws {
        let (url, _) = try await TestVideo.make(name: "cache", shots: [(2, 1.0)])
        let info = try await MediaLibrary.loadInfo(url)
        let cache = AnalysisCache(directory: TestVideo.directory().appendingPathComponent("cache"))
        let a = try await cache.analysis(for: info)
        let b = try #require(cache.load(info))
        #expect(a.sampleTimes == b.sampleTimes && a.scores == b.scores && a.thumbnails == b.thumbnails)
    }

    @Test func folderScanFindsMoviesOnly() throws {
        let dir = TestVideo.directory().appendingPathComponent("scan/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("a.mov"))
        try Data().write(to: dir.appendingPathComponent("b.MP4"))
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        let found = MediaLibrary.movieFiles(in: [dir.deletingLastPathComponent()]).map(\.lastPathComponent)
        #expect(found == ["a.mov", "b.MP4"])
    }

    @Test func detectorIgnoresSmoothMotion() {
        // steady motion, then a jump
        let diffs: [Float] = [0, 0.05, 0.06, 0.05, 0.07, 0.06, 0.6, 0.05, 0.06, 0.05, 0.06]
        #expect(ShotDetector.detectCuts(diffs) == [6])
    }

    @Test func seededPickIsDeterministic() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42)
        let w = [1.0, 0, 3, 2]
        let xs = (0..<50).map { _ in a.pick(weights: w)! }
        #expect(xs == (0..<50).map { _ in b.pick(weights: w)! })
        #expect(!xs.contains(1))
    }
}
