import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Samples a clip at a few frames per second and turns each sample into a score, a signature
/// for shot detection, a focus point for reframing and a thumbnail.
public enum ClipAnalyzer {
    /// Samples per second (fewer for long clips, see `sampleRate(for:)`).
    static let samplesPerSecond = 5.0
    static let maxSamples = 1_500.0
    static let analysisSize = 256
    /// Every n-th sample gets a JPEG thumbnail (2.5 per second at 5 fps).
    static let thumbnailStride = 2
    /// Aesthetics are slower to compute and change slowly: every n-th sample, held in between.
    static let aestheticsStride = 5

    static func sampleRate(for duration: Double) -> Double {
        max(1, min(samplesPerSecond, maxSamples / max(duration, 0.1)))
    }

    public static func analyze(_ info: ClipInfo, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ClipAnalysis {
        let asset = AVURLAsset(url: info.url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: analysisSize, height: analysisSize)
        let rate = sampleRate(for: info.duration)
        let tolerance = CMTime(seconds: 0.5 / rate, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        let count = max(1, Int(info.duration * rate))
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) / rate, preferredTimescale: 600) }

        var sampleTimes = [Double](), sharp = [Float](), exposure = [Float](), diffs = [Float]()
        var aesthetics = [Float](), focus = [Float](), thumbs = [Data]()
        var prev: FrameSignature?
        var lastAesthetic: Float = 0.5
        var index = 0
        for await result in gen.images(for: times) {
            try Task.checkCancellation()
            guard case .success(_, let image, let actual) = result else { continue }
            guard let frame = RGBAFrame(image) else { continue }
            let sig = frame.signature()
            diffs.append(prev.map { sig.difference($0) } ?? 0)
            prev = sig
            sampleTimes.append(actual.seconds)
            let (s, e) = frame.sharpnessAndExposure()
            sharp.append(s)
            exposure.append(e)
            if index % aestheticsStride == 0 { lastAesthetic = await aestheticScore(image) }
            aesthetics.append(lastAesthetic)
            focus.append(info.needsReframe ? await focusX(image) : 0.5)
            if index % thumbnailStride == 0, let jpeg = jpegData(image) { thumbs.append(jpeg) }
            index += 1
            progress?(Double(index) / Double(count))
        }
        guard !sampleTimes.isEmpty else { throw TurboTapeError.readFailed(info.url, "no frames could be decoded") }

        let cuts = ShotDetector.detectCuts(diffs)
        let motion = motionScores(diffs, cuts: Set(cuts))
        let scores = sampleTimes.indices.map { i in
            0.35 * sharp[i] + 0.2 * exposure[i] + 0.2 * motion[i] + 0.25 * aesthetics[i]
        }
        return ClipAnalysis(
            info: info,
            sampleTimes: sampleTimes,
            scores: scores,
            // a cut lies between the two samples: start the new shot halfway
            shotStarts: cuts.map { (sampleTimes[$0 - 1] + sampleTimes[$0]) / 2 },
            focusX: focus,
            thumbnails: thumbs,
            thumbnailStride: thumbnailStride
        )
    }

    /// Some motion is good, none is dull and a lot is chaos: peaks around a difference of 0.06
    /// between samples. Differences across a shot cut are not motion.
    static func motionScores(_ diffs: [Float], cuts: Set<Int>) -> [Float] {
        diffs.indices.map { i in
            var d = diffs[i]
            if cuts.contains(i) || i == 0 { d = i + 1 < diffs.count && !cuts.contains(i + 1) ? diffs[i + 1] : 0.06 }
            let x = log((d + 0.005) / 0.065)
            return exp(-0.5 * x * x)
        }
    }

    // MARK: - Vision

    static func aestheticScore(_ image: CGImage) async -> Float {
        guard let obs = try? await CalculateImageAestheticsScoresRequest().perform(on: image) else { return 0.5 }
        let s = (obs.overallScore + 1) / 2
        return obs.isUtility ? s * 0.3 : s
    }

    /// Faces win; otherwise salient objects weighted by area × confidence; otherwise the centre.
    static func focusX(_ image: CGImage) async -> Float {
        if let faces = try? await DetectFaceRectanglesRequest().perform(on: image), !faces.isEmpty {
            return weightedCentre(faces.map { ($0.boundingBox.cgRect, 1) })
        }
        if let sal = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: image), !sal.salientObjects.isEmpty {
            return weightedCentre(sal.salientObjects.map { ($0.boundingBox.cgRect, $0.confidence) })
        }
        return 0.5
    }

    private static func weightedCentre(_ boxes: [(CGRect, Float)]) -> Float {
        var sum: Float = 0, w: Float = 0
        for (r, c) in boxes {
            let a = Float(r.width * r.height) * max(c, 0.05)
            sum += Float(r.midX) * a
            w += a
        }
        return w > 0 ? sum / w : 0.5
    }

    static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// A CGImage redrawn into a tightly packed sRGB RGBA8 buffer.
struct RGBAFrame {
    let width: Int, height: Int
    var pixels: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard width > 0, height > 0 else { return nil }
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
    }

    func signature() -> FrameSignature {
        pixels.withUnsafeBytes { FrameSignature(rgba: $0, width: width, height: height, rowBytes: width * 4) }
    }

    /// Sharpness from the variance of the luma Laplacian (log-mapped to 0…1) and exposure
    /// (1 for a mid-grey average, falling toward black or blown-out frames).
    func sharpnessAndExposure() -> (Float, Float) {
        var luma = [Float](repeating: 0, count: width * height)
        var sum: Float = 0
        for i in 0..<width * height {
            let l = (0.2126 * Float(pixels[4 * i]) + 0.7152 * Float(pixels[4 * i + 1]) + 0.0722 * Float(pixels[4 * i + 2])) / 255
            luma[i] = l
            sum += l
        }
        let mean = sum / Float(luma.count)
        var lsum: Float = 0, lsq: Float = 0, n: Float = 0
        if width > 2, height > 2 {
            for y in 1..<height - 1 {
                for x in 1..<width - 1 {
                    let i = y * width + x
                    let lap = luma[i - 1] + luma[i + 1] + luma[i - width] + luma[i + width] - 4 * luma[i]
                    lsum += lap
                    lsq += lap * lap
                    n += 1
                }
            }
        }
        let variance = n > 0 ? lsq / n - (lsum / n) * (lsum / n) : 0
        let sharp = min(max((log10(variance + 1e-7) + 3.5) / 2, 0), 1)
        let dev = min(abs(mean - 0.45) / 0.4, 1)
        let exposure = mean < 0.06 ? 0 : 1 - dev * dev
        return (sharp, exposure)
    }
}
