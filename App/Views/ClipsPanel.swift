import SwiftUI
import TurboTapeKit

struct ClipsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Videos", systemImage: "film.stack").font(.headline)
                if !model.clips.isEmpty {
                    Text("\(model.clips.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                if model.analyzingCount > 0 {
                    ProgressView().controlSize(.small)
                    Text("analyzing \(model.analyzingCount)…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Videos or Folder…") { importing = true }
            }
            if model.clips.isEmpty {
                DropZone(title: "Drop videos or a folder here", systemImage: "rectangle.stack.badge.plus") { model.addClips($0) }
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(model.clips) { ClipCell(item: $0) }
                    }
                    .padding(.bottom, 8)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    model.addClips(urls)
                    return true
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.addClips(urls) }
        }
    }
}

struct ClipCell: View {
    @Environment(AppModel.self) private var model
    let item: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                if let img = model.poster(item.url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                }
                switch item.state {
                case .working(let p):
                    ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
                case .failed(let why):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(why)
                case .ready:
                    if !item.included {
                        Image(systemName: "eye.slash").foregroundStyle(.white)
                    }
                }
            }
            .frame(height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(item.included ? 1 : 0.4)
            HStack(spacing: 4) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let d = item.info?.duration { Text(d.clock).foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggleIncluded(item.url) }
        // drag onto a shot in the timeline to show this clip there
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .help(item.included ? "Click to leave this video out" : "Click to use this video again")
        .contextMenu {
            Button(item.included ? "Leave Out" : "Use") { model.toggleIncluded(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Remove", role: .destructive) { model.removeClip(item.url) }
        }
    }
}

struct GenerateBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Picker("Pace", selection: Binding(get: { model.pace }, set: { model.setPace($0) })) {
                ForEach(Pace.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .help("How often to cut: Chill ≈ every bar, Hype ≈ every beat")
            Spacer()
            Button {
                model.shuffle()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .disabled(model.timeline == nil)
            .help("New random picks; clips you edited (📌) stay (⌘R)")
            Button {
                model.generate()
            } label: {
                Label("Generate", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canGenerate)
            .help("Cut a new video to the music (⌘G)")
        }
        .padding(14)
    }
}
