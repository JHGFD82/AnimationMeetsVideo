import CoreImage
import Foundation
import Observation

/// An effect package that can't be used, and why.
struct EffectPackageProblem: Identifiable, Equatable, Sendable {
    var url: URL
    var message: String

    var id: URL { url }
}

/// What the effects library shows of the packages' kernels: which don't
/// compile, and why, once they have been compiled in the background after
/// launch. The packages that couldn't be read or installed are the
/// registry's `problems`.
@MainActor
@Observable
final class EffectPackageStatus {
    static let shared = EffectPackageStatus()

    /// Why each package's kernel doesn't compile, by package ID.
    private(set) var kernelProblems: [String: String]
    /// Bumped as a package is installed while the app runs, so what lists
    /// the effects (read from the registry, which isn't observed) does again.
    private(set) var revision = 0

    init(kernelProblems: [String: String] = [:]) {
        self.kernelProblems = kernelProblems
    }

    /// Reads the package at `url`, adds it to the registry beside those
    /// installed, and compiles its kernel. Throws why it can't be used.
    func install(_ url: URL) async throws -> EffectPackage {
        let package = try EffectPackageStore.read(url)
        try EffectRegistry.add(package)
        revision += 1
        let problem = await Task.detached(priority: .userInitiated) { PackageKernels.problem(for: package) }.value
        kernelProblems[package.id] = problem
        return package
    }

    /// Compiles each package's kernel away from the main thread, then
    /// says which failed.
    func compileKernels(of packages: [EffectPackage]) async {
        kernelProblems = await Task.detached(priority: .utility) {
            var problems: [String: String] = [:]
            for package in packages {
                if let problem = PackageKernels.problem(for: package) { problems[package.id] = problem }
            }
            return problems
        }.value
    }
}

struct EffectPackageLibrary: Sendable {
    var packages: [EffectPackage] = []
    var problems: [EffectPackageProblem] = []
}

/// Reads effect packages (see docs/effect-packages.md) from the person's
/// Effects folder, as strictly as a project, and installs them in the
/// `EffectRegistry` at launch.
enum EffectPackageStore {
    /// `~/Library/Application Support/AnimationMeetsVideo/Effects/`, beside
    /// the Presets folder.
    static var defaultFolder: URL {
        URL.applicationSupportDirectory
            .appending(path: "AnimationMeetsVideo", directoryHint: .isDirectory)
            .appending(path: "Effects", directoryHint: .isDirectory)
    }

    static let manifestName = "effect.json"

    /// The package type `Packaging/Info.plist` declares for `.amveffect`,
    /// so Finder shows one as a single item and opens it in the app.
    static let packageTypeIdentifier = "com.jhgfd.animationmeetsvideo.effect"

    /// The packages that ship with the app, in its resource bundle. In the
    /// app that is in Contents/Resources (scripts/build-app.sh puts it
    /// there); built by SwiftPM, beside the executable.
    static var builtInFolder: URL? {
        let name = "AnimationMeetsVideo_AnimationMeetsVideo.bundle"
        if let resources = Bundle.main.resourceURL, let bundle = Bundle(url: resources.appending(path: name)) {
            return bundle.url(forResource: "Effects", withExtension: nil)
        }
        return Bundle.module.url(forResource: "Effects", withExtension: nil)
    }

    /// The packages that ship with the app. One that can't be read is a
    /// mistake in the app, logged and left out.
    static func loadBuiltIn() -> EffectPackageLibrary {
        guard let folder = builtInFolder else {
            NSLog("The app's effect packages are missing.")
            return EffectPackageLibrary()
        }
        let library = load(from: folder, builtIn: true)
        for problem in library.problems {
            NSLog("The built-in effect package \(problem.url.lastPathComponent) can't be used: \(problem.message)")
        }
        return library
    }

