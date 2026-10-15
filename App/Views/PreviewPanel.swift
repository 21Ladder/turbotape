import AVKit
import SwiftUI
import TurboTapeKit

struct PreviewPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                PlayerView(player: model.player)
                if let img = model.slipPreview {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .clipped()
                        .allowsHitTesting(false)
                }
                if model.timeline == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled").font(.system(size: 40))
                        Text(hint).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .top) {
                if let s = model.status {
                    Text(s).font(.callout.monospacedDigit()).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.status)
            if let t = model.timeline {
                HStack(spacing: 12) {
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Text("\(t.seconds(model.playheadFrame).clock) / \(t.duration.clock)").monospacedDigit().foregroundStyle(.secondary)
                    Text("· \(t.segments.count) shots").foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    private var hint: String {
        if model.musicURL == nil { return "Choose a song and add some videos" }
        if model.clips.isEmpty { return "Now add some videos" }
        if !model.canGenerate { return "Analyzing…" }
        return "Press Generate"
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

struct ExportBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            Text(ExportPreset.shortsReels.name).font(.callout)
            Text("H.264 · 30 fps · 12 Mbps · AAC · −14 LUFS").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let p = model.exportProgress {
                ProgressView(value: p).frame(width: 220)
                Text("\(Int(p * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                Button("Cancel") { model.cancelExport() }
            } else {
                if let url = model.lastExport {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label(url.lastPathComponent, systemImage: "checkmark.circle.fill").lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .help("Reveal in Finder")
                }
                Button("Export…") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("e")
                    .disabled(model.timeline == nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = model.suggestedExportName
        panel.canCreateDirectories = true
        // the real ~/Movies (inside the sandbox, the home directory is the container)
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let dir = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Movies/TurboTape", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.export(to: url)
    }
}
