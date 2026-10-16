#if DEBUG
import AppKit
import AVFoundation
import TurboTapeKit

/// Headless check of the whole app for development, driven by environment variables (needs an
/// unsandboxed build: `xcodebuild … CODE_SIGN_ENTITLEMENTS=`):
///
/// - `TURBOTAPE_MUSIC=<file>` and `TURBOTAPE_CLIPS=<path>:<path>` load media at launch;
/// - `TURBOTAPE_SNAPSHOT=<png>` then snapshots the window, makes a roll and a slip edit, undoes
///   them, and exports next to the PNG, printing the results.
@MainActor
enum SmokeTest {
    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let m = env["TURBOTAPE_MUSIC"] { model.setMusic(URL(fileURLWithPath: m)) }
        if let c = env["TURBOTAPE_CLIPS"] { model.addClips(c.split(separator: ":").map { URL(fileURLWithPath: String($0)) }) }
        if let path = env["TURBOTAPE_SNAPSHOT"] {
            setvbuf(stdout, nil, _IOLBF, 0)
            // TURBOTAPE_SNAPSHOT=<png>: after the analysis settles, select a shot and snapshot the window
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                model.selectedSegment = 2
                try? await Task.sleep(for: .seconds(1))
                guard let view = NSApp.windows.first(where: \.isVisible)?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("snapshot: \(model.timeline?.segments.count ?? 0) shots, \(model.clips.count) clips, music \(model.music?.bpm ?? 0)")
                // exercise the edit + undo paths (an edit at a clip's end is clamped and is a no-op)
                let before = model.timeline
                model.selectedCut = 3
                model.nudgeCut(by: -2, toBeat: false)
                try? await Task.sleep(for: .milliseconds(100))  // separate undo groups
                model.selectedSegment = 4
                model.slipSelected(by: 15)
                try? await Task.sleep(for: .milliseconds(100))
                while model.timeline != before, model.undoManager.undoActionName != "Generate", model.undoManager.canUndo {
                    model.undo()
                }
                print("undo restores: \(model.timeline == before)")
                model.slipSelected(by: 15)
                // beats: steady grid, shift all, delete one, re-cut on them
                model.setBeatMode(.steady)
                try? await Task.sleep(for: .milliseconds(50))
                model.shiftBeats(by: 0.02)
                try? await Task.sleep(for: .milliseconds(50))
                // a tempo tweak keeps the shifted alignment at the start of the excerpt
                let start = model.timeline?.musicStart ?? 0
                let anchorBefore = model.beats.flatMap { b in b.nearest(to: start).map { b.times[$0] } } ?? 0
                model.setSteadyBPM((model.beats?.bpm ?? 120) + 0.3)
                let anchorAfter = model.beats.flatMap { b in b.nearest(to: start).map { b.times[$0] } } ?? 0
                print(String(format: "tempo tweak keeps alignment: %@ (%.1f ms)", "\(abs(anchorAfter - anchorBefore) < 0.001)", (anchorAfter - anchorBefore) * 1000))
                model.selectedBeat = (model.beats?.times.firstIndex { $0 > (model.timeline?.musicStart ?? 0) + 5 }) ?? 10
                let gridBeforeDelete = model.beats
                model.deleteSelectedBeat()
                try? await Task.sleep(for: .milliseconds(50))
                let changed = model.beatsChanged
                try? await Task.sleep(for: .milliseconds(50))
                model.generate()
                if let t = model.timeline, let b = model.beats {
                    let frames = Set(b.times.map { t.frame(songTime: $0) })
                    let gaps = zip(b.times, b.times.dropFirst()).map { $1 - $0 }
                    print(String(format: "beats: %@ %.1f BPM, changed before generate %@, cuts on edited beats %@, after generate changed %@",
                                 model.beatMode.title, b.bpm, "\(changed)", "\(t.cutFrames.allSatisfy(frames.contains))", "\(model.beatsChanged)"))
                    print("steady gaps equal except the deleted beat: \(Set(gaps.map { ($0 * 1e6).rounded() }).count <= 2)")
                }
                try? await Task.sleep(for: .milliseconds(50))
                model.undo()  // generate
                model.undo()  // delete
                print("undo brings back the deleted beat: \(model.beats == gridBeforeDelete) mode \(model.beatMode.title)")
                // shots: move, replace, re-roll, then undo all three
                if let t0 = model.timeline, t0.segments.count > 6 {
                    model.moveShot(from: 1, to: 5)
                    let t1 = model.timeline!
                    let moved = t1.segments[5].id == t0.segments[1].id && t1.cutFrames == t0.cutFrames && t1.isValid
                    try? await Task.sleep(for: .milliseconds(50))
                    let longest = model.clips.compactMap(\.analysis).filter { $0.url != t1.segments[2].clip }.max { $0.duration < $1.duration }!
                    model.replaceShot(2, with: longest.url)
                    let replaced = model.timeline!.segments[2].clip == longest.url && model.timeline!.segments[2].pinned
                    try? await Task.sleep(for: .milliseconds(50))
                    let before3 = model.timeline!.segments[3]
                    model.rerollShot(3)
                    let after3 = model.timeline!.segments[3]
                    let rerolled = after3 != before3 && after3.startFrame == before3.startFrame && after3.frameCount == before3.frameCount
                    try? await Task.sleep(for: .milliseconds(50))
                    model.undo(); model.undo(); model.undo()
                    print("shots: moved \(moved), replaced \(replaced), re-rolled \(rerolled), undo restores \(model.timeline == t0)")
                }
                // colour: a curve for all clips, one clip's own on top, undo / redo
                if let t = model.timeline {
                    let clipsInVideo = Set(t.segments.map(\.clip))
                    model.gradeScope = .all
                    model.gradeChannel = .luma
                    // watch the paused preview while the curve changes
                    model.player.pause()
                    try? await Task.sleep(for: .milliseconds(300))
                    let where_ = min(200, (model.timeline?.frameCount ?? 2) - 1)
                    model.seek(frame: where_)
                    try? await Task.sleep(for: .milliseconds(500))
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    let itemBefore = model.player.currentItem
                    itemBefore?.add(output)
                    model.seek(frame: model.playheadFrame)
                    func shownMean() async -> Double? {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard let item = model.player.currentItem,
                              let pb = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) else { return nil }
                        CVPixelBufferLockBaseAddress(pb, .readOnly)
                        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
                        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                        var sum = 0.0
                        for y in stride(from: 0, to: h, by: 8) { for x in stride(from: 0, to: w, by: 8) { sum += Double(p[y * rb + 4 * x + 1]) } }
                        return sum / Double((h / 8) * (w / 8)) / 255
                    }
                    let before = await shownMean()
                    let itemsBefore = model.playerItemsCreated
                    model.beginCurveDrag()
                    model.setCurve([CurvePoint(0, 0), CurvePoint(0.5, 0.3), CurvePoint(1, 0.7)], final: false)
                    model.endCurveDrag()
                    let after = await shownMean()
                    let stayed = model.playheadFrame == where_ && model.timeline!.frame(model.player.currentTime().seconds) == where_
                    print(String(format: "color live: same player item %@, new items %d, shown frame %.3f → %.3f, playhead stays %@ (%d)",
                                 "\(model.player.currentItem === itemBefore)", model.playerItemsCreated - itemsBefore, before ?? -1, after ?? -1,
                                 "\(stayed)", model.playheadFrame))
                    let allGraded = model.curvesByClip.count == clipsInVideo.count
                    let one = clipsInVideo.sorted { $0.path < $1.path }.first!
                    model.gradeScope = .single
                    model.gradeClip = one
                    model.gradeChannel = .blue
                    model.setCurve([CurvePoint(0, 0.3), CurvePoint(1, 1)], final: true)
                    let curves = model.curvesByClip
                    let others = clipsInVideo.filter { $0 != one }
                    let singleDiffers = others.allSatisfy { curves[$0] != curves[one] } && Set(others.map { curves[$0] }).count <= 1
                    try? await Task.sleep(for: .milliseconds(50))
                    model.undo()
                    let singleUndone = model.clipGrades.isEmpty && !model.gradeAll.isIdentity
                    model.undo()
                    let allUndone = model.gradeAll.isIdentity && model.curvesByClip.isEmpty
                    model.redo()
                    model.redo()
                    print("color: all clips graded \(allGraded), single clip differs \(singleDiffers), undo single \(singleUndone), undo all \(allUndone), redo \(model.clipGrades.count == 1 && !model.gradeAll.isIdentity)")
                    model.gradeScope = .all
                }
                let out = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("mp4")
                model.export(to: out)
                while model.exportProgress != nil { try? await Task.sleep(for: .milliseconds(100)) }
                print("export: \(model.lastExport?.path ?? "failed: \(model.errorMessage ?? "?")")")
            }
        }
    }
}
#endif