    /// Reads the person's packages and installs them beside the built-in
    /// effects. Called once at launch, before a project is opened.
    static func installAtLaunch(from folder: URL = defaultFolder) {
        let library = load(from: folder)
        for problem in library.problems {
            NSLog("The effect package \(problem.url.lastPathComponent) can't be used: \(problem.message)")
        }
        EffectRegistry.install(library.packages, problems: library.problems)
        // Compiled now rather than at first use, so a kernel's mistake shows
        // up at once and the first frame of a look doesn't wait on it.
        let packages = EffectRegistry.current.effects.compactMap(\.package)
        Task { @MainActor in await EffectPackageStatus.shared.compileKernels(of: packages) }
    }

    /// Every package in the folder, and each that couldn't be read.
    /// `builtIn` packages, which ship with the app, may take IDs without a
    /// dot.
    static func load(from folder: URL, builtIn: Bool = false) -> EffectPackageLibrary {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return EffectPackageLibrary()
        }
        var library = EffectPackageLibrary()
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        where url.pathExtension == EffectPackage.fileExtension && !url.lastPathComponent.hasPrefix(".") {
            do {
                library.packages.append(try read(url, builtIn: builtIn))
            } catch {
                library.problems.append(EffectPackageProblem(url: url, message: error.localizedDescription))
            }
        }
        return library
    }

    /// Reads one package folder.
    static func read(_ url: URL, builtIn: Bool = false) throws -> EffectPackage {
        let manifest = url.appending(path: manifestName)
        guard let data = try? Data(contentsOf: manifest) else {
            throw EffectPackageError("The package has no \(manifestName).")
        }
        if let problem = JSONFile.versionMismatch(in: data, expecting: EffectPackage.formatVersion, noun: "package") {
            throw EffectPackageError(problem)
        }
        do {
            try StrictJSON.validate(data, against: shape)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw JSONShapeError(message: "Expected an object", path: "")
            }
            return try Reader(url: url, builtIn: builtIn, manifest: data).package(from: object)
        } catch let problem as JSONShapeError {
            throw EffectPackageError("The package can't be used. \(problem.sentence)")
        }
    }

    // MARK: Making one

    /// The ID a package made from the app takes: `user.` and its name in
    /// camel case, of its letters and digits ("My Glow" is `user.myGlow`).
    /// Nil for a name with no letter to start it.
    static func userID(for name: String) -> String? {
        camelCase(name).map { "user.\($0)" }
    }

    private static func camelCase(_ name: String) -> String? {
        let words = name.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        guard let first = words.first, first.first?.isLetter == true else { return nil }
        return first.prefix(1).lowercased() + first.dropFirst() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// Writes a new package called `name` into `folder`: a Tint, as in the
    /// guide (docs/effect-packages.md, "Writing one by hand"), to change
    /// into something else. Returns its folder.
    static func makePackage(named name: String, in folder: URL = defaultFolder) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = userID(for: name), let camel = camelCase(name) else {
            throw EffectPackageError("Give it a name that starts with a letter.")
        }
        guard EffectRegistry.current.effect(named: id) == nil else {
            throw EffectPackageError("An effect called \"\(id)\" is already installed.")
        }
        let url = folder.appending(path: "\(name).\(EffectPackage.fileExtension)", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw EffectPackageError("The Effects folder already has a package called \"\(name)\".")
        }
        // Kernel functions are Metal names, so this one can't be a Metal
        // word such as `half`.
        let function = "user" + camel.prefix(1).uppercased() + camel.dropFirst()
        let manifest = """
        {
          "formatVersion": 1,
          "id": "\(id)",
          "version": 1,
          "name": \(String(data: try JSONEncoder().encode(name), encoding: .utf8)!),
          "category": "recolor",
          "symbol": "wand.and.stars",
          "kernel": { "file": "kernel.metal", "function": "\(function)", "type": "color" },
          "controls": [
            { "id": "tint", "name": "Tint", "type": "color", "default": [1, 0.6, 0.2] },
            { "id": "strength", "name": "Strength", "type": "number", "default": 100, "range": [0, 200], "unit": "%" }
          ],
          "amount": true,
          "arguments": ["tint", "strength / 100"]
        }

        """
        let kernel = """
        // Each pixel's tones multiplied by a color, `strength` of the way: a
        // starting point. See docs/effect-packages.md for what a package can
        // say, and the looks that ship for kernels of every kind.
        extern "C" [[stitchable]] float4 \(function)(coreimage::sample_t s, float space, float4 tint, float strength, float amount) {
            float3 t = toTones(straight(s), space);
            float3 tinted = t * mix(float3(1.0), tint.rgb, strength);
            return mixed(s, fromTones(tinted, space), amount);
        }

        """
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try manifest.write(to: url.appending(path: manifestName), atomically: true, encoding: .utf8)
        try kernel.write(to: url.appending(path: "kernel.metal"), atomically: true, encoding: .utf8)
        return url
    }

    /// Copies `package` into `folder` as a new one to change: "Twirl Copy"
    /// (or "Twirl Copy 2", and so on, for a name already taken), its ID from
    /// that name as a made one's, version 1, its controls and kernel as they
    /// were. Returns its folder.
    static func copyPackage(_ package: EffectPackage, in folder: URL = defaultFolder) throws -> URL {
        let taken = { (name: String) in
            FileManager.default.fileExists(atPath: folder.appending(path: "\(name).\(EffectPackage.fileExtension)").path)
                || userID(for: name).map { EffectRegistry.current.effect(named: $0) != nil } ?? true
        }
        var name = "\(package.name) Copy"
        var number = 2
        while taken(name) {
            name = "\(package.name) Copy \(number)"
            number += 1
        }
        guard let id = userID(for: name) else { throw EffectPackageError("\(package.name) can't be copied: its name has no letter to start an ID.") }
        let url = folder.appending(path: "\(name).\(EffectPackage.fileExtension)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: package.url, to: url)
        let manifest = url.appending(path: manifestName)
        try String(contentsOf: manifest, encoding: .utf8).renamed(id: (package.id, id), name: (package.name, name)).write(
            to: manifest, atomically: true, encoding: .utf8
        )
        // Read back, so a manifest the text edit missed is written whole.
        if let copy = try? read(url), copy.id == id, copy.name == name, copy.version == 1 { return url }
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] ?? [:]
        json["id"] = id
        json["name"] = name
        json["version"] = 1
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: manifest)
        return url
    }

    // MARK: Opening one

    /// What opening the package at `url` from Finder does.
    enum Opening: Equatable {
        /// Copied into the Effects folder at `destination` and installed.
        case install(destination: URL)
        /// It is the one installed, in the Effects folder.
        case alreadyInstalled
        /// Another package has its folder name or ID: these folders, which
        /// replacing it removes.
        case replace(existing: [URL])
    }

    /// Reads the package at `url` and says what opening it does, against
    /// the registry in use and the packages in `folder`. Throws why it
    /// can't be used; one can't replace a look of the app's, whose IDs have
    /// no dot, as every other package's must.
    static func opening(_ url: URL, into folder: URL = defaultFolder) throws -> (EffectPackage, Opening) {
        let package = try read(url)
        let destination = folder.appending(path: url.lastPathComponent, directoryHint: .isDirectory)
        let installed = EffectRegistry.current.effect(named: package.id)?.package
        if url.standardizedFileURL == destination.standardizedFileURL {
            return (package, installed?.url.standardizedFileURL == destination.standardizedFileURL ? .alreadyInstalled : .install(destination: destination))
        }
        var existing: [URL] = []
        if FileManager.default.fileExists(atPath: destination.path) { existing.append(destination) }
        if let installed, !existing.contains(where: { $0.standardizedFileURL == installed.url.standardizedFileURL }) {
            existing.append(installed.url)
        }
        return (package, existing.isEmpty ? .install(destination: destination) : .replace(existing: existing))
    }

    /// Copies the package at `url` into `folder`, first removing
    /// `replacing`. Returns where it is.
    @discardableResult
    static func copyIn(_ url: URL, into folder: URL = defaultFolder, replacing: [URL] = []) throws -> URL {
        let destination = folder.appending(path: url.lastPathComponent, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in replacing { try FileManager.default.removeItem(at: old) }
        if url.standardizedFileURL != destination.standardizedFileURL {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return destination
    }

    // MARK: Shape

    /// The units a control may have, as written in a package and as shown.
    static let units: [String: String] = ["%": "%", "°": "°", "px": " px", "s": " s", "×": "×", "/s": " /s", "turns/s": " turns/s", "frames": " frames"]

    static let categories: [EffectCategory] = [.correction, .blur, .keying, .light, .stylize, .recolor, .noise, .distortion]

    /// What effect.json may contain.
    static let shape: JSONShape = {
        typealias O = JSONObjectShape
        func object(_ fields: [O.Field]) -> JSONObjectShape { JSONObjectShape(fields: fields) }
        let unit = JSONShape.choice(units.keys.sorted(), noun: "unit")
        let common: [O.Field] = [.required("id", .string), .required("name", .string), .required("type", .string)]
        let controls: [String: JSONObjectShape] = [
            "number": object(common + [
                .required("default", .number), .optional("range", .numbers(count: 2)), .optional("unit", unit),
                .optional("step", .number), .optional("whole", .bool), .optional("rate", .bool),
            ]),
            "vector": object(common + [
                .required("components", .array(.string)), .required("default", .numbers(count: nil)),
                .optional("range", .numbers(count: 2)), .optional("unit", unit), .optional("step", .number),
            ]),
            "point": object(common + [.optional("default", .numbers(count: 2))]),
            "color": object(common + [.required("default", .numbers(count: nil))]),
            "choice": object(common + [
                .required("options", .array(.object(object([.required("id", .string), .required("name", .string)])))),
                .required("default", .string),
            ]),
            // Where the standard Amount goes, when not last.
            "amount": object([.required("type", .string)]),
        ]
        return .object(object([
            .required("formatVersion", .integer), .required("id", .string), .required("version", .integer),
            .required("name", .string),
            .required("category", .choice(categories.map(\.rawValue), noun: "category")),
            .required("symbol", .string),
            .required("kernel", .object(object([
                .required("file", .string), .required("function", .string),
                .required("type", .choice(EffectPackage.KernelType.allCases.map(\.rawValue), noun: "kernel type")),
            ]))),
            .required("controls", .array(.tagged(key: "type", noun: "control type", controls))),
            .optional("amount", .bool),
            .required("arguments", .array(.string)),
            .optional("generates", .bool), .optional("changesEveryFrame", .bool),
            .optional("dependsOnPixelSize", .bool), .optional("flashes", .any),
            .optional("reach", .string),
            .optional("input", .choice(EffectPackage.Edges.allCases.map(\.rawValue), noun: "input")),
            .optional("pictures", .array(.object(object([
                .required("id", .string),
                .required("from", .choice(EffectPackage.Picture.Source.allCases.map(\.rawValue), noun: "picture source")),
                .optional("delay", .string), .optional("missing", .choice(["transparent", "picture"], noun: "missing picture")),
                .optional("ahead", .string),
            ])))),
            .optional("drawsWhen", .string),
            .optional("repeat", .object(object([
                .required("count", .string), .optional("index", .string),
                .optional("countWhilePlaying", .string), .optional("indexWhilePlaying", .string),
                .optional("start", .choice(["picture", "clear"], noun: "start")),
            ]))),
            .optional("after", .array(.object(object([
                .required("filter", .string), .optional("when", .string), .optional("parameters", .any),
                .optional("input", .choice(EffectPackage.Edges.allCases.map(\.rawValue), noun: "input")),
            ])))),
        ]))
    }()

    // MARK: Reading

    /// Turns a checked effect.json into a package, throwing the first
    /// problem the shape can't catch, with where it is.
    private struct Reader {
        let url: URL
        let builtIn: Bool
        let manifest: Data

        func package(from json: [String: Any]) throws -> EffectPackage {
            let id = json["id"] as! String
            guard EffectPackage.isValidID(id) else {
                throw JSONShapeError(
                    message: "\"\(id)\" isn't a valid ID: use letters, digits and hyphens, in parts joined by dots", path: "id"
                )
            }
            guard builtIn || id.contains(".") else {
                throw JSONShapeError(message: "The ID \"\(id)\" needs a dot, as in \"com.example.\(id)\"", path: "id")
            }
            let version = json["version"] as! Int
            guard version >= 1 else { throw JSONShapeError(message: "The version starts at 1", path: "version") }

            let kernel = json["kernel"] as! [String: Any]
            let kernelType = EffectPackage.KernelType(rawValue: kernel["type"] as! String)!
            let function = kernel["function"] as! String
            let source = try kernelSource(file: kernel["file"] as! String, function: function)

            var controls: [ControlDefinition] = []
            var names: [String: EffectExpression.ValueType] = [:]
            var rates: Set<ControlKind> = []
            var amountIndex: Int?
            for (index, entry) in (json["controls"] as! [[String: Any]]).enumerated() {
                let path = "controls[\(index)]"
                if entry["type"] as? String == "amount" {
                    guard amountIndex == nil else { throw JSONShapeError(message: "Amount is placed twice", path: path) }
                    amountIndex = controls.count
                    continue
                }
                let control = try self.control(entry, package: id, path: path)
                let controlID = control.kind.savedName
                guard names[controlID] == nil else { throw JSONShapeError(message: "Another control is called \"\(controlID)\"", path: path + ".id") }
                names[controlID] = valueType(entry["type"] as! String, control)
                if entry["rate"] as? Bool == true { rates.insert(control.kind) }
                controls.append(control)
            }

            func expression(_ text: String, _ path: String) throws -> EffectExpression {
                do {
                    return try EffectExpression(text, names: names)
                } catch {
                    throw JSONShapeError(message: error.message, path: path)
                }
            }
            func number(_ text: String, _ path: String) throws -> EffectExpression {
                let parsed = try expression(text, path)
                guard parsed.type == .number else { throw JSONShapeError(message: "Expected one number, not \(parsed.type.noun)", path: path) }
                return parsed
            }

            var pictures: [EffectPackage.Picture] = []
            for (index, entry) in (json["pictures"] as? [[String: Any]] ?? []).enumerated() {
                let path = "pictures[\(index)]"
                guard kernelType == .general else {
                    throw JSONShapeError(message: "Only a general kernel reads more than one picture", path: path)
                }
                let pictureID = entry["id"] as! String
                guard EffectPackage.isValidControlID(pictureID), names[pictureID] == nil, !pictures.contains(where: { $0.id == pictureID }) else {
                    throw JSONShapeError(message: "\"\(pictureID)\" isn't a name a picture can take: use letters and digits, not a control's", path: path + ".id")
                }
                let source = EffectPackage.Picture.Source(rawValue: entry["from"] as! String)!
                guard (entry["ahead"] != nil) == (source == .motion) else {
                    throw JSONShapeError(message: "The motion, and only the motion, says how many frames ahead it is", path: path)
                }
                guard source == .moment || !pictures.contains(where: { $0.source == source }) else {
                    throw JSONShapeError(message: "It already reads a picture from \(source.rawValue)", path: path + ".from")
                }
                guard (entry["delay"] != nil) == (source == .moment), entry["missing"] == nil || source == .moment else {
                    throw JSONShapeError(message: "A moment, and only a moment, has a delay and says what a missing one is", path: path)
                }
                pictures.append(EffectPackage.Picture(id: pictureID, source: source, missingIsPicture: entry["missing"] as? String == "picture"))
            }
            var flags: [String: EffectExpression.ValueType] = [:]
            if pictures.contains(where: { $0.source == .input }) { flags["hasInput"] = .number }
            if pictures.contains(where: { $0.source == .against }) { flags["hasAgainst"] = .number }
            if pictures.contains(where: { $0.source == .motion }) { flags["hasMotion"] = .number }
            names.merge(flags) { own, _ in own }
            // A repeated kernel's passes, and the copy or band each draws.
            var repeats: EffectPackage.Repeat?
            if let entry = json["repeat"] as? [String: Any] {
                guard kernelType == .general else {
                    throw JSONShapeError(message: "Only a general kernel draws over what it drew before", path: "repeat")
                }
                names["pass"] = .number
                names["passes"] = .number
                names["index"] = .number
                let counts = try ["count", "countWhilePlaying"].map { key in try (entry[key] as? String).map { try number($0, "repeat.\(key)") } }
                let indices = try ["index", "indexWhilePlaying"].map { key in try (entry[key] as? String).map { try number($0, "repeat.\(key)") } }
                repeats = EffectPackage.Repeat(
                    count: counts[0]!, index: indices[0], countWhilePlaying: counts[1], indexWhilePlaying: indices[1],
                    startsClear: entry["start"] as? String == "clear"
                )
            }
            for (index, entry) in (json["pictures"] as? [[String: Any]] ?? []).enumerated() {
                if let text = entry["delay"] as? String { pictures[index].delay = try number(text, "pictures[\(index)].delay") }
                if let text = entry["ahead"] as? String { pictures[index].ahead = try number(text, "pictures[\(index)].ahead") }
            }
            var drawsWhen: EffectExpression?
            if let text = json["drawsWhen"] as? String {
                do {
                    drawsWhen = try EffectExpression(text, names: flags)
                } catch {
                    throw JSONShapeError(message: error.message + "; drawsWhen reads only whether it has its pictures", path: "drawsWhen")
                }
            }

            let arguments = try (json["arguments"] as! [String]).enumerated().map { try expression($1, "arguments[\($0)]") }
            var reach: EffectExpression?
            if let text = json["reach"] as? String {
                guard kernelType != .color else {
                    throw JSONShapeError(message: "A color kernel reads only its own pixel, so it has no reach", path: "reach")
                }
                reach = try number(text, "reach")
            }
            if json["input"] != nil, kernelType != .general {
                throw JSONShapeError(message: "Only a general kernel reads past its picture's edges", path: "input")
            }
            let flashes: EffectPackage.Flashing
            switch json["flashes"] {
            case nil: flashes = .never
            case let condition as String: flashes = .when(try number(condition, "flashes"))
            case let always as NSNumber where CFGetTypeID(always) == CFBooleanGetTypeID(): flashes = always.boolValue ? .always : .never
            default: throw JSONShapeError(message: "Expected true, false or a condition", path: "flashes")
            }
            var after: [EffectPackage.Filter] = []
            for (index, entry) in (json["after"] as? [[String: Any]] ?? []).enumerated() {
                let path = "after[\(index)]"
                let name = entry["filter"] as! String
                guard let filter = CIFilter(name: name) else {
                    throw JSONShapeError(message: "Core Image has no filter \"\(name)\"", path: path + ".filter")
                }
                if let given = entry["parameters"], !(given is [String: Any]) {
                    throw JSONShapeError(message: "Expected an object", path: path + ".parameters")
                }
                var parameters: [(key: String, value: EffectExpression)] = []
                for (key, value) in (entry["parameters"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    let place = path + ".parameters." + key
                    guard filter.inputKeys.contains(key), key != kCIInputImageKey else {
                        throw JSONShapeError(message: "\(name) has no input \"\(key)\"", path: place)
                    }
                    guard let text = value as? String else { throw JSONShapeError(message: "Expected text", path: place) }
                    parameters.append((key, try expression(text, place)))
                }
                let when = try (entry["when"] as? String).map { try number($0, path + ".when") }
                let edges = (entry["input"] as? String).flatMap(EffectPackage.Edges.init(rawValue:)) ?? .clear
                after.append(EffectPackage.Filter(name: name, when: when, parameters: parameters, edges: edges))
            }

            return EffectPackage(
                url: url, id: id, version: version, name: json["name"] as! String,
                category: EffectCategory(rawValue: json["category"] as! String)!, systemImage: json["symbol"] as! String,
                contentHash: EffectPackage.contentHash(manifest, source),
                kernelType: kernelType, kernelFunction: function, kernelFile: kernel["file"] as! String, kernelSource: source,
                controls: controls,
                amountIndex: amountIndex ?? (json["amount"] as? Bool == true ? controls.count : nil), arguments: arguments,
                generates: json["generates"] as? Bool ?? false, changesEveryFrame: json["changesEveryFrame"] as? Bool ?? false,
                dependsOnPixelSize: json["dependsOnPixelSize"] as? Bool ?? false, flashes: flashes,
                rateControls: rates, reach: reach, pictures: pictures, drawsWhen: drawsWhen, repeats: repeats,
                edges: (json["input"] as? String).flatMap(EffectPackage.Edges.init(rawValue:)) ?? .clear, after: after
            )
        }

        /// The kernel's Metal source, which must be a file in the package
        /// and hold the function named.
        private func kernelSource(file: String, function: String) throws -> String {
            guard !file.isEmpty, !file.contains("/"), !file.hasPrefix(".") else {
                throw JSONShapeError(message: "\"\(file)\" isn't a file in the package", path: "kernel.file")
            }
            guard let source = try? String(contentsOf: url.appending(path: file), encoding: .utf8) else {
                throw JSONShapeError(message: "The package has no file \"\(file)\"", path: "kernel.file")
            }
            guard source.contains(function) else {
                throw JSONShapeError(message: "\(file) has no function \"\(function)\"", path: "kernel.function")
            }
            return source
        }

        private func control(_ entry: [String: Any], package: String, path: String) throws -> ControlDefinition {
            let id = entry["id"] as! String
            guard EffectPackage.isValidControlID(id) else {
                throw JSONShapeError(message: "\"\(id)\" isn't a valid control ID: use letters and digits, starting with a letter", path: path + ".id")
            }
            guard !EffectExpression.reservedNames.contains(id) else {
                throw JSONShapeError(message: "\"\(id)\" is a name expressions already use", path: path + ".id")
            }
            let kind = ControlKind(package: package, control: id)
            let name = entry["name"] as! String
            let owner = EffectKind(package: package)
            let unit = (entry["unit"] as? String).flatMap { EffectPackageStore.units[$0] } ?? ""
            var range: ClosedRange<Double>?
            if let bounds = entry["range"] as? [Double] {
                guard bounds[0] < bounds[1] else { throw JSONShapeError(message: "The range's start must be below its end", path: path + ".range") }
                range = bounds[0]...bounds[1]
            }
            func checkDefaults(_ values: [Double], whole: Bool = false) throws {
                for value in values {
                    if let range, !range.contains(value) {
                        throw JSONShapeError(message: "The default \(value) is outside the range", path: path + ".default")
                    }
                    if whole, value != value.rounded() {
                        throw JSONShapeError(message: "The default must be a whole number", path: path + ".default")
                    }
                }
            }

            switch entry["type"] as! String {
            case "number":
                let whole = entry["whole"] as? Bool ?? false
                let value = entry["default"] as! Double
                try checkDefaults([value], whole: whole)
                return ControlDefinition(
                    kind, name, owner, defaults: [value], unit: unit,
                    dragStep: entry["step"] as? Double ?? (whole ? 1 : Self.dragStep(unit)), range: range, isWhole: whole
                )
            case "vector":
                let components = entry["components"] as! [String]
                guard (2...4).contains(components.count) else {
                    throw JSONShapeError(message: "A vector has 2, 3 or 4 components", path: path + ".components")
                }
                let values = entry["default"] as! [Double]
                guard values.count == components.count else {
                    throw JSONShapeError(message: "Expected a list of \(components.count) numbers, one per component", path: path + ".default")
                }
                try checkDefaults(values)
                return ControlDefinition(
                    kind, name, owner, defaults: values, unit: unit, dragStep: entry["step"] as? Double ?? Self.dragStep(unit),
                    range: range, componentNames: components
                )
            case "point":
                return ControlDefinition(
                    kind, name, owner, defaults: entry["default"] as? [Double] ?? [0, 0], unit: " px", componentNames: ["Δx", "Δy"]
                )
            case "color":
                var values = entry["default"] as! [Double]
                guard values.count == 3 || values.count == 4 else {
                    throw JSONShapeError(message: "Expected red, green and blue, and alpha if not 1", path: path + ".default")
                }
                guard values.allSatisfy({ (0...1).contains($0) }) else {
                    throw JSONShapeError(message: "A color's components are from 0 to 1", path: path + ".default")
                }
                if values.count == 3 { values.append(1) }
                return ControlDefinition(kind, name, owner, defaults: values, dragStep: 0.01, range: 0...1, isColor: true)
            default:
                let options = (entry["options"] as! [[String: String]]).map { (id: $0["id"]!, name: $0["name"]!) }
                guard !options.isEmpty else { throw JSONShapeError(message: "A choice needs options", path: path + ".options") }
                guard Set(options.map(\.id)).count == options.count else {
                    throw JSONShapeError(message: "Two options have the same ID", path: path + ".options")
                }
                let choice = entry["default"] as! String
                guard options.contains(where: { $0.id == choice }) else {
                    throw JSONShapeError(message: "The default \"\(choice)\" isn't one of the options", path: path + ".default")
                }
                var definition = ControlDefinition(kind, name, owner)
                definition.choiceOptions = options
                definition.defaultChoice = choice
                return definition
            }
        }

        private func valueType(_ type: String, _ control: ControlDefinition) -> EffectExpression.ValueType {
            switch type {
            case "number": .number
            case "point": .point
            case "choice": .choice
            default: .vector(control.defaultValues.count)
            }
        }

        /// How far one point of dragging moves a value in `unit`: speeds and
        /// factors by hundredths, seconds by tenths, the rest by one.
        private static func dragStep(_ unit: String) -> Double {
            switch unit {
            case " /s", " turns/s", "×": 0.01
            case " s": 0.1
            default: 1
            }
        }
    }
}

private extension String {
    /// The manifest with its ID, name and version those of a copy: each the
    /// first of its key, as the top level's come before the controls'.
    func renamed(id: (old: String, new: String), name: (old: String, new: String)) -> String {
        func quoted(_ text: String) -> String { String(data: try! JSONEncoder().encode(text), encoding: .utf8)! }
        var text = self
        for (key, old, new) in [("id", quoted(id.old), quoted(id.new)), ("name", quoted(name.old), quoted(name.new))] {
            if let range = text.range(of: "\"\(key)\"\\s*:\\s*" + NSRegularExpression.escapedPattern(for: old), options: .regularExpression) {
                text.replaceSubrange(range, with: "\"\(key)\": \(new)")
            }
        }
        if let range = text.range(of: #""version"\s*:\s*\d+"#, options: .regularExpression) {
            text.replaceSubrange(range, with: #""version": 1"#)
        }
        return text
    }
}

private struct EffectPackageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
