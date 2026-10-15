import AppKit
import SwiftUI
import TurboTapeKit

struct TimelinePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text("Beats").font(.headline)
                Picker("Beats", selection: Binding(get: { model.beatMode }, set: { model.setBeatMode($0) })) {
                    ForEach(BeatMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Detected follows the music's own timing; Steady makes every beat exactly the same length")
                if model.beatMode == .steady, let b = model.beats {
                    Stepper(value: Binding(get: { (b.bpm * 10).rounded() / 10 }, set: { model.setSteadyBPM($0) }), in: 40...250, step: 0.1) {
                        Text(String(format: "%.1f BPM", b.bpm)).monospacedDigit()
                    }
                    .fixedSize()
                    .help("Fine-tune the tempo of the steady grid")
                    if let fit = model.steadyFit {
                        Text("fits \(Int((fit * 100).rounded())) %")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(fit < 0.6 ? .orange : .secondary)
                            .help(fit < 0.6
                                  ? "This song's tempo isn't steady: only \(Int((fit * 100).rounded())) % of its beats are on an even grid. Detected will follow it better."
                                  : "\(Int((fit * 100).rounded())) % of the music's tracked beats are within 40 ms of this grid")
                    }
                }
                HStack(spacing: 2) {
                    Button { model.shiftBeats(by: -0.01) } label: { Image(systemName: "chevron.left") }
                    Text("shift all").font(.caption).foregroundStyle(.secondary)
                    Button { model.shiftBeats(by: 0.01) } label: { Image(systemName: "chevron.right") }
                }
                .help("Move every beat 10 ms earlier / later (or ⇧-drag any beat)")
                Button("Reset") { model.resetBeats() }.help("Undo all hand edits to the beats")
                if model.beatsChanged {
                    Label("Beats changed · Generate to re-cut", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Re-snap Cuts") { model.reSnapAll() }.help("Move every cut onto the nearest beat (⇧⌘B)")
                Button {
                    model.fitTimeline = true
                } label: { Image(systemName: "arrow.left.and.right.square") }
                    .help("Zoom to fit (⌘-scroll or pinch to zoom)")
            }
            Text("Music: drag a beat (⌥ free) · ⇧-drag moves all · double-click adds · ⌫ deletes · ←/→ 10 ms      Video: drag a cut · select a shot and scroll over it to change which part plays (, / .)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView()
                .frame(height: 150)
            SlipInspector()
                .frame(height: 64)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Waveform, beat grid, the shots as thumbnail strips, and the playhead. All interaction goes
/// through `TimelineEventView` (mouse, scroll, pinch and keys).
struct TimelineView: View {
    @Environment(AppModel.self) private var model
    /// Height of the music lane (waveform + editable beats); the video lane is below it.
    static let waveHeight: CGFloat = 52

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { ctx, size in draw(&ctx, size) }
                // its own view, so playback redraws the playhead only, not the thumbnails
                TimelinePlayhead().allowsHitTesting(false)
                TimelineEventView(model: model)
            }
            .onAppear { fit(geo.size.width) }
            .onChange(of: geo.size.width) { fit(geo.size.width) }
            .onChange(of: model.fitTimeline) { if model.fitTimeline { fit(geo.size.width) } }
            .onChange(of: model.timeline?.frameCount) { if model.fitTimeline { fit(geo.size.width) } }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func fit(_ width: CGFloat) {
        guard model.fitTimeline, let t = model.timeline, t.frameCount > 0 else { return }
        model.pixelsPerFrame = width / CGFloat(t.frameCount)
        model.offsetFrames = 0
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard let t = model.timeline else { return }
        let ppf = model.pixelsPerFrame, off = model.offsetFrames
        let x = { (f: Int) in (CGFloat(f) - off) * ppf }
        let rowTop = Self.waveHeight + 4, rowH = size.height - rowTop - 4

        // music lane
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: Self.waveHeight + 2)), with: .color(.black.opacity(0.18)))
        if let m = model.music, !m.waveform.isEmpty {
            var p = Path()
            let cols = Int(size.width)
            for c in stride(from: 0, to: cols, by: 2) {
                let f = off + CGFloat(c) / ppf
                guard f >= 0, f < CGFloat(t.frameCount) else { continue }
                let i = Int((t.musicStart + Double(f) / Double(t.fps)) * m.waveformRate)
                let v = CGFloat(m.waveform[min(max(i, 0), m.waveform.count - 1)])
                let h = max(1, v * Self.waveHeight)
                p.addRect(CGRect(x: CGFloat(c), y: (Self.waveHeight - h) / 2 + 2, width: 1.5, height: h))
            }
            ctx.fill(p, with: .color(.secondary.opacity(0.55)))
        }

        // shots
        for (i, s) in t.segments.enumerated() {
            let r = CGRect(x: x(s.startFrame), y: rowTop, width: CGFloat(s.frameCount) * ppf, height: rowH)
            guard r.maxX >= 0, r.minX <= size.width else { continue }
            ctx.drawLayer { l in
                l.clip(to: Path(r))
                l.fill(Path(r), with: .color(.black))
                let tileW = rowH * 9 / 16
                var tx = r.minX
                while tx < r.maxX {
                    let f = (tx - r.minX + tileW / 2) / ppf
                    if let img = model.thumbnail(s.clip, at: s.sourceStart + Double(f) / Double(t.fps)) {
                        // centre-crop the thumbnail into a vertical tile
                        let aspect = img.size.width / max(img.size.height, 1)
                        let w = rowH * aspect
                        l.drawLayer { tl in
                            let tile = CGRect(x: tx, y: rowTop, width: tileW, height: rowH)
                            tl.clip(to: Path(tile))
                            tl.draw(Image(nsImage: img), in: CGRect(x: tx + (tileW - w) / 2, y: rowTop, width: w, height: rowH))
                        }
                    }
                    tx += tileW
                }
            }
            let selected = model.selectedSegment == i
            ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(selected ? .accentColor : .black.opacity(0.6)), lineWidth: selected ? 3 : 1)
            if s.pinned, r.width > 14 {
                ctx.draw(Text(Image(systemName: "pin.fill")).font(.system(size: 9)).foregroundColor(.white), at: CGPoint(x: r.minX + 8, y: rowTop + 9))
            }
        }

        // bar lines through the video lane
        if let g = model.grid {
            var bars = Path()
            for b in g.downbeats { bars.addRect(CGRect(x: x(b), y: rowTop, width: 1, height: rowH)) }
            ctx.fill(bars, with: .color(.white.opacity(0.18)))
        }
        // the editable beats (exact song times, not rounded to frames)
        if let b = model.beats {
            let bx = { (sec: Double) in (CGFloat((sec - t.musicStart) * Double(t.fps)) - off) * ppf }
            var beats = Path(), bars = Path(), handles = Path()
            for (i, time) in b.times.enumerated() {
                let px = bx(time)
                guard px >= -6, px <= size.width + 6, i != model.selectedBeat else { continue }
                if b.downbeat[i] {
                    bars.addRect(CGRect(x: px - 0.75, y: 0, width: 1.5, height: Self.waveHeight + 2))
                    handles.addEllipse(in: CGRect(x: px - 4, y: 1, width: 8, height: 8))
                } else {
                    beats.addRect(CGRect(x: px - 0.5, y: 6, width: 1, height: Self.waveHeight - 4))
                    handles.addEllipse(in: CGRect(x: px - 2.5, y: 2, width: 5, height: 5))
                }
            }
            ctx.fill(beats, with: .color(.yellow.opacity(0.75)))
            ctx.fill(bars, with: .color(.orange))
            ctx.fill(handles, with: .color(.orange))
            if let i = model.selectedBeat, b.times.indices.contains(i) {
                let px = bx(b.times[i])
                ctx.fill(Path(CGRect(x: px - 1.25, y: 0, width: 2.5, height: Self.waveHeight + 2)), with: .color(.accentColor))
                ctx.fill(Path(ellipseIn: CGRect(x: px - 5.5, y: 0, width: 11, height: 11)), with: .color(.accentColor))
            }
        }

        // selected cut
        if let c = model.selectedCut, t.segments.indices.contains(c) {
            let cx = x(t.segments[c].startFrame)
            ctx.fill(Path(CGRect(x: cx - 1.5, y: 0, width: 3, height: size.height)), with: .color(.accentColor))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 5, y: rowTop + rowH / 2 - 5, width: 10, height: 10)), with: .color(.accentColor))
        }
    }
}

