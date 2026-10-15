import AVFoundation
import UniformTypeIdentifiers

/// What we know about a source video without decoding it.
public struct ClipInfo: Codable, Sendable, Hashable {
    public var url: URL
    /// Length of the video track (seconds).
    public var duration: Double
    /// Size as displayed (after the rotation in `preferredTransform`).
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var isHDR: Bool
    public var fileSize: Int64
    public var modified: Date

    public var aspect: Double { Double(width) / Double(max(height, 1)) }
    /// Wider than 9:16: needs a horizontal crop to fill a vertical frame.
    public var needsReframe: Bool { aspect > 9.0 / 16.0 + 0.01 }
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

public enum MediaLibrary {
    /// Movie files among `urls`; folders are searched recursively. Sorted by path, no duplicates.
    public static func movieFiles(in urls: [URL]) -> [URL] {
        var out = Set<URL>()
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey, .isRegularFileKey],
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL {
                    if isMovie(f) { out.insert(f.standardizedFileURL) }
                }
            } else if isMovie(url) {
                out.insert(url.standardizedFileURL)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func isMovie(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .movie) == true
    }

    public static func loadInfo(_ url: URL) async throws -> ClipInfo {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable) else { throw TurboTapeError.readFailed(url, "not readable (protected or damaged)") }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw TurboTapeError.noVideoTrack(url) }
        let (size, transform, fps, traits, range) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate,
                                                                          .mediaCharacteristics, .timeRange)
        // the picture's length, not the file's: audio often runs a little longer than the video,
        // and a segment reaching past the last video frame has nothing to show
        let duration = min(range.end.seconds, try await asset.load(.duration).seconds)
        guard duration.isFinite, duration > 0.2 else { throw TurboTapeError.readFailed(url, "too short") }
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return ClipInfo(
            url: url,
            duration: duration,
            width: Int(abs(shown.width).rounded()),
            height: Int(abs(shown.height).rounded()),
            frameRate: fps > 0 ? Double(fps) : 30,
            isHDR: traits.contains(.containsHDRVideo),
            fileSize: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attrs[.modificationDate] as? Date ?? .distantPast
        )
    }
}
