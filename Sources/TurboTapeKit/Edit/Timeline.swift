import Foundation

/// One shot of the output: `frameCount` output frames read from `clip` starting at `sourceStart`.
public struct Segment: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var clip: URL
    /// Source time (seconds) of the segment's first frame.
    public var sourceStart: Double
    /// First output frame.
    public var startFrame: Int
    public var frameCount: Int
    /// Edited by hand: Shuffle keeps it.
    public var pinned: Bool

    public var endFrame: Int { startFrame + frameCount }

    public init(id: Int, clip: URL, sourceStart: Double, startFrame: Int, frameCount: Int, pinned: Bool = false) {
        self.id = id
        self.clip = clip
        self.sourceStart = sourceStart
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.pinned = pinned
    }
}

/// The edit: contiguous segments over an excerpt of the music, on an integer output-frame grid so
/// durations always add up exactly and cuts never drift against the beat.
public struct Timeline: Codable, Sendable, Equatable {
    public var fps: Int
    public var music: URL
    /// Song time (seconds) at output frame 0.
    public var musicStart: Double
    public var frameCount: Int
    public var segments: [Segment]
    public var seed: UInt64

    public var duration: Double { Double(frameCount) / Double(fps) }

    public func seconds(_ frame: Int) -> Double { Double(frame) / Double(fps) }
    public func frame(_ seconds: Double) -> Int { Int((seconds * Double(fps)).rounded()) }
    /// Output frame of a song time.
    public func frame(songTime t: Double) -> Int { frame(t - musicStart) }

    /// Output frames where one segment ends and the next starts.
    public var cutFrames: [Int] { segments.dropFirst().map(\.startFrame) }

    public func segmentIndex(at frame: Int) -> Int? {
        segments.firstIndex { frame >= $0.startFrame && frame < $0.endFrame }
    }

    /// Contiguous, in order, covering `[0, frameCount)` with no empty segment.
    public var isValid: Bool {
        var f = 0
        for s in segments {
            guard s.startFrame == f, s.frameCount > 0, s.sourceStart >= -1e-9 else { return false }
            f = s.endFrame
        }
        return f == frameCount
    }
}
