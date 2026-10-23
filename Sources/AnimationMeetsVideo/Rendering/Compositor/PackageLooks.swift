import CoreGraphics
import CoreImage
import Foundation
import Synchronization

/// The kernels of effect packages (see docs/effect-packages.md), each
/// compiled once from its package's source with the looks' shared
/// functions (`LookKernels.prelude`) in front. Each package's is compiled
/// on its own, as each built-in look's is, so Core Image can't mistake one
/// for another.
enum PackageKernels {
    private enum Outcome {
        case compiled(CIKernel)
        case failed(String)
    }

    /// By package ID and content hash, so a changed package compiles again.
    private static let outcomes = Mutex<[String: Outcome]>([:])

    /// The package's kernel, compiled the first time it is asked for; nil
    /// when it doesn't compile, and its look leaves the picture as it is.
    static func kernel(for package: EffectPackage) -> CIKernel? {
        if case .compiled(let kernel) = outcome(for: package) { return kernel }
        return nil
    }

    /// Why the package's kernel doesn't compile, or nil when it does,
    /// compiling it the first time it is asked for.
    static func problem(for package: EffectPackage) -> String? {
        if case .failed(let message) = outcome(for: package) { return message }
        return nil
    }

    /// Why the package's kernel didn't compile, if it has been compiled; so
    /// a view can ask without waiting for a compile.
    static func knownProblem(for package: EffectPackage) -> String? {
        if case .failed(let message)? = outcomes.withLock({ $0[key(package)] }) { return message }
        return nil
    }

    private static func key(_ package: EffectPackage) -> String { package.id + "#" + package.contentHash }

    private static func outcome(for package: EffectPackage) -> Outcome {
        let key = key(package)
        if let known = outcomes.withLock({ $0[key] }) { return known }
        let outcome = compile(package)
        outcomes.withLock { $0[key] = outcome }
        if case .failed(let message) = outcome {
            NSLog("The kernel of effect package \(package.id) couldn't be compiled: \(message)")
        }
        return outcome
    }

    private static func compile(_ package: EffectPackage) -> Outcome {
        let kernels: [CIKernel]
        do {
            kernels = try CIKernel.kernels(withMetalString: prelude + package.kernelSource)
        } catch {
            let message = linesBefore.flatMap { compilerMessage(error, file: package.kernelFile, linesBefore: $0) }
            return .failed(message ?? error.localizedDescription)
        }
        let function = package.kernelFunction
        guard let kernel = kernels.first(where: { $0.name == function }) else {
            return .failed("No kernel \"\(function)\" was compiled; it must be marked extern \"C\" [[stitchable]].")
        }
        let type: EffectPackage.KernelType = kernel is CIColorKernel ? .color : kernel is CIWarpKernel ? .warp : .general
        guard type == package.kernelType else {
            return .failed("\(function) is a \(type.rawValue) kernel, not the \(package.kernelType.rawValue) kernel effect.json says.")
        }
        return .compiled(kernel)
    }

    private static let prelude = LookKernels.prelude + "\n"

