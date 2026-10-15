import SwiftUI
import TurboTapeKit

struct MusicPanel: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var customLength = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Music", systemImage: "music.note").font(.headline)
                Spacer()
                Button(model.musicURL == nil ? "Choose…" : "Replace…") { importing = true }
            }
            if let url = model.musicURL {
                HStack(spacing: 6) {
                    Text(url.deletingPathExtension().lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    switch model.musicState {
                    case .working: ProgressView().controlSize(.small)
                    case .failed(let why): Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(2)
                    default:
                        if let m = model.music {
                            Text(String(format: "%.0f BPM · %@", m.bpm, m.duration.clock)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .font(.callout)
                if model.music != nil {
                    WaveformView().frame(height: 56)
                    lengthPicker
                }
            } else {
                DropZone(title: "Drop a song here", systemImage: "music.note.list") { urls in
                    if let u = urls.first { model.setMusic(u) }
                }
                .frame(height: 110)
            }
        }
        .padding(14)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.musicURL != nil, let u = urls.first else { return false }
            model.setMusic(u)
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            if case .success(let u) = result { model.setMusic(u) }
        }
    }

    private var lengthPicker: some View {
        HStack {
            Picker("Length", selection: Binding(
                get: { customLength ? -1 : model.length },
                set: { v in
                    customLength = v < 0
                    if v > 0 { model.setLength(v) }
                })) {
                Text("15 s").tag(15.0)
                Text("30 s").tag(30.0)
                Text("60 s").tag(60.0)
                Text("Custom").tag(-1.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if customLength {
                Stepper(value: Binding(get: { model.length }, set: { model.setLength($0) }), in: 5...180, step: 5) {
                    Text("\(Int(model.length)) s").monospacedDigit()
                }
                .fixedSize()
            }
        }
    }
}

/// The whole song: waveform, bar lines and the excerpt, which can be dragged along the song.
struct WaveformView: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Canvas { ctx, size in
                guard let m = model.music else { return }
                let x = { (t: Double) in CGFloat(t / m.duration) * size.width }
                if let (s, e) = model.excerpt {
                    ctx.fill(Path(roundedRect: CGRect(x: x(s), y: 0, width: x(e) - x(s), height: size.height), cornerRadius: 4),
                             with: .color(.accentColor.opacity(0.22)))
                }
                let n = m.waveform.count
                var path = Path()
                let cols = n > 0 ? Int(size.width) : 0
                for c in 0..<cols {
                    let a = c * n / cols, b = max(a + 1, (c + 1) * n / cols)
                    let v = CGFloat(m.waveform[min(a, n - 1)..<min(b, n)].max() ?? 0)
                    let h = max(1, v * size.height * 0.9)
                    path.addRect(CGRect(x: CGFloat(c), y: (size.height - h) / 2, width: 1, height: h))
                }
                ctx.fill(path, with: .color(.secondary.opacity(0.7)))
                var bars = Path()
                for d in m.downbeats { bars.addRect(CGRect(x: x(d), y: size.height - 4, width: 0.5, height: 4)) }
                ctx.fill(bars, with: .color(.secondary.opacity(0.6)))
                if let (s, e) = model.excerpt {
                    ctx.stroke(Path(roundedRect: CGRect(x: x(s), y: 0.5, width: x(e) - x(s), height: size.height - 1), cornerRadius: 4),
                               with: .color(.accentColor), lineWidth: 1.5)
                }
            }
            // its own view, so playback redraws the playhead only, not the waveform
            .overlay { WaveformPlayhead().allowsHitTesting(false) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard let m = model.music else { return }
                    if dragStart == nil {
                        // grab the excerpt where it was clicked, or jump to the click
                        let t = Double(g.startLocation.x / w) * m.duration
                        if let (s, e) = model.excerpt, t >= s, t <= e { dragStart = s } else { dragStart = t }
                    }
                    model.setMusicStart(dragStart! + Double(g.translation.width / w) * m.duration, final: false)
                }
                .onEnded { _ in
                    dragStart = nil
                    model.setMusicStart(model.musicStart, final: true)
                })
            .help("Drag to choose which part of the song to use (snaps to bars)")
        }
    }
}

/// The playhead over the song waveform (see `WaveformView`).
private struct WaveformPlayhead: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Canvas { ctx, size in
            // the playing timeline's start, not the excerpt being dragged (not re-cut yet)
            guard let m = model.music, let t = model.timeline else { return }
            let p = t.musicStart + Double(model.playheadFrame) / Double(t.fps)
            ctx.fill(Path(CGRect(x: CGFloat(p / m.duration) * size.width, y: 0, width: 1, height: size.height)), with: .color(.red))
        }
    }
}
