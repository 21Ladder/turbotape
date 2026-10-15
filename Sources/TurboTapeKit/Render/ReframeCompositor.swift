import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// What the compositor needs for one segment.
final class ReframeInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    /// The source clip (to swap its colour curves without rebuilding, see `RenderPlan.videoComposition(curves:)`).
    let clip: URL
    /// Output time → source time: `source = sourceStart + (t - timeRange.start)`.
    let sourceStart: Double
    let orientation: CGImagePropertyOrientation
    let isHDR: Bool
    /// Focus keyframes: source time → horizontal centre 0…1 (display orientation).
    let focusTimes: [Double]
    let focusValues: [Float]
    /// Colour curves as `CIColorCurves` data (RGB float triples), nil for none.
    let curves: Data?

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, clip: URL, sourceStart: Double, orientation: CGImagePropertyOrientation,
         isHDR: Bool, focusTimes: [Double], focusValues: [Float], curves: Data? = nil) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.clip = clip
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.sourceStart = sourceStart
        self.orientation = orientation
        self.isHDR = isHDR
        self.focusTimes = focusTimes
        self.focusValues = focusValues
        self.curves = curves
    }

    /// The same instruction with other colour curves.
    func with(curves: Data?) -> ReframeInstruction {
        ReframeInstruction(timeRange: timeRange, trackID: trackID, clip: clip, sourceStart: sourceStart, orientation: orientation,
                           isHDR: isHDR, focusTimes: focusTimes, focusValues: focusValues, curves: curves)
    }

    func focus(at output: CMTime) -> CGFloat {
        guard !focusTimes.isEmpty else { return 0.5 }
        let t = sourceStart + (output - timeRange.start).seconds
        guard let j = focusTimes.lastIndex(where: { $0 <= t }) else { return CGFloat(focusValues[0]) }
        guard j + 1 < focusTimes.count else { return CGFloat(focusValues[j]) }
        let f = (t - focusTimes[j]) / (focusTimes[j + 1] - focusTimes[j])
        return CGFloat(focusValues[j] + (focusValues[j + 1] - focusValues[j]) * Float(min(max(f, 0), 1)))
    }
}

/// Fills the vertical frame from any source: orient, crop a full-height 9:16 window that follows
/// the focus (or a centred one for tall sources), scale with Lanczos, tone-map HDR to Rec.709.
final class ReframeCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "TurboTape"]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()
    private static let outputSpace = CGColorSpace(name: CGColorSpace.itur_709)!

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
    ]
    var supportsWideColorSourceFrames: Bool { true }
    var supportsHDRSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let ins = request.videoCompositionInstruction as? ReframeInstruction,
              let out = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: NSError(domain: "TurboTape", code: 1, userInfo: [NSLocalizedDescriptionKey: "no render buffer"]))
            return
        }
        let size = request.renderContext.size
        // a missing source frame (e.g. a file whose last frame is short) becomes black, not a failed export
        let image = request.sourceFrame(byTrackID: ins.trackID).map {
            Self.graded(Self.frame(CIImage(cvPixelBuffer: $0), orientation: ins.orientation, isHDR: ins.isHDR,
                                   focus: ins.focus(at: request.compositionTime), into: size), curves: ins.curves)
        } ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        Self.context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.outputSpace)
        request.finish(withComposedVideoFrame: out)
    }

    func cancelAllPendingVideoCompositionRequests() {}

    /// The colour curves applied to the display-encoded (Rec.709) picture.
    static func graded(_ image: CIImage, curves: Data?) -> CIImage {
        guard let curves, curves.count >= 2 * 3 * MemoryLayout<Float>.size else { return image }
        let f = CIFilter.colorCurves()
        f.inputImage = image
        f.curvesData = curves
        f.curvesDomain = CIVector(x: 0, y: 1)
        f.colorSpace = outputSpace
        return f.outputImage ?? image
    }

    /// The source image cropped and scaled to exactly `size`.
    static func frame(_ source: CIImage, orientation: CGImagePropertyOrientation, isHDR: Bool, focus: CGFloat, into size: CGSize) -> CIImage {
        var img = source.oriented(orientation)
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        if isHDR {
            let tm = CIFilter.toneMapHeadroom()
            tm.inputImage = img
            tm.targetHeadroom = 1
            img = tm.outputImage ?? img
        }
        let w = img.extent.width, h = img.extent.height
        let targetAspect = size.width / size.height
        var crop: CGRect
        if w / h > targetAspect {
            // wider than the output: full height, window follows the focus
            let cw = h * targetAspect
            let x = min(max(focus * w - cw / 2, 0), w - cw)
            crop = CGRect(x: x, y: 0, width: cw, height: h)
        } else {
            // taller: full width, centred vertically
            let ch = w / targetAspect
            crop = CGRect(x: 0, y: (h - ch) / 2, width: w, height: ch)
        }
        crop = crop.integral.intersection(img.extent)
        img = img.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scale = size.height / crop.height
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = img.clampedToExtent()
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = Float((size.width / crop.width) / scale)
        return (lanczos.outputImage ?? img).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// The EXIF-style orientation that a track's `preferredTransform` encodes.
    static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        case (-1, 0, 0, 1): .upMirrored
        case (1, 0, 0, -1): .downMirrored
        case (0, 1, 1, 0): .leftMirrored
        case (0, -1, -1, 0): .rightMirrored
        default: .up
        }
    }
}
