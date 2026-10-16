import AVFoundation
import AppKit
import Observation
import SwiftUI
import TurboTapeKit

enum LoadState: Equatable {
    case working(Double)
    case ready
    case failed(String)
}

struct ClipItem: Identifiable {
    let url: URL
    var id: URL { url }
    var info: ClipInfo?
    var analysis: ClipAnalysis?
    var state: LoadState = .working(0)
    var included = true
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor @Observable
final class AppModel {
    // MARK: Music
    var musicURL: URL?
    var music: MusicAnalysis?
    var musicState: LoadState?
    var length: Double = 30
    var musicStart: Double = 0
    private var startIsManual = false

    // MARK: Clips
    var clips: [ClipItem] = []
    @ObservationIgnored private(set) var thumbnails: [URL: [NSImage]] = [:]

    // MARK: Beats
    var beatMode: BeatMode = .detected
    /// The beats the video is cut on (editable); nil until the music is analysed.
    var beats: BeatGrid?
    /// The beats the current timeline was cut on.
    var beatsUsed: BeatGrid?
    var selectedBeat: Int?
    /// A shot being dragged to another position (for drawing the drop marker).
    struct ShotDrag: Equatable { var from: Int; var to: Int }
    var shotDrag: ShotDrag?
    /// The shot a video from the library is being dragged onto.
    var dropTarget: Int?
    /// How well the steady grid matches the tracked beats (nil in Detected mode).
    var steadyFit: Double? {
        guard beatMode == .steady, let music, let beats else { return nil }
        return beats.agreement(with: music.beats)
    }
    /// The beats were edited since the video was last cut: Generate re-cuts on them.
    var beatsChanged: Bool { timeline != nil && beats != nil && beats != beatsUsed }

    // MARK: Colour
    enum GradeScope: String, CaseIterable, Identifiable {
        case all, single
        var id: String { rawValue }
        var title: String { self == .all ? "All clips" : "Single clip" }
    }
    var gradeScope: GradeScope = .all
    /// Curves for every clip.
    var gradeAll = ColorGrade.identity
    /// A clip's own curves, applied on top of `gradeAll`.
    var clipGrades: [URL: ColorGrade] = [:]
    /// The clip edited in Single mode (follows the selected shot).
    var gradeClip: URL?
    var gradeChannel: CurveChannel = .luma
    /// Edit R, G and B together.
    var linkRGB = false
    @ObservationIgnored private var histograms: [String: Histogram] = [:]

    // MARK: Edit
    var pace: Pace = .normal
    var timeline: Timeline?
    var grid: SnapGrid?
    var selectedSegment: Int?
    var selectedCut: Int?  // index of the segment after the cut
    /// Transient feedback ("beat 17 · +2 f", errors, …).
    var status: String?
    /// Thumbnail shown over the preview while slipping.
    var slipPreview: NSImage?
    var playheadFrame = 0
    var isPlaying = false

    // MARK: Timeline view
    var pixelsPerFrame: CGFloat = 1
    var offsetFrames: CGFloat = 0
    var fitTimeline = true

    // MARK: Export
    var exportProgress: Double?
    var lastExport: URL?
    var errorMessage: String?