/// The playhead over the timeline (see `TimelineView`).
private struct TimelinePlayhead: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Canvas { ctx, size in
            guard model.timeline != nil else { return }
            let px = (CGFloat(model.playheadFrame) - model.offsetFrames) * model.pixelsPerFrame
            ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.red))
        }
    }
}

/// An AppKit view on top of the canvas for the events SwiftUI doesn't give us (scroll wheel,
/// modifier-aware drags, pinch, keys).
struct TimelineEventView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> EventView {
        let v = EventView()
        v.model = model
        return v
    }

    func updateNSView(_ v: EventView, context: Context) { v.model = model }

    final class EventView: NSView {
        weak var model: AppModel?

        private enum Drag {
            case cut(Int)
            case slip(Int, startX: CGFloat, base: Double)
            case beat(Int, base: BeatGrid)
            case allBeats(startX: CGFloat, base: BeatGrid)
            case scrub
        }
        private var drag: Drag?
        /// The undo gesture of the current mouse drag / scroll burst.
        private var dragGesture: Int?
        private var scrollGesture: Int?
        private var lastSnap: Int?
        private var scrollAccum: CGFloat = 0
        private var scrollEnd: Task<Void, Never>?

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }

        private var rowTop: CGFloat { TimelineView.waveHeight + 4 }
        private func frame(at x: CGFloat) -> CGFloat {
            guard let m = model else { return 0 }
            return m.offsetFrames + x / max(m.pixelsPerFrame, 0.0001)
        }
        private func xOf(_ f: Int) -> CGFloat {
            guard let m = model else { return 0 }
            return (CGFloat(f) - m.offsetFrames) * m.pixelsPerFrame
        }
        private func songTime(at x: CGFloat) -> Double {
            guard let t = model?.timeline else { return 0 }
            return t.musicStart + Double(frame(at: x)) / Double(t.fps)
        }
        private func xOf(songTime sec: Double) -> CGFloat {
            guard let t = model?.timeline else { return 0 }
            return xOf(0) + CGFloat((sec - t.musicStart) * Double(t.fps)) * (model?.pixelsPerFrame ?? 1)
        }
        /// The beat within 6 px of `x`.
        private func beat(near x: CGFloat) -> Int? {
            guard let b = model?.beats, let i = b.nearest(to: songTime(at: x)) else { return nil }
            return abs(xOf(songTime: b.times[i]) - x) <= 6 ? i : nil
        }

        /// The cut (index of the segment after it) within 5 px of `x`.
        private func cut(near x: CGFloat) -> Int? {
            guard let t = model?.timeline else { return nil }
            let hits = t.segments.indices.dropFirst().filter { abs(xOf(t.segments[$0].startFrame) - x) <= 5 }
            return hits.min { abs(xOf(t.segments[$0].startFrame) - x) < abs(xOf(t.segments[$1].startFrame) - x) }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseMoved(with e: NSEvent) {
            let p = convert(e.locationInWindow, from: nil)
            let onHandle = p.y >= rowTop ? cut(near: p.x) != nil : beat(near: p.x) != nil
            (onHandle ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }

        override func mouseExited(with e: NSEvent) { NSCursor.arrow.set() }

        override func mouseDown(with e: NSEvent) {
            window?.makeFirstResponder(self)
            guard let m = model, let t = m.timeline else { return }
            let p = convert(e.locationInWindow, from: nil)
            if p.y < rowTop {
                // music lane: beats
                m.selectedCut = nil
                m.selectedSegment = nil
                if let i = beat(near: p.x), let b = m.beats {
                    m.selectedBeat = i
                    if e.modifierFlags.contains(.shift) {
                        dragGesture = m.beginGesture("Shift Beats")
                        drag = .allBeats(startX: p.x, base: b)
                    } else {
                        dragGesture = m.beginGesture("Move Beat")
                        drag = .beat(i, base: b)
                    }
                    lastSnap = nil
                    return
                }
                m.selectedBeat = nil
                if e.clickCount == 2 {
                    m.insertBeat(at: songTime(at: p.x))
                    return
                }
                drag = .scrub
                m.seek(frame: Int(frame(at: p.x)))
                return
            }
            m.selectedBeat = nil
            if let c = cut(near: p.x) {
                m.selectedCut = c
                m.selectedSegment = nil
                dragGesture = m.beginGesture("Move Cut")
                drag = .cut(c)
                lastSnap = nil
                return
            }
            let f = Int(frame(at: p.x))
            m.selectedCut = nil
            if let i = t.segmentIndex(at: f) {
                m.selectedSegment = i
                if e.modifierFlags.contains(.command) {
                    dragGesture = m.beginGesture("Slip Clip")
                    drag = .slip(i, startX: p.x, base: t.segments[i].sourceStart)
                    return
                }
            } else {
                m.selectedSegment = nil
            }
            drag = .scrub
            m.seek(frame: f)
        }

        override func mouseDragged(with e: NSEvent) {
            guard let m = model, let base = m.gestureStart ?? m.timeline, let drag else { return }
            let p = convert(e.locationInWindow, from: nil)
            switch drag {
            case .cut(let c):
                var target = Int(frame(at: p.x).rounded())
                if !e.modifierFlags.contains(.option), let g = m.grid,
                   let snap = g.snap(target, radius: max(1, Int((8 / m.pixelsPerFrame).rounded()))) {
                    target = snap.frame
                    if lastSnap != snap.frame {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        lastSnap = snap.frame
                    }
                } else {
                    lastSnap = nil
                }
                let r = TimelineEdits.rollCut(base, before: c, to: target, durations: m.durations)
                let f = r.timeline.segments[c].startFrame
                m.updateGesture(r.timeline, seek: f)
                m.describeCut(f, clamped: r.clamped)
            case .slip(let i, let startX, let start):
                // like dragging the window along the clip: right = later part
                let seconds = Double((p.x - startX) / m.pixelsPerFrame) / Double(base.fps)
                let r = TimelineEdits.setSourceStart(base, segment: i, to: start + seconds, duration: m.durations[base.segments[i].clip])
                m.updateGesture(r.timeline, seek: base.segments[i].startFrame)
                m.describeSlip(r.timeline.segments[i], clamped: r.clamped)
            case .beat(let i, let grid):
                var target = songTime(at: p.x)
                // snap to a hit in the music unless ⌥
                if !e.modifierFlags.contains(.option), let music = m.music,
                   let onset = music.onsets.min(by: { abs($0 - target) < abs($1 - target) }),
                   abs(xOf(songTime: onset) - p.x) <= 8 {
                    target = onset
                    let key = Int(onset * 1000)
                    if lastSnap != key {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        lastSnap = key
                    }
                } else {
                    lastSnap = nil
                }
                m.updateBeats(grid.moving(i, to: target))
                m.describeBeat(i)
            case .allBeats(let startX, let grid):
                let dt = Double((p.x - startX) / m.pixelsPerFrame) / Double(base.fps)
                let shifted = grid.shifted(by: dt)
                m.updateBeats(shifted)
                m.flash(String(format: "All beats %+.0f ms", m.beatShift(shifted) * 1000))
            case .scrub:
                m.seek(frame: Int(frame(at: p.x)))
            }
        }

        override func mouseUp(with e: NSEvent) {
            if let g = dragGesture { model?.endGesture(g) }
            dragGesture = nil
            drag = nil
        }

        override func scrollWheel(with e: NSEvent) {
            guard let m = model, let t = m.timeline else { return }
            let p = convert(e.locationInWindow, from: nil)
            let dominant = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
            if e.modifierFlags.contains(.command) {
                zoom(by: exp(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.1)), around: p.x)
                return
            }
            // over the selected clip: slip it (scroll forward = later part of the clip)
            if let i = m.selectedSegment, t.segments.indices.contains(i), p.y >= rowTop, t.segmentIndex(at: Int(frame(at: p.x))) == i {
                scrollAccum += -dominant * (e.hasPreciseScrollingDeltas ? 1 : 12)
                let frames = Int(scrollAccum / 3)
                guard frames != 0 else { return }
                scrollAccum -= CGFloat(frames) * 3
                if !m.isGesturing || m.gestureID != scrollGesture { scrollGesture = m.beginGesture("Slip Clip") }
                let gesture = scrollGesture
                let cur = m.timeline!
                let r = TimelineEdits.slip(cur, segment: i, byFrames: frames, duration: m.durations[cur.segments[i].clip])
                m.updateGesture(r.timeline, seek: cur.segments[i].startFrame)
                m.describeSlip(r.timeline.segments[i], clamped: r.clamped)
                // one undo step per scroll burst
                scrollEnd?.cancel()
                scrollEnd = Task { @MainActor [weak m] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, let m else { return }
                    m.endGesture(gesture)
                }
                return
            }
            // otherwise pan when zoomed in
            m.fitTimeline = false
            let visible = bounds.width / m.pixelsPerFrame
            m.offsetFrames = min(max(0, m.offsetFrames - (e.scrollingDeltaX != 0 ? e.scrollingDeltaX : e.scrollingDeltaY) / m.pixelsPerFrame),
                                 max(0, CGFloat(t.frameCount) - visible))
        }

        override func magnify(with e: NSEvent) {
            zoom(by: 1 + e.magnification, around: convert(e.locationInWindow, from: nil).x)
        }

        private func zoom(by factor: CGFloat, around x: CGFloat) {
            guard let m = model, let t = m.timeline else { return }
            let anchor = frame(at: x)
            let minPPF = bounds.width / CGFloat(max(t.frameCount, 1))
            m.pixelsPerFrame = min(max(m.pixelsPerFrame * factor, minPPF), 40)
            m.fitTimeline = m.pixelsPerFrame <= minPPF + 0.0001
            let visible = bounds.width / m.pixelsPerFrame
            m.offsetFrames = min(max(0, anchor - x / m.pixelsPerFrame), max(0, CGFloat(t.frameCount) - visible))
        }

        override func keyDown(with e: NSEvent) {
            guard let m = model else { return super.keyDown(with: e) }
            let shift = e.modifierFlags.contains(.shift)
            switch e.keyCode {
            case 51, 117:  // ⌫ ⌦
                if m.selectedBeat != nil { m.deleteSelectedBeat() } else { super.keyDown(with: e) }
            case 123, 124:  // ← →
                let dir = e.keyCode == 123 ? -1 : 1
                if m.selectedBeat != nil {
                    if shift { m.shiftBeats(by: Double(dir) * 0.01) } else { m.nudgeSelectedBeat(by: Double(dir) * 0.01) }
                } else if m.selectedCut != nil {
                    m.nudgeCut(by: dir, toBeat: shift)
                } else if let i = m.selectedSegment, let t = m.timeline {
                    // move the selection
                    m.selectedSegment = min(max(0, i + dir), t.segments.count - 1)
                }
            case 43, 47:  // , .
                let dir = e.keyCode == 43 ? -1 : 1
                m.slipSelected(by: dir * (shift ? (m.timeline?.fps ?? 30) : 1))
            case 35:  // p
                if let i = m.selectedSegment { m.togglePin(i) }
            case 53:  // esc
                m.selectedSegment = nil
                m.selectedCut = nil
                m.selectedBeat = nil
            default:
                super.keyDown(with: e)
            }
        }
    }
}

