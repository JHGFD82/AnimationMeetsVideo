import SwiftUI

@main
struct AnimationMeetsVideoApp: App {
    @State private var project = EditingProject.demo

    var body: some Scene {
        WindowGroup("Animation Meets Video") {
            EditorView(project: $project)
                .frame(minWidth: 1_100, minHeight: 700)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    project = EditingProject.empty
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
