import AVFoundation
import CoreVideo
@testable import TurboTapeKit

/// Writes small synthetic H.264 videos: a sequence of visually distinct "shots", each a moving
/// pattern, so shot detection and the render pipeline can be tested against known truth.
enum TestVideo {
    static func directory() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("turbotape-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// `shots` lists (pattern, seconds). Returns the file URL and the true cut times.
    /// With `audioSeconds`, a silent PCM audio track of that length is added (it may outlast the picture).
    static func make(name: String, shots: [(Int, Double)], width: Int = 320, height: Int = 180, fps: Int32 = 30,
                     audioSeconds: Double? = nil) async throws -> (URL, [Double]) {
        let url = directory().appendingPathComponent("\(name).mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        let audio = audioSeconds.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        }
        if let audio {
            audio.expectsMediaDataInRealTime = false
            writer.add(audio)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        // audio first and in one piece: the writer interleaves, so it would stall the video waiting for it
        if let audio, let seconds = audioSeconds {
            let frames = Int(seconds * 48_000)
            var fmt: CMAudioFormatDescription?
            var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                   mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                                   mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 2, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: frames * 2,
                                               flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 2)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!,
                                                                 sampleCount: frames, presentationTimeStamp: .zero,
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            while !audio.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            audio.append(sample!)
            audio.markAsFinished()
        }
        var frame: Int64 = 0
        var cuts = [Double]()
        for (k, (pattern, seconds)) in shots.enumerated() {
            if k > 0 { cuts.append(Double(frame) / Double(fps)) }
            for _ in 0..<Int(seconds * Double(fps)) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                guard let pool = adaptor.pixelBufferPool else { throw TurboTapeError.exportFailed("no pool") }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                guard let pb else { throw TurboTapeError.exportFailed("no buffer") }
                draw(pb, pattern: pattern, t: Int(frame))
                adaptor.append(pb, withPresentationTime: CMTime(value: frame, timescale: fps))
                frame += 1
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? TurboTapeError.exportFailed("writer") }
        return (url, cuts)
    }

    private static func draw(_ pb: CVPixelBuffer, pattern: Int, t: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let xx = Double(x + 2 * t)
                let (r, g, b): (Double, Double, Double) = switch pattern % 4 {
                case 0: (40 + 150 * abs(sin(xx * 0.05)), 90, 160)
                case 1: (200, 180 - Double(y) * 0.5, 40 + abs(cos(xx * 0.1)) * 60)
                case 2: ((Int(xx) / 8 + y / 8) % 2 == 0 ? 230 : 20, 120, 60)
                default: (30, 30 + min(Double(y) * 1.5, 200), 30 + abs(sin(xx * 0.03)) * 200)
                }
                let i = y * rb + x * 4
                p[i] = UInt8(b); p[i + 1] = UInt8(g); p[i + 2] = UInt8(r); p[i + 3] = 255
            }
        }
    }
}
