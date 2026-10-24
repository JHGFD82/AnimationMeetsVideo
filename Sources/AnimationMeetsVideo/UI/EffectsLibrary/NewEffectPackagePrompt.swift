import AppKit
import Observation
import SwiftUI

/// Making effect packages from the app (see docs/effect-packages.md,
/// "Starting one from the app"): asking for a new one's name, from the File
/// menu or the effects library, or copying a look's; then installing it and
/// showing its kernel in Finder.
@MainActor
@Observable
final class NewEffectPackagePrompt {
    static let shared = NewEffectPackagePrompt()

    var isAsking = false
    var name = ""
    /// Why the last one couldn't be made or installed.
    var error: String?

    func ask() {
        name = "My Look"
        isAsking = true
    }

    func make() {
        let name = name
        Task {
            do {
                let url = try EffectPackageStore.makePackage(named: name)
                _ = try await EffectPackageStatus.shared.install(url)
                NSWorkspace.shared.activateFileViewerSelecting([url.appending(path: "kernel.metal")])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Copies `package` as a new one in the Effects folder, installs it,
    /// and shows its kernel in Finder.
    func copy(_ package: EffectPackage) {
        Task {
            do {
                let url = try EffectPackageStore.copyPackage(package)
                _ = try await EffectPackageStatus.shared.install(url)
                NSWorkspace.shared.activateFileViewerSelecting([url.appending(path: package.kernelFile)])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The Effects folder in Finder, made first if there is none yet.
    static func showEffectsFolder() {
        let folder = EffectPackageStore.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// The prompt's alerts, on the editor window.
private struct NewEffectPackageAlerts: ViewModifier {
    @Bindable var prompt = NewEffectPackagePrompt.shared

    func body(content: Content) -> some View {
        content
            .alert("New Effect Package", isPresented: $prompt.isAsking) {
                TextField("Name", text: $prompt.name)
                Button("Make") { prompt.make() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A starting package is made in the Effects folder and added to the library. Edit its effect.json and kernel.metal, then open the app again to see the changes.")
            }
            .alert("The Effect Package Wasn't Made", isPresented: Binding(get: { prompt.error != nil }, set: { if !$0 { prompt.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(prompt.error ?? "")
            }
    }
}

extension View {
    /// Where New Effect Package asks for its name.
    func newEffectPackagePrompt() -> some View {
        modifier(NewEffectPackageAlerts())
    }
}