/// The selected clip from start to end, with the part that plays highlighted; drag the highlight
/// to choose a different part.
struct SlipInspector: View {
    @Environment(AppModel.self) private var model
    @State private var dragBase: Double?
    @State private var dragGesture: Int?

    var body: some View {
        if let t = model.timeline, let i = model.selectedSegment, t.segments.indices.contains(i),
           let a = model.analysis(t.segments[i].clip) {
            let s = t.segments[i]
            let len = Double(s.frameCount) / Double(t.fps)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.info.name).lineLimit(1).truncationMode(.middle).font(.callout)
                    Text(String(format: "%.2f – %.2f s of %@", s.sourceStart, s.sourceStart + len, a.duration.clock))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button(s.pinned ? "Unpin" : "Pin") { model.togglePin(i) }
                        .controlSize(.small)
                        .help("Pinned clips (📌) are kept when you Shuffle (P)")
                }
                .frame(width: 190, alignment: .leading)
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    let x = { (sec: Double) in CGFloat(sec / a.duration) * w }
                    Canvas { ctx, size in
                        let tileW = h * CGFloat(a.info.aspect)
                        let n = max(1, Int((w / tileW).rounded(.up)))
                        for k in 0..<n {
                            let tx = CGFloat(k) * w / CGFloat(n)
                            if let img = model.thumbnail(s.clip, at: (Double(k) + 0.5) / Double(n) * a.duration) {
                                ctx.drawLayer { l in
                                    let r = CGRect(x: tx, y: 0, width: w / CGFloat(n) + 1, height: h)
                                    l.clip(to: Path(r))
                                    let iw = h * img.size.width / max(img.size.height, 1)
                                    l.draw(Image(nsImage: img), in: CGRect(x: r.midX - iw / 2, y: 0, width: iw, height: h))
                                }
                            }
                        }
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.45)))
                        let win = CGRect(x: x(s.sourceStart), y: 0, width: max(4, x(len)), height: h)
                        ctx.drawLayer { l in
                            l.clip(to: Path(win))
                            for k in 0..<n {
                                let tx = CGFloat(k) * w / CGFloat(n)
                                if let img = model.thumbnail(s.clip, at: (Double(k) + 0.5) / Double(n) * a.duration) {
                                    let iw = h * img.size.width / max(img.size.height, 1)
                                    let r = CGRect(x: tx, y: 0, width: w / CGFloat(n) + 1, height: h)
                                    l.drawLayer { tl in
                                        tl.clip(to: Path(r))
                                        tl.draw(Image(nsImage: img), in: CGRect(x: r.midX - iw / 2, y: 0, width: iw, height: h))
                                    }
                                }
                            }
                        }
                        ctx.stroke(Path(roundedRect: win.insetBy(dx: 1, dy: 1), cornerRadius: 3), with: .color(.accentColor), lineWidth: 2.5)
                        var cuts = Path()
                        for c in a.shotStarts { cuts.addRect(CGRect(x: x(c) - 0.5, y: 0, width: 1, height: h)) }
                        ctx.fill(cuts, with: .color(.yellow.opacity(0.9)))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard let tl = model.timeline else { return }
                            if dragBase == nil {
                                dragGesture = model.beginGesture("Slip Clip")
                                // grab the window, or centre it on the click
                                let clickT = Double(g.startLocation.x / w) * a.duration
                                dragBase = (clickT >= s.sourceStart && clickT <= s.sourceStart + len) ? s.sourceStart : clickT - len / 2
                            }
                            let start = dragBase! + Double(g.translation.width / w) * a.duration
                            let base = model.gestureStart ?? tl
                            let r = TimelineEdits.setSourceStart(base, segment: i, to: start, duration: a.duration)
                            model.updateGesture(r.timeline, seek: s.startFrame)
                            model.describeSlip(r.timeline.segments[i], clamped: r.clamped)
                        }
                        .onEnded { _ in
                            dragBase = nil
                            if let g = dragGesture { model.endGesture(g) }
                            dragGesture = nil
                        })
                    .help("Drag the highlighted part to choose which part of this clip plays. Yellow lines are shot changes.")
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        } else {
            HStack {
                Text("Click a shot in the timeline to choose which part of its clip plays.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxHeight: .infinity)
        }
    }
}
