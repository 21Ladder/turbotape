import SwiftUI
import TurboTapeKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MusicPanel()
                    Divider()
                    ClipsPanel()
                    Divider()
                    GenerateBar()
                }
                .frame(width: 440)
                Divider()
                PreviewPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ColorPanel()
                    .frame(width: 330)
            }
            Divider()
            if model.timeline != nil {
                TimelinePanel()
                Divider()
            }
            ExportBar()
        }
        .frame(minWidth: 1320, minHeight: 820)
        .onAppear {
            #if DEBUG
            SmokeTest.runIfRequested(model)
            #endif
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// A dashed drop target for files.
struct DropZone: View {
    let title: String
    let systemImage: String
    var compact = false
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.accentColor.opacity(0.08) : .clear))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: systemImage).font(compact ? .title3 : .largeTitle).foregroundStyle(.secondary)
                    Text(title).foregroundStyle(.secondary)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                onDrop(urls)
                return !urls.isEmpty
            } isTargeted: { targeted = $0 }
    }
}

extension Double {
    /// m:ss
    var clock: String {
        let s = Int(self.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