    let player = AVPlayer()
    /// Our own undo stack: one explicit group per edit. (The window's manager groups by user
    /// event, which would merge edits made from tasks — like Generate — with the next click.)
    @ObservationIgnored let undoManager: UndoManager = {
        let u = UndoManager()
        u.groupsByEvent = false
        u.levelsOfUndo = 200
        return u
    }()
    /// Bumped on every undo change so menus re-evaluate.
    private(set) var undoVersion = 0
    @ObservationIgnored private var sources: [URL: SourceTrack] = [:]
    @ObservationIgnored private var musicTrack: MusicSource?
    @ObservationIgnored private let cache = AnalysisCache()
    @ObservationIgnored private let limiter = Limiter(3)
    @ObservationIgnored private var gestureBase: Timeline?
    @ObservationIgnored private var gestureName = ""
    /// Identifies the current gesture, so a late end (e.g. a scroll burst settling) can't end a newer one.
    @ObservationIgnored private(set) var gestureID = 0
    /// The settings that go with the timeline the undo stack last recorded.
    @ObservationIgnored private var committedSettings = EditSettings(musicStart: 0, length: 30, pace: .normal, startIsManual: false,
                                                                     beatMode: .detected, beats: nil, beatsUsed: nil,
                                                                     gradeAll: .identity, clipGrades: [:])
    @ObservationIgnored private var rebuildScheduled = false
    @ObservationIgnored private var pendingSeek: Int?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var musicTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                // while a new item seeks to the edit point it reports 0; don't let that move the playhead
                guard let self, let t = self.timeline, time.isNumeric, !self.seekingAfterRebuild else { return }
                // only on change: every write invalidates the views that read it
                let f = min(t.frameCount, max(0, t.frame(time.seconds)))
                if self.playheadFrame != f { self.playheadFrame = f }
                let playing = self.player.rate != 0
                if self.isPlaying != playing { self.isPlaying = playing }
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem, ended == ObjectIdentifier(item) else { return }
                self.player.seek(to: .zero)
                self.player.play()  // loop
            }
        }
    }

    // MARK: - Derived

    var readyClips: [ClipAnalysis] { clips.filter(\.included).compactMap(\.analysis) }
    var analyzingCount: Int { clips.filter { if case .working = $0.state { true } else { false } }.count }
    var canGenerate: Bool { music != nil && !readyClips.isEmpty }
    var excerpt: (start: Double, end: Double)? {
        music?.excerpt(start: musicStart, length: length, maxLength: ExportPreset.shortsReels.maxDuration)
    }
    /// Removed clips, kept so undo can bring back segments that use them (their length, reframing
    /// and thumbnails are still needed). `sources` and `thumbnails` keep their entries too.
    @ObservationIgnored private var removedClips: [URL: ClipItem] = [:]
    /// Clips in the list plus removed ones (list wins).
    private var allClips: [ClipItem] { clips + removedClips.values.filter { r in !clips.contains { $0.url == r.url } } }

    var durations: [URL: Double] {
        Dictionary(allClips.compactMap { c in c.info.map { (c.url, $0.duration) } }, uniquingKeysWith: { a, _ in a })
    }
    /// Called per thumbnail tile while drawing: look up directly instead of building `allClips`.
    func analysis(_ url: URL) -> ClipAnalysis? { (clips.first { $0.url == url } ?? removedClips[url])?.analysis }
    /// Every loaded analysis, included or not: segments already in the timeline keep their reframing.
    private var analysesByURL: [URL: ClipAnalysis] {
        Dictionary(allClips.compactMap(\.analysis).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Settings an edit can change besides the timeline; undo restores them with it.
    private struct EditSettings: Equatable {
        var musicStart: Double
        var length: Double
        var pace: Pace
        var startIsManual: Bool
        var beatMode: BeatMode
        var beats: BeatGrid?
        var beatsUsed: BeatGrid?
        var gradeAll: ColorGrade
        var clipGrades: [URL: ColorGrade]
    }

    private var editSettings: EditSettings {
        get {
            EditSettings(musicStart: musicStart, length: length, pace: pace, startIsManual: startIsManual,
                         beatMode: beatMode, beats: beats, beatsUsed: beatsUsed, gradeAll: gradeAll, clipGrades: clipGrades)
        }
        set {
            musicStart = newValue.musicStart
            length = newValue.length
            pace = newValue.pace
            startIsManual = newValue.startIsManual
            beatMode = newValue.beatMode
            beats = newValue.beats
            beatsUsed = newValue.beatsUsed
            gradeAll = newValue.gradeAll
            clipGrades = newValue.clipGrades
            if let b = selectedBeat, b >= (beats?.times.count ?? 0) { selectedBeat = nil }
            refreshGrid()
        }
    }

    // MARK: - Music

    /// The song whose sandbox access we hold (released when another song replaces it).
    @ObservationIgnored private var musicAccess: URL?

    func setMusic(_ url: URL) {
        // balance every start with one stop, also when the same song is chosen again
        let started = url.startAccessingSecurityScopedResource()
        if started || musicAccess != url {
            musicAccess?.stopAccessingSecurityScopedResource()
            musicAccess = started ? url : nil
        }
        musicURL = url
        music = nil
        referenceGrids = [:]
        musicTrack = nil
        musicState = .working(0)
        startIsManual = false
        beats = nil
        beatsUsed = nil
        beatMode = .detected
        selectedSegment = nil
        selectedCut = nil
        selectedBeat = nil
        // the old song's edits can't be undone onto the new one; stop playing the old composition
        gestureBase = nil
        undoManager.removeAllActions()
        undoVersion += 1
        setTimeline(nil, seek: nil)
        committedSettings = editSettings
        musicTask?.cancel()
        musicTask = Task {
            do {
                let a = try await MusicAnalyzer.analyze(url: url)
                let track = try await MusicSource.load(url)
                // superseded (also by choosing the same song again): only the newest task commits
                guard !Task.isCancelled, musicURL == url else { return }
                music = a
                referenceGrids = [:]
                musicTrack = track
                beats = .detected(a)
                musicStart = a.suggestedStart(length: length)
                musicState = .ready
                committedSettings = editSettings
                if canGenerate, analyzingCount == 0 { generate() }
            } catch {
                guard !Task.isCancelled, musicURL == url, !(error is CancellationError) else { return }
                musicState = .failed(error.localizedDescription)
            }
        }
    }

    func setLength(_ l: Double) {
        length = min(max(l, 5), ExportPreset.shortsReels.maxDuration)
        if let music, !startIsManual { musicStart = music.suggestedStart(length: length) }
        excerptChanged()
    }

    /// Move the excerpt start (snapped to the nearest downbeat).
    func setMusicStart(_ t: Double, final: Bool) {
        guard let music else { return }
        // keep the whole excerpt inside the song (like `suggestedStart`) so it isn't cut short
        let all = music.downbeats
        let fitting = all.filter { $0 + length <= music.duration + 0.5 }
        let db = fitting.isEmpty ? all : fitting
        musicStart = db.min { abs($0 - t) < abs($1 - t) } ?? max(0, t)
        startIsManual = true
        if final { excerptChanged() }
    }

    /// The excerpt changed: the old cuts no longer fit, so plan again with the same seed.
    private func excerptChanged() {
        guard let t = timeline else { committedSettings = editSettings; return }
        // unchanged (e.g. a click on the excerpt without dragging): keep the hand edits
        if let (s, e) = excerpt, abs(s - t.musicStart) < 1e-9, Int(((e - s) * Double(t.fps)).rounded()) == t.frameCount {
            committedSettings = editSettings
            return
        }
        replan(seed: t.seed, keepPins: false, actionName: "Change Music Range")
    }

    // MARK: - Clips

    func addClips(_ urls: [URL]) {
        for u in urls { _ = u.startAccessingSecurityScopedResource() }
        let known = Set(clips.map(\.url))
        let new = MediaLibrary.movieFiles(in: urls).filter { !known.contains($0) }
        // (a clip dragged from the library and dropped back on it is not news)
        if new.isEmpty, !urls.isEmpty, !urls.allSatisfy({ known.contains($0.standardizedFileURL) }) { flash("No new videos found") }
        for url in new {
            clips.append(ClipItem(url: url))
            Task { await analyze(url) }
        }
    }

    private func analyze(_ url: URL) async {
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        do {
            let info = try await MediaLibrary.loadInfo(url)
            update(url) { $0.info = info }
            let a = try await cache.analysis(for: info) { p in
                Task { @MainActor [weak self] in self?.update(url) { if case .working = $0.state { $0.state = .working(p) } } }
            }
            let src = try await SourceTrack.load(url)
            sources[url] = src
            thumbnails[url] = a.thumbnails.compactMap { NSImage(data: $0) }
            update(url) {
                $0.analysis = a
                $0.state = .ready
            }
        } catch {
            update(url) { $0.state = .failed(error.localizedDescription) }
        }
        // also when the last clip to finish failed: the others are ready
        if timeline == nil, canGenerate, analyzingCount == 0 { generate() }
    }

    private func update(_ url: URL, _ change: (inout ClipItem) -> Void) {
        guard let i = clips.firstIndex(where: { $0.url == url }) else { return }
        change(&clips[i])
    }

    func toggleIncluded(_ url: URL) { update(url) { $0.included.toggle() } }

    func removeClip(_ url: URL) {
        if let item = clips.first(where: { $0.url == url }) { removedClips[url] = item }
        clips.removeAll { $0.url == url }
        if timeline?.segments.contains(where: { $0.clip == url }) == true, let t = timeline {
            replan(seed: t.seed, keepPins: true, actionName: "Remove Video", dropping: url)
        }
    }

    func thumbnail(_ url: URL, at t: Double) -> NSImage? {
        guard let thumbs = thumbnails[url], !thumbs.isEmpty, let i = analysis(url)?.thumbnailIndex(at: t) else { return nil }
        return thumbs[min(thumbs.count - 1, i)]
    }

    func poster(_ url: URL) -> NSImage? {
        guard let thumbs = thumbnails[url], !thumbs.isEmpty else { return nil }
        return thumbs[thumbs.count / 3]
    }

    // MARK: - Generate / Shuffle

    func generate() {
        // only play when there is a new cut to see
        if replan(seed: UInt64.random(in: 1...UInt64.max), keepPins: false, actionName: "Generate") { player.play() }
    }

    /// New random picks; segments edited by hand stay unless `all`.
    func shuffle(all: Bool = false) {
        guard timeline != nil else { return generate() }
        replan(seed: UInt64.random(in: 1...UInt64.max), keepPins: !all, actionName: all ? "Shuffle All" : "Shuffle")
    }

    func setPace(_ p: Pace) {
        pace = p
        if let t = timeline { replan(seed: t.seed, keepPins: true, actionName: "Change Pace") } else { committedSettings = editSettings }
    }

    @discardableResult
    private func replan(seed: UInt64, keepPins: Bool, actionName: String, dropping: URL? = nil) -> Bool {
        guard let music, let musicURL, let (s, e) = excerpt else { return false }
        let pins = keepPins ? (timeline?.segments.filter { $0.pinned && $0.clip != dropping } ?? []) : []
        do {
            let t = try EditPlanner.plan(music: music, musicURL: musicURL, start: s, end: e, clips: readyClips,
                                         beats: beats, settings: PlanSettings(pace: pace), seed: seed, keeping: pins)
            beatsUsed = beats
            selectedCut = nil
            selectedSegment = nil
            commit(t, actionName: actionName, seek: 0)
            fitTimeline = true
            return true
        } catch {
            committedSettings = editSettings
            flash(error.localizedDescription)
            return false
        }
    }

    // MARK: - Edits (undoable)

    /// Replace the timeline with undo.
    func commit(_ t: Timeline, actionName: String, seek: Int? = nil) {
        endGesture()  // a gesture still settling (e.g. a scroll slip) is its own undo step
        let old = timeline
        setTimeline(t, seek: seek)
        registerUndo(from: old, settings: committedSettings, actionName: actionName)
    }

    private func registerUndo(from old: Timeline?, settings oldSettings: EditSettings, actionName: String) {
        let current = timeline, currentSettings = editSettings
        committedSettings = currentSettings
        guard old != current || oldSettings != currentSettings else { return }
        // while undoing/redoing, the manager collects the inverse into its own group
        let group = !undoManager.isUndoing && !undoManager.isRedoing
        if group { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { m in
            MainActor.assumeIsolated {
                m.editSettings = oldSettings
                m.setTimeline(old, seek: nil)
                m.registerUndo(from: current, settings: currentSettings, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        if group { undoManager.endUndoGrouping() }
        undoVersion += 1
    }

    var canUndo: Bool { _ = undoVersion; return undoManager.canUndo }
    var canRedo: Bool { _ = undoVersion; return undoManager.canRedo }
    var undoTitle: String { _ = undoVersion; return undoManager.undoMenuItemTitle }
    var redoTitle: String { _ = undoVersion; return undoManager.redoMenuItemTitle }

    func undo() {
        // a gesture still settling (e.g. a scroll slip) becomes its own step first, so undo takes
        // back that edit instead of the one before it (and the late end can't clear the redo stack)
        endGesture()
        guard undoManager.canUndo else { return }
        undoManager.undo()
        undoVersion += 1
    }

    func redo() {
        endGesture()
        guard undoManager.canRedo else { return }
        undoManager.redo()
        undoVersion += 1
    }

    /// The timeline without its pins: what the composition depends on.
    private static func rendered(_ t: Timeline?) -> Timeline? {
        guard var t else { return nil }
        for i in t.segments.indices { t.segments[i].pinned = false }
        return t
    }

    private func setTimeline(_ t: Timeline?, seek: Int?) {
        // pinning alone changes nothing on screen: keep the playing item (no black blink)
        let sameCuts = t != nil && Self.rendered(t) == Self.rendered(builtTimeline) && player.currentItem != nil
        if sameCuts { builtTimeline = t }
        timeline = t
        refreshGrid()
        if let t {
            if let s = selectedSegment, s >= t.segments.count { selectedSegment = nil }
            if let c = selectedCut, c >= t.segments.count { selectedCut = nil }
        }
        if sameCuts {
            // e.g. undoing a colour or beat edit: the playing item stays, only the curves may change
            scheduleGradeRefresh()
            if let seek { self.seek(frame: seek) }
        } else {
            scheduleRebuild(seek: seek)
        }
    }

    /// Snap targets for cuts: the (edited) beats and the song's onsets.
    private func refreshGrid() {
        guard let t = timeline, let music else { grid = nil; return }
        grid = SnapGrid(beats: beats ?? .detected(music), onsets: music.onsets, timeline: t)
    }

    // MARK: - Colour (undoable)

    /// The clip Single mode edits: the chosen one, else the selected shot's, else the first in the timeline.
    var gradeTarget: URL? {
        if let c = gradeClip, timeline?.segments.contains(where: { $0.clip == c }) == true { return c }
        if let t = timeline, let i = selectedSegment, t.segments.indices.contains(i) { return t.segments[i].clip }
        return timeline?.segments.first?.clip
    }

    /// The grade the panel edits (all clips, or the target clip's own).
    var editedGrade: ColorGrade {
        if gradeScope == .single, let url = gradeTarget { return clipGrades[url] ?? .identity }
        return gradeAll
    }

    private func setEditedGrade(_ g: ColorGrade) {
        if gradeScope == .single, let url = gradeTarget {
            // drop the clip's grade only when its curves are straight: `isIdentity` is also true at
            // strength 0, and dropping then would lose the curve the strength slider turns back up
            let straight = g.curves.allSatisfy { $0.allSatisfy { abs($0.x - $0.y) < 1e-6 } }
            clipGrades[url] = straight ? nil : g
        } else {
            gradeAll = g
        }
        // show the change on the current frame, without reloading the player (that blinks black)
        scheduleGradeRefresh()
    }

    /// Replace the edited channel's curve (with link, R, G and B together). `final` = one undo step
    /// now; otherwise it's part of a drag between `beginCurveDrag` and `endCurveDrag`.
    func setCurve(_ points: [CurvePoint], final: Bool) {
        var g = editedGrade
        let channels: [CurveChannel] = linkRGB && gradeChannel != .luma ? [.red, .green, .blue] : [gradeChannel]
        for c in channels { g[c] = points }
        setEditedGrade(g)
        if final { commitSettings("Color Curve") }
    }

    func setIntensity(_ v: Float, channel: CurveChannel, final: Bool) {
        var g = editedGrade
        g.intensity[channel.rawValue] = min(max(v, 0), 1)
        setEditedGrade(g)
        if final { commitSettings("Curve Strength") }
    }

    @ObservationIgnored private var curveGesture: Int?
    func beginCurveDrag() { curveGesture = beginGesture("Color Curve") }
    func endCurveDrag() {
        if let g = curveGesture { endGesture(g) }
        curveGesture = nil
    }

    func resetChannel(_ c: CurveChannel) {
        var g = editedGrade
        g[c] = ColorGrade.identityCurve
        g.intensity[c.rawValue] = 1
        setEditedGrade(g)
        commitSettings("Reset Curve")
    }

    func resetGrade() {
        setEditedGrade(.identity)
        commitSettings(gradeScope == .all ? "Reset Color" : "Reset Clip Color")
    }

    /// Each clip's combined curves (all clips, then its own) for the compositor.
    var curvesByClip: [URL: Data] {
        var out = [URL: Data]()
        for url in Set(timeline?.segments.map(\.clip) ?? []) {
            if let d = ColorGrade.curvesData([gradeAll, clipGrades[url] ?? .identity]) { out[url] = d }
        }
        return out
    }

    /// Histogram behind the curve editor: of the edited clip, or of every clip in the video.
    var histogram: Histogram? {
        let urls: [URL]
        let key: String
        if gradeScope == .single, let u = gradeTarget {
            urls = [u]
            key = u.path
        } else {
            urls = Array(Set(timeline?.segments.map(\.clip) ?? [])).sorted { $0.path < $1.path }
            key = "all|" + urls.map(\.path).joined(separator: "|")
        }
        if let h = histograms[key] { return h }
        // a spread of thumbnails, at most ~60 in total
        var images = [CGImage]()
        let per = max(1, 60 / max(urls.count, 1))
        for u in urls {
            guard let thumbs = thumbnails[u], !thumbs.isEmpty else { continue }
            let step = max(1, thumbs.count / per)
            for i in stride(from: 0, to: thumbs.count, by: step) {
                if let cg = thumbs[i].cgImage(forProposedRect: nil, context: nil, hints: nil) { images.append(cg) }
            }
        }
        let h = Histogram.compute(images)
        if let h { histograms[key] = h }
        return h
    }

    // MARK: - Beats (undoable)

    /// A settings-only edit (the beats): one undo step.
    private func commitSettings(_ actionName: String) {
        endGesture()
        refreshGrid()
        registerUndo(from: timeline, settings: committedSettings, actionName: actionName)
    }

    /// The unedited detected or steady grid of the current song. Cached: the steady fit is a
    /// search over hundreds of periods, too slow to redo on every drag event.
    @ObservationIgnored private var referenceGrids: [BeatMode: BeatGrid] = [:]

    private func referenceGrid(_ mode: BeatMode, _ music: MusicAnalysis) -> BeatGrid {
        if let g = referenceGrids[mode] { return g }
        let g = mode == .detected ? BeatGrid.detected(music) : .steady(music)
        referenceGrids[mode] = g
        return g
    }

    func setBeatMode(_ mode: BeatMode) {
        guard let music else { return }
        beatMode = mode
        beats = referenceGrid(mode, music)
        selectedBeat = nil
        commitSettings(mode == .detected ? "Detected Beats" : "Steady Beats")
        flash(String(format: "%@ beats · %.1f BPM", mode.title, beats?.bpm ?? 0))
    }

    /// Steady grid at a new tempo, keeping the beat at the start of the excerpt in place.
    func setSteadyBPM(_ bpm: Double) {
        guard let music, beatMode == .steady, bpm >= 40, bpm <= 250 else { return }
        var g = BeatGrid.steady(music, bpm: bpm, anchor: musicStart)
        // keep where the beats sit at the start of the excerpt (e.g. after "shift all"): the new
        // grid goes through the current beat there, and only the spacing changes
        if let cur = beats, let ci = cur.nearest(to: musicStart), let fi = g.nearest(to: cur.times[ci]) {
            let dt = cur.times[ci] - g.times[fi]
            if abs(dt) < 30 / bpm { g = g.shifted(by: dt) }
        }
        // an even grid can't keep single moved or deleted beats: say so when there were any
        let handEdited = beats.map { b in Set(zip(b.times, b.times.dropFirst()).map { (($1 - $0) * 1e4).rounded() }).count > 1 } ?? false
        beats = g
        selectedBeat = nil
        commitSettings("Change Tempo")
        flash(String(format: "%.1f BPM%@", g.bpm, handEdited ? " · moved/deleted beats were reset (⌘Z to undo)" : ""))
    }

    /// Throw away hand edits: back to the detected or steady grid.
    func resetBeats() {
        guard let music else { return }
        beats = referenceGrid(beatMode, music)
        selectedBeat = nil
        commitSettings("Reset Beats")
    }

    /// All beats earlier (negative) or later.
    func shiftBeats(by dt: Double) {
        guard let b = beats else { return }
        beats = b.shifted(by: dt)
        commitSettings("Shift Beats")
        flash(String(format: "All beats %+.0f ms", beatShift(beats!) * 1000))
    }

    /// Move the selected beat by `dt` seconds.
    func nudgeSelectedBeat(by dt: Double) {
        guard let b = beats, let i = selectedBeat, b.times.indices.contains(i) else { return }
        beats = b.moving(i, to: b.times[i] + dt)
        commitSettings("Move Beat")
        describeBeat(i)
    }

    func deleteSelectedBeat() {
        guard let b = beats, let i = selectedBeat, b.times.indices.contains(i) else { return }
        beats = b.deleting(i)
        selectedBeat = nil
        commitSettings("Delete Beat")
        flash("Beat deleted · Generate to re-cut")
    }

    func insertBeat(at songTime: Double) {
        guard let b = beats, let (g, i) = b.inserting(at: songTime) else { return }
        beats = g
        selectedBeat = i
        commitSettings("Add Beat")
        flash("Beat added · Generate to re-cut")
    }

    /// Live beat edits during a drag (inside `beginGesture` / `endGesture`).
    func updateBeats(_ g: BeatGrid) {
        beats = g
        refreshGrid()
    }

    /// How far the grid sits from the unedited one (for feedback while shifting).
    func beatShift(_ g: BeatGrid) -> Double {
        guard let music else { return 0 }
        let ref = referenceGrid(beatMode, music)
        guard let t = g.times.first, let i = ref.nearest(to: t) else { return 0 }
        return t - ref.times[i]
    }

    func describeBeat(_ i: Int) {
        guard let b = beats, b.times.indices.contains(i), let music else { return }
        let ref = referenceGrid(beatMode, music)
        let off = ref.nearest(to: b.times[i]).map { b.times[i] - ref.times[$0] } ?? 0
        flash(String(format: "beat %d · %+.0f ms", i + 1, off * 1000))
    }

    /// Drag-style edits: many updates, one undo step. Returns the gesture's id for `endGesture`.
    @discardableResult
    func beginGesture(_ name: String) -> Int {
        endGesture()  // never drop the undo step of a gesture still in progress
        gestureID += 1
        gestureBase = timeline
        gestureName = name
        return gestureID
    }

    var gestureStart: Timeline? { gestureBase }

    func updateGesture(_ t: Timeline, seek: Int?) {
        setTimeline(t, seek: seek)
    }

    /// End the current gesture, or only gesture `id` when given.
    func endGesture(_ id: Int? = nil) {
        guard id == nil || id == gestureID else { return }
        slipPreview = nil
        guard let base = gestureBase else { return }
        gestureBase = nil
        registerUndo(from: base, settings: committedSettings, actionName: gestureName)
    }

    var isGesturing: Bool { gestureBase != nil }

    // MARK: - Shots: move, replace, re-roll

    /// Move shot `from` to position `to`; the cuts stay on the beat, the contents move.
    func moveShot(from: Int, to: Int) {
        guard let t = timeline, from != to else { return }
        guard let r = TimelineEdits.moveShot(t, from: from, to: to, durations: durations) else {
            flash("That clip is too short for the shot at the new position")
            return
        }
        selectedSegment = to
        selectedCut = nil
        commit(r.timeline, actionName: "Move Shot", seek: r.timeline.segments[to].startFrame)
        flash(r.clamped ? "Shot moved · in-points pulled earlier to fit" : "Shot moved")
    }

    /// Show another video in shot `i`, at its best part.
    func replaceShot(_ i: Int, with url: URL) {
        guard let t = timeline, t.segments.indices.contains(i) else { return }
        let u = url.standardizedFileURL
        guard let item = clips.first(where: { $0.url == u }) else {
            addClips([url])
            flash("Video added to the library · drop it on the shot again once it's analysed")
            return
        }
        guard let a = item.analysis else {
            flash("\(item.name) is still being analysed")
            return
        }
        guard let out = TimelineEdits.replaceClip(t, segment: i, with: a) else {
            flash(String(format: "%@ is too short for this shot (%.1f s)", item.name, Double(t.segments[i].frameCount) / Double(t.fps)))
            return
        }
        selectedSegment = i
        commit(out, actionName: "Replace Clip", seek: t.segments[i].startFrame)
        let s = out.segments[i]
        flash(String(format: "%@ · %.2f – %.2f s", item.name, s.sourceStart, s.sourceStart + Double(s.frameCount) / Double(t.fps)))
    }

    /// A new random pick for shot `i` only.
    func rerollShot(_ i: Int) {
        guard let t = timeline, t.segments.indices.contains(i) else { return }
        guard let out = EditPlanner.reroll(t, segment: i, clips: readyClips, seed: UInt64.random(in: 1...UInt64.max)) else {
            flash("No other clip fits this shot")
            return
        }
        selectedSegment = i
        commit(out, actionName: "Re-roll Shot", seek: t.segments[i].startFrame)
        let s = out.segments[i]
        flash(String(format: "%@ · %.2f s", s.clip.deletingPathExtension().lastPathComponent, s.sourceStart))
    }

    func togglePin(_ i: Int) {
        guard let t = timeline, t.segments.indices.contains(i) else { return }
        commit(TimelineEdits.setPinned(t, segment: i, !t.segments[i].pinned), actionName: t.segments[i].pinned ? "Unpin" : "Pin")
    }

    func reSnapAll() {
        guard let t = timeline, let grid else { return }
        let fixed = TimelineEdits.reSnapAll(t, grid: grid, radius: max(2, t.fps / 10), durations: durations)
        let moved = zip(fixed.cutFrames, t.cutFrames).filter { $0 != $1 }.count
        commit(fixed, actionName: "Re-snap Cuts")
        flash(moved == 0 ? "All cuts already on the beat" : "Moved \(moved) cut\(moved == 1 ? "" : "s") onto the beat")
    }

    /// Nudge the selected cut by frames, or to the previous / next beat.
    func nudgeCut(by frames: Int, toBeat: Bool) {
        guard let t = timeline, let c = selectedCut, t.segments.indices.contains(c) else { return }
        let f = t.segments[c].startFrame
        let target = toBeat ? (frames < 0 ? grid?.beat(before: f) : grid?.beat(after: f)) ?? f : f + frames
        let r = TimelineEdits.rollCut(t, before: c, to: target, durations: durations)
        commit(r.timeline, actionName: "Nudge Cut", seek: r.timeline.segments[c].startFrame)
        describeCut(r.timeline.segments[c].startFrame, clamped: r.clamped)
    }

    /// Slip the selected segment by frames.
    func slipSelected(by frames: Int) {
        guard let t = timeline, let i = selectedSegment, t.segments.indices.contains(i) else { return }
        let r = TimelineEdits.slip(t, segment: i, byFrames: frames, duration: durations[t.segments[i].clip])
        commit(r.timeline, actionName: "Slip Clip", seek: t.segments[i].startFrame)
        describeSlip(r.timeline.segments[i], clamped: r.clamped)
    }

    func describeCut(_ frame: Int, clamped: Bool) {
        guard let grid, let (beat, off) = grid.describe(frame) else { return }
        let offText = off == 0 ? "on the beat" : String(format: "%+d f", off)
        flash("beat \(beat) · \(offText)\(clamped ? " · limit" : "")")
    }

    func describeSlip(_ s: Segment, clamped: Bool) {
        guard let t = timeline else { return }
        let len = Double(s.frameCount) / Double(t.fps)
        flash(String(format: "%@ · %.2f – %.2f s%@", s.clip.deletingPathExtension().lastPathComponent, s.sourceStart, s.sourceStart + len, clamped ? " · end of clip" : ""))
        // only while a slip gesture runs: `endGesture` clears it, and nothing would after a one-shot slip
        slipPreview = isGesturing ? thumbnail(s.clip, at: s.sourceStart) : nil
    }

    func flash(_ text: String) {
        status = text
        statusTask?.cancel()
        statusTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { status = nil }
        }
    }

    // MARK: - Player

    /// Rebuild the composition after an edit (coalesced: at most one per run-loop turn).
    private func scheduleRebuild(seek: Int?) {
        if let seek { pendingSeek = seek }
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        Task { @MainActor in
            rebuildScheduled = false
            rebuild()
        }
    }

    /// The plan behind the player's current item and the timeline it was built from.
    @ObservationIgnored private var plan: RenderPlan?
    @ObservationIgnored private var builtTimeline: Timeline?
    @ObservationIgnored private var gradeRefreshScheduled = false
    @ObservationIgnored private var seekingAfterRebuild = false
    /// Player items created so far (the smoke test checks colour edits don't add one).
    @ObservationIgnored private(set) var playerItemsCreated = 0

    /// Swap the colour curves of the playing item in place (coalesced to one per run-loop turn).
    private func scheduleGradeRefresh() {
        guard !gradeRefreshScheduled else { return }
        gradeRefreshScheduled = true
        Task { @MainActor in
            gradeRefreshScheduled = false
            refreshGrade()
        }
    }

    private func refreshGrade() {
        guard let plan, let item = player.currentItem, builtTimeline == timeline else {
            scheduleRebuild(seek: playheadFrame)
            return
        }
        item.videoComposition = plan.videoComposition(curves: curvesByClip)
        // a paused player keeps showing the old frame: draw this one again with the new curves
        if player.rate == 0 {
            player.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func rebuild() {
        guard let t = timeline, let musicTrack else {
            player.replaceCurrentItem(with: nil)
            plan = nil
            builtTimeline = nil
            return
        }
        do {
            let plan = try CompositionBuilder.build(t, sources: sources, music: musicTrack, clips: analysesByURL, curves: curvesByClip)
            self.plan = plan
            builtTimeline = t
            playerItemsCreated += 1
            let wasPlaying = player.rate != 0
            let resume = player.currentTime()
            player.replaceCurrentItem(with: plan.playerItem())
            let target: CMTime
            if let f = pendingSeek {
                // when playing, start a moment before the edit so the cut is seen in context
                target = CMTime(value: CMTimeValue(wasPlaying ? max(0, f - t.fps) : f), timescale: CMTimeScale(t.fps))
            } else {
                target = resume
            }
            seekingAfterRebuild = true
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.seekingAfterRebuild = false }
            }
            pendingSeek = nil
            if wasPlaying { player.play() }
        } catch {
            flash(error.localizedDescription)
        }
    }

    func togglePlay() {
        if player.rate != 0 { player.pause() } else { player.play() }
        isPlaying = player.rate != 0
    }

    func seek(frame: Int) {
        guard let t = timeline else { return }
        let f = min(max(0, frame), t.frameCount - 1)
        playheadFrame = f
        player.seek(to: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(t.fps)), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Export

    func export(to url: URL) {
        guard let t = timeline, let musicTrack else { return }
        let clipsByURL = analysesByURL
        let curves = curvesByClip
        exportProgress = 0
        errorMessage = nil
        player.pause()
        let sources = sources
        exportTask = Task {
            do {
                let plan = try CompositionBuilder.build(t, sources: sources, music: musicTrack, clips: clipsByURL, curves: curves)
                let gain = try await Exporter.musicGain(t)
                let report = try await Exporter.export(plan, fps: t.fps, gain: gain, to: url) { p in
                    Task { @MainActor [weak self] in if self?.exportProgress != nil { self?.exportProgress = p } }
                }
                lastExport = report.url
                flash(String(format: "Exported in %.1f s", report.seconds))
            } catch is CancellationError {
                flash("Export cancelled")
            } catch {
                errorMessage = error.localizedDescription
            }
            exportProgress = nil
        }
    }

    func cancelExport() { exportTask?.cancel() }

    var suggestedExportName: String {
        let song = musicURL?.deletingPathExtension().lastPathComponent ?? "short"
        let clean = song.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return "\(clean.prefix(60))-\(String(timeline?.seed ?? 0, radix: 36).prefix(6)).mp4"
    }
}

/// At most `n` analyses at once (the hardware decoders are shared).
actor Limiter {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ n: Int) { free = n }

    func acquire() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}
