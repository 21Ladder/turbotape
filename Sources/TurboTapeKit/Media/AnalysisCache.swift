import CryptoKit
import Foundation

/// Clip analyses on disk, keyed by path, size, modification date and analysis version, so a
/// changed or replaced file is analysed again.
public struct AnalysisCache: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TurboTape/clips", isDirectory: true)
    }

    func file(for info: ClipInfo) -> URL {
        let key = "\(ClipAnalysis.version)|\(info.url.path)|\(info.fileSize)|\(info.modified.timeIntervalSince1970)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).plist")
    }

    public func load(_ info: ClipInfo) -> ClipAnalysis? {
        guard let data = try? Data(contentsOf: file(for: info)) else { return nil }
        return try? PropertyListDecoder().decode(ClipAnalysis.self, from: data)
    }

    public func store(_ analysis: ClipAnalysis) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(analysis) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: analysis.info), options: .atomic)
    }

    /// Cached analysis, or a fresh one (then cached).
    public func analysis(for info: ClipInfo, progress: (@Sendable (Double) -> Void)? = nil) async throws -> ClipAnalysis {
        if let hit = load(info) { return hit }
        let a = try await ClipAnalyzer.analyze(info, progress: progress)
        store(a)
        return a
    }
}
