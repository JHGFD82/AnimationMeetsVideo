import CoreMedia
import Foundation

/// A saved set of effects, shared by every project (see docs/effects.md,
/// "Copying and presets").
struct EffectPreset: Identifiable, Equatable, Sendable {
    /// The file's name without its extension, which is what ties the
    /// preset to its file.
    var id: String
    var name: String
    /// The effects, with keyframe times from the start of the clip they
    /// were saved from (`origin` is zero).
    var bundle: EffectBundle
    var url: URL
}

/// A preset file that can't be read, and why.
struct PresetProblem: Identifiable, Equatable, Sendable {
    var url: URL
    var message: String

    var id: URL { url }
}

struct PresetLibrary: Equatable, Sendable {
    var presets: [EffectPreset] = []
    var problems: [PresetProblem] = []
}

/// What a preset file holds.
struct PresetFile: Codable {
    static let currentVersion = 1

    var formatVersion: Int
    var name: String
    var effects: [ProjectFile.EffectEntry]

    /// What a preset file may contain, as strict as a project's, made at
    /// each read as a project's is.
    static var shape: JSONShape {
        .object(JSONObjectShape(fields: [
            .required("formatVersion", .integer), .required("name", .string),
            .required("effects", ProjectFile.ShapeKit.effects(extra: [.optional("inputName", .string), .optional("againstName", .string)], allowingMissing: true)),
        ]))
    }
}

enum PresetStore {
    static let fileExtension = "json"

    /// `~/Library/Application Support/AnimationMeetsVideo/Presets/`.
    static var defaultFolder: URL {
        URL.applicationSupportDirectory
            .appending(path: "AnimationMeetsVideo", directoryHint: .isDirectory)
            .appending(path: "Presets", directoryHint: .isDirectory)
    }

    /// Saves effects as a preset called `name`, in a file of its own.
    @discardableResult
    static func save(_ bundle: EffectBundle, named name: String, in folder: URL = defaultFolder) throws -> EffectPreset {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = freeID(for: name, in: folder)
        let url = fileURL(id, in: folder)
        // Times are kept from the start of the clip they came from.
        let shifted = EffectBundle(
            effects: bundle.effects.map { item in
                var item = item
                for c in item.effect.controls.indices {
                    item.effect.controls[c].number = item.effect.controls[c].number.shifted(by: CMTimeSubtract(.zero, bundle.origin))
                }
                return item
            },
            origin: .zero
        )
        try write(PresetFile(name: name, bundle: shifted), to: url)
        return EffectPreset(id: id, name: name, bundle: shifted, url: url)
    }

    /// Writes the recipes (`LookRecipes`) into the folder as presets, once
    /// for each version of them, so a recipe the person deleted doesn't come
    /// back. One whose name a preset already has is left out, so nothing of
    /// theirs is overwritten. Returns how many were written.
    @discardableResult
    static func installRecipes(in folder: URL = defaultFolder, defaults: UserDefaults = .standard) -> Int {
        guard defaults.integer(forKey: Preferences.recipesInstalled) < LookRecipes.version else { return 0 }
        let taken = Set(load(from: folder).presets.map(\.name))
        var written = 0
        for recipe in LookRecipes.all where !taken.contains(recipe.name) {
            if (try? save(recipe.bundle, named: recipe.name, in: folder)) != nil { written += 1 }
        }
        defaults.set(LookRecipes.version, forKey: Preferences.recipesInstalled)
        return written
    }

    /// Every preset in the folder, and each file that couldn't be read.
    static func load(from folder: URL = defaultFolder) -> PresetLibrary {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return PresetLibrary()
        }
        var library = PresetLibrary()
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        where url.pathExtension == fileExtension && !url.lastPathComponent.hasPrefix(".") {
            do {
                library.presets.append(try read(url))
            } catch {
                library.problems.append(PresetProblem(url: url, message: error.localizedDescription))
            }
        }
        return library
    }

    /// Reads one preset file, as strictly as a project's.
    static func read(_ url: URL) throws -> EffectPreset {
        let data = try Data(contentsOf: url)
        let id = url.deletingPathExtension().lastPathComponent
        do {
            let header = (try? JSONDecoder().decode(ProjectFileHeader.self, from: data))?.formatVersion
            guard header == PresetFile.currentVersion else {
                throw PresetError("The preset has format version \(header.map(String.init) ?? "none"); this app reads version \(PresetFile.currentVersion).")
            }
            try StrictJSON.validate(data, against: PresetFile.shape)
            let file = try JSONDecoder().decode(PresetFile.self, from: data)
            return EffectPreset(id: id, name: file.name, bundle: file.bundle, url: url)
        } catch let problem as JSONShapeError {
            throw PresetError("The preset can't be used. \(problem.sentence)")
        } catch let problem as DecodingError {
            throw PresetError("The preset can't be used. \(problem.sentenceForProject)")
        }
    }

    /// Gives a preset a new name, and its file the matching name.
    @discardableResult
    static func rename(_ preset: EffectPreset, to name: String, in folder: URL = defaultFolder) throws -> EffectPreset {
        let id = freeID(for: name, in: folder, except: preset.id)
        let url = fileURL(id, in: folder)
        try write(PresetFile(name: name, bundle: preset.bundle), to: url)
        if url != preset.url { try? FileManager.default.removeItem(at: preset.url) }
        return EffectPreset(id: id, name: name, bundle: preset.bundle, url: url)
    }

    static func delete(_ preset: EffectPreset) throws {
        try FileManager.default.removeItem(at: preset.url)
    }

    // MARK: Files

    /// The file of the preset with this ID.
    static func fileURL(_ id: String, in folder: URL = defaultFolder) -> URL {
        folder.appending(path: "\(id).\(fileExtension)")
    }

    /// A file name for `name` that no other preset uses: the name with
    /// characters a file can't have taken out, numbered if it's taken.
    private static func freeID(for name: String, in folder: URL, except own: String? = nil) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let base = cleaned.isEmpty ? "Preset" : cleaned
        var candidate = base
        var number = 2
        while candidate != own, FileManager.default.fileExists(atPath: fileURL(candidate, in: folder).path) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    private static func write(_ file: PresetFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(file)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}

private struct PresetError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension PresetFile {
    init(name: String, bundle: EffectBundle) {
        formatVersion = Self.currentVersion
        self.name = name
        effects = bundle.effects.map { item in
            var entry = ProjectFile.EffectEntry(item.effect)
            entry.pasteChanges = nil
            entry.input = nil
            entry.inputName = item.inputName
            entry.againstName = item.againstName
            return entry
        }
    }

    /// The effects of the file, with keyframe times from zero.
    var bundle: EffectBundle {
        EffectBundle(
            effects: effects.compactMap { entry in
                guard let effect = entry.effect else { return nil }
                var bare = effect
                bare.input = nil
                bare.pasteChanges = []
                return EffectBundle.Effect(effect: bare, inputName: entry.inputName, againstName: entry.againstName)
            },
            origin: .zero
        )
    }
}
