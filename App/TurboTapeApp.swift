import SwiftUI
import TurboTapeKit

@main
struct TurboTapeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("TurboTape", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoTitle) { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button(model.redoTitle) { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandMenu("Edit Video") {
                Button("Generate") { model.generate() }
                    .keyboardShortcut("g")
                    .disabled(!model.canGenerate)
                Button("Shuffle") { model.shuffle() }
                    .keyboardShortcut("r")
                    .disabled(!model.canGenerate)
                Button("Shuffle All (ignore pins)") { model.shuffle(all: true) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(!model.canGenerate)
                Divider()
                Button("Re-snap All Cuts to the Beat") { model.reSnapAll() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(model.timeline == nil)
                Divider()
                Picker("Pace", selection: Binding(get: { model.pace }, set: { model.setPace($0) })) {
                    ForEach(Pace.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }
}
