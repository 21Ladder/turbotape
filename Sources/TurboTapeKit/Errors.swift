import Foundation

public enum TurboTapeError: Error, LocalizedError, Sendable {
    case noAudioTrack(URL)
    case noVideoTrack(URL)
    case readFailed(URL, String)
    case noBeat
    case musicTooShort
    case noUsableClips
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack(let u): "\(u.lastPathComponent) has no audio track."
        case .noVideoTrack(let u): "\(u.lastPathComponent) has no video track."
        case .readFailed(let u, let why): "Could not read \(u.lastPathComponent): \(why)"
        case .noBeat: "No beat found in the music (silence, noise or speech?)."
        case .musicTooShort: "The music is too short."
        case .noUsableClips: "None of the videos can be used."
        case .exportFailed(let why): "Export failed: \(why)"
        }
    }
}
