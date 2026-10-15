import AVFoundation
import VideoToolbox

/// Delivery format.
public struct ExportPreset: Sendable, Equatable {
    public var name: String
    public var width: Int
    public var height: Int
    public var videoBitrate: Int
    public var keyframeSeconds: Double
    public var audioSampleRate: Double
    public var audioBitrate: Int
    /// Integrated loudness to aim for, LUFS, and the sample-peak ceiling, dBFS.
    public var targetLUFS: Double
    public var peakCeiling: Double
    public var maxDuration: Double

    public static let shortsReels = ExportPreset(
        name: "Shorts / Reels 1080×1920", width: 1080, height: 1920, videoBitrate: 12_000_000, keyframeSeconds: 2,
        audioSampleRate: 48_000, audioBitrate: 256_000, targetLUFS: -14, peakCeiling: -1, maxDuration: 180)

    public var renderSize: CGSize { CGSize(width: width, height: height) }

    func videoSettings(fps: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoMaxKeyFrameIntervalKey: Int(Double(fps) * keyframeSeconds),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: true,
            ],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
        ]
    }

    var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: audioBitrate,
        ]
    }

    var pcmSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}
