import AppKit
import Observation
import SwiftUI

/// Making and opening effect packages from the app (see
/// docs/effect-packages.md, "Starting one from the app"): asking for a new
/// one's name, from the File menu or the effects library, or copying a
/// look's, then installing it and showing its kernel in Finder; or
/// installing one opened from Finder.
@MainActor
@Observable
final class NewEffectPackagePrompt {
    static let shared = NewEffectPackagePrompt()

    struct Problem {
        var title: String
        var message: String
    }

    /// A package opened from Finder that would replace those installed.
    struct Replacement {
        var url: URL
        var package: EffectPackage
        var existing: [URL]
    }

    var isAsking = false
    var name = ""
    /// Why the last one couldn't be made, opened or installed.
    var problem: Problem?
    /// What opening one did.
    var notice: String?
    var replacement: Replacement?

    private func failed(_ title: String, _ error: Error) {
        problem = Problem(title: title, message: error.localizedDescription)
    }

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
                failed("The Effect Package Wasn't Made", error)
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
                failed("The Effect Package Wasn't Made", error)
            }
        }
    }

    /// Installs a package opened from Finder: copied into the Effects folder
    /// and installed at once, or once it is confirmed to replace one there,
    /// at the next launch.
    func open(_ url: URL) {
        let opening: (EffectPackage, EffectPackageStore.Opening)
        do {
            opening = try EffectPackageStore.opening(url)
        } catch {
            return failed("“\(url.deletingPathExtension().lastPathComponent)” Can't Be Used", error)
        }
        let package = opening.0
        let installed = "“\(package.name)” is installed: it is in the effects library under \(package.category.name)."
        switch opening.1 {
        case .alreadyInstalled:
            notice = installed
        case .install:
            Task {
                do {
                    _ = try await EffectPackageStatus.shared.install(try EffectPackageStore.copyIn(url))
                    notice = installed
                } catch {
                    failed("“\(package.name)” Wasn't Installed", error)
                }
            }
        case .replace(let existing):
            replacement = Replacement(url: url, package: package, existing: existing)
        }
    }

    /// Replaces the installed packages the last opened one clashes with.
    func replace() {
        guard let replacement else { return }
        self.replacement = nil
        do {
            try EffectPackageStore.copyIn(replacement.url, replacing: replacement.existing)
            notice = "“\(replacement.package.name)” replaces the package installed before when the app is opened again."
        } catch {
            failed("“\(replacement.package.name)” Wasn't Installed", error)
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
            .alert(prompt.problem?.title ?? "", isPresented: Binding(get: { prompt.problem != nil }, set: { if !$0 { prompt.problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(prompt.problem?.message ?? "")
            }
            .alert("Effect Package", isPresented: Binding(get: { prompt.notice != nil }, set: { if !$0 { prompt.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(prompt.notice ?? "")
            }
            .alert(
                "Replace the Installed Package?",
                isPresented: Binding(get: { prompt.replacement != nil }, set: { if !$0 { prompt.replacement = nil } })
            ) {
                Button("Replace", role: .destructive) { prompt.replace() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The Effects folder has a package with the folder name or ID of “\(prompt.replacement?.package.name ?? "")”. Replacing removes it; the new one is used when the app is opened again.")
            }
    }
}

extension View {
    /// Where New Effect Package asks for its name.
    func newEffectPackagePrompt() -> some View {
        modifier(NewEffectPackageAlerts())
    }
}