    /// How many lines the compiler counts before a package's kernel: the
    /// prelude's, and those Core Image puts before the source, which it
    /// doesn't say. Found once, from where an error on the kernel's first
    /// line is reported.
    private static let linesBefore: Int? = {
        do {
            _ = try CIKernel.kernels(withMetalString: prelude + "#error amvFirstLine\n")
        } catch {
            var current: NSError? = error as NSError
            while let error = current, error.domain != "MTLLibraryErrorDomain" {
                current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            let reported = current?.localizedDescription.firstMatch(of: /program_source:(\d+):\d+: error: amvFirstLine/)
            return reported.flatMap { Int($0.output.1) }.map { $0 - 1 }
        }
        return nil
    }()

    /// The Metal compiler's first error inside `error`, Core Image's being
    /// only a code, as "kernel.metal:3:12: use of undeclared identifier":
    /// its line counted in `file`, less the `linesBefore` it was compiled
    /// after. With how many more errors there were, if any.
    static func compilerMessage(_ error: Error, file: String, linesBefore: Int) -> String? {
        var current: NSError? = error as NSError
        while let error = current, error.domain != "MTLLibraryErrorDomain" {
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        guard let output = current?.localizedDescription else { return nil }
        let pattern = /program_source:(\d+):(\d+): error: (.*)/
        let errors = output.split(separator: "\n").compactMap { $0.wholeMatch(of: pattern) }
        guard let first = errors.first, let line = Int(first.output.1) else { return nil }
        let place = line > linesBefore ? "\(file):\(line - linesBefore):\(first.output.2)" : file
        let more = errors.count > 1 ? " (and \(errors.count - 1) more)" : ""
        return "\(place): \(first.output.3)\(more)"
    }
}

/// Draws a look whose kind comes from an effect package: its arguments
/// evaluated from the step, then its kernel, then its filters.
enum PackageLookRenderer {
    /// `picture` with `step` drawn on it, as `LookRenderer.apply` draws a
    /// built-in look: a color kernel over `region` (a generator, with
    /// nothing there, over `canvas`); a general kernel over `region` with
    /// its edges repeating, or over `canvas` transparent past them; a warp
    /// over `canvas`. The picture as it is if the kernel didn't compile.
    static func apply(
        _ package: EffectPackage, _ step: LookStep, to picture: CIImage, over region: CGRect, canvas: CGRect,
        frame: CGRect, scale: CGFloat, space: ProjectColorSpace
    ) -> CIImage {
        guard let kernel = PackageKernels.kernel(for: package) else { return picture }
        let values = Values(package: package, step: step, frame: frame, canvas: canvas, scale: scale)
        var arguments = package.arguments.map { kernelArgument($0.evaluate(values)) }
        if package.hasAmount { arguments.append(Float(step.amount)) }
        let spaceIndex = Float(space.gradingSpaceIndex)
        let reach = package.reach.map { CGFloat($0.number(values)) }
        let clear = CIImage(color: .clear)

        var drawn: CIImage
        switch package.kernelType {
        case .color:
            var region = region.integral
            if region.isEmpty, package.generates { region = canvas.integral }
            guard !region.isEmpty, !region.isInfinite, let color = kernel as? CIColorKernel else { return picture }
            // A generator draws where nothing was too.
            let input = package.generates ? picture.composited(over: clear).cropped(to: region) : picture.cropped(to: region)
            guard let image = color.apply(extent: region, arguments: [input, spaceIndex] + arguments) else { return picture }
            drawn = image
        case .general:
            let extent: CGRect
            let input: CIImage
            if package.edges == .clamped {
                extent = region.integral
                guard !extent.isEmpty, !extent.isInfinite else { return picture }
                input = picture.cropped(to: extent).clampedToExtent()
            } else {
                extent = canvas.integral
                input = picture.composited(over: clear).cropped(to: canvas)
            }
            let image = kernel.apply(
                extent: extent,
                roiCallback: { _, rect in reach.map { rect.insetBy(dx: -abs($0) - 1, dy: -abs($0) - 1) } ?? canvas },
                arguments: [input, spaceIndex] + arguments
            )
            guard let image else { return picture }
            drawn = image.cropped(to: extent)
        case .warp:
            guard let warp = kernel as? CIWarpKernel else { return picture }
            let input = picture.composited(over: clear).cropped(to: canvas)
            let image = warp.apply(
                extent: canvas.integral,
                roiCallback: { _, rect in reach.map { rect.insetBy(dx: -abs($0) - 1, dy: -abs($0) - 1) } ?? canvas },
                image: input, arguments: arguments
            )
            guard let image else { return picture }
            drawn = image
        }

        for filter in package.after where filter.when.map({ $0.number(values) != 0 }) ?? true {
            var parameters: [String: Any] = [:]
            for (key, value) in filter.parameters { parameters[key] = filterParameter(value.evaluate(values)) }
            drawn = drawn.applyingFilter(filter.name, parameters: parameters).cropped(to: drawn.extent)
        }
        return drawn
    }

    /// One number as a `float`, several as a vector of their count.
    private static func kernelArgument(_ value: [Double]) -> Any {
        value.count == 1 ? Float(value[0]) : CIVector(values: value.map { CGFloat($0) }, count: value.count)
    }

    private static func filterParameter(_ value: [Double]) -> Any {
        value.count == 1 ? NSNumber(value: value[0]) : CIVector(values: value.map { CGFloat($0) }, count: value.count)
    }

    /// What a package's expressions read: its controls from the step (a
    /// control turned off or deleted at its default), and the frame's
    /// sizes and time. Read from the package, not the registry, as frames
    /// are drawn away from any task.
    private struct Values: EffectExpression.Values {
        let package: EffectPackage
        let step: LookStep
        let frame: CGRect
        let canvas: CGRect
        let scale: CGFloat

        private func definition(_ name: String) -> ControlDefinition? {
            let kind = ControlKind(package: package.id, control: name)
            return package.controls.first { $0.kind == kind }
        }

        func value(_ name: String) -> [Double] {
            switch name {
            case "seconds": return [step.seconds]
            // Thousandths of a second, so each frame of any rate differs,
            // as the built-in looks count frames.
            case "frame": return [(step.seconds * 1000).rounded()]
            case "scale": return [Double(scale)]
            case "frameWidth": return [Double(frame.width)]
            case "frameHeight": return [Double(frame.height)]
            case "frameCenter": return [Double(frame.midX), Double(frame.midY)]
            case "canvasWidth": return [Double(canvas.width)]
            case "canvasHeight": return [Double(canvas.height)]
            case "pi": return [.pi]
            default:
                guard let definition = definition(name) else { return [0] }
                return step.numbers[definition.kind] ?? definition.defaultValues
            }
        }

        /// A point's offset from the middle of the frame, in the timeline's
        /// pixels with down positive, as a position in output pixels.
        func center(_ name: String) -> [Double] {
            let offset = value(name)
            return [Double(frame.midX) + offset[0] * Double(scale), Double(frame.midY) - offset[1] * Double(scale)]
        }

        func index(_ name: String) -> Double {
            guard let definition = definition(name) else { return 0 }
            let choice = step.choices[definition.kind] ?? definition.defaultChoice
            return Double(definition.choiceOptions.firstIndex { $0.id == choice } ?? 0)
        }
    }
}
