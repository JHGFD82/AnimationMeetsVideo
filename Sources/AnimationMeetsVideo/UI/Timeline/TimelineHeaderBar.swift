import SwiftUI

/// The bar above the viewer. It reads as a path on the left, from the
/// project to the open timeline through any timelines gone into on the
/// way; the open timeline's frame size, rate and colour in the middle; and
/// the window's own controls, Export last, on the right.
///
/// Weight marks the project, the root of the path, and brightness marks
/// where you are: the project's name is semibold but quiet, the open
/// timeline's is the brightest thing on the bar.
struct TimelineHeaderBar<Actions: View>: View {
    @Binding var project: EditingProject
    @Binding var timelineID: UUID
    /// The timelines gone into to reach this one, outermost first, shown as
    /// a breadcrumb to go back along.
    var trail: [UUID] = []
    /// Goes back out to the timeline at this place on the trail.
    var onLeaveTo: (Int) -> Void = { _ in }
    /// Where the path starts; nil leaves it at the timelines.
    var projectName: String? = nil
    @ViewBuilder var actions: () -> Actions
    @State private var showingSettings = false
    @State private var showingNew = false

    private var currentTimeline: Timeline? {
        project.timeline(id: timelineID)
    }

    var body: some View {
        // The sides share what the middle leaves equally, so the middle is
        // centred on the window whatever each side holds.
        HStack(spacing: Design.Space.group) {
            path
                .frame(maxWidth: .infinity, alignment: .leading)
            if let currentTimeline {
                Text(currentTimeline.timebaseSummary)
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .help("The open timeline's frame size, frame rate and colour space")
            }
            actions()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Design.Space.rail)
        .frame(minHeight: 40)
        .rail(.raised)
        .sheet(isPresented: $showingSettings) {
            TimelineSettingsSheet(mode: .edit(timelineID), project: $project, isPresented: $showingSettings)
        }
        .sheet(isPresented: $showingNew) {
            TimelineSettingsSheet(mode: .create, project: $project, isPresented: $showingNew) { newID in
                timelineID = newID
            }
        }
    }

    private var path: some View {
        HStack(spacing: Design.Space.close) {
            if let projectName {
                // Gives way first when the bar is short of room: the
                // timeline's name is the one to keep whole.
                Text(projectName)
                    .font(Design.Typeface.panelTitle)
                    .foregroundStyle(Design.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(projectName)
                    .accessibilityLabel("Project \(projectName)")
                separator
            }
            // Where this timeline was reached from; each is a button back.
            ForEach(Array(trail.enumerated()), id: \.offset) { index, ancestorID in
                Button(project.timeline(id: ancestorID)?.name ?? "Timeline") { onLeaveTo(index) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Design.textSecondary)
                    .lineLimit(1)
                    .help("Back to \(project.timeline(id: ancestorID)?.name ?? "this timeline")")
                    .accessibilityLabel("Back to \(project.timeline(id: ancestorID)?.name ?? "the outer timeline")")
                separator
            }
            // The open timeline's name, only shown: timelines are opened
            // and renamed in the browser's Timelines tab.
            Text(currentTimeline?.name ?? "Timeline")
                .font(Design.Typeface.bodyEmphasis)
                .foregroundStyle(Design.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Button {
                showingSettings = true
            } label: {
                Image(systemName: Design.Symbol.settings)
            }
            .buttonStyle(.icon)
            .help("Timeline settings")
            .accessibilityLabel("Timeline settings")
            .disabled(currentTimeline == nil)
            Button {
                showingNew = true
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(.icon)
            .help("New timeline")
            .accessibilityLabel("New timeline")
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(Design.Typeface.glyphTiny)
            .foregroundStyle(Design.textTertiary)
            .accessibilityHidden(true)
    }
}

extension TimelineHeaderBar where Actions == EmptyView {
    init(
        project: Binding<EditingProject>, timelineID: Binding<UUID>, trail: [UUID] = [],
        onLeaveTo: @escaping (Int) -> Void = { _ in }, projectName: String? = nil
    ) {
        self.init(
            project: project, timelineID: timelineID, trail: trail, onLeaveTo: onLeaveTo,
            projectName: projectName, actions: { EmptyView() }
        )
    }
}

struct TimelineSettingsSheet: View {
    enum Mode {
        case create
        case edit(UUID)
    }

    let mode: Mode
    @Binding var project: EditingProject
    @Binding var isPresented: Bool
    var onCreate: ((UUID) -> Void)?

    @State private var name: String = "New Timeline"
    @State private var widthText: String = "1920"
    @State private var heightText: String = "1080"
    @State private var frameRateText: String = "24"
    @State private var colorSpace: ProjectColorSpace = .rec709
    @State private var hasBackground = false
    @State private var background = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    private static let arithmeticNote = "Fields take arithmetic: 1920/2 becomes 960."

    var body: some View {
        SheetFrame(
            title: isCreating ? "New Timeline" : "Timeline Settings",
            subtitle: isCreating
                ? "The frame size and rate everything on this timeline is composited to."
                : "Clips keep their own footage; changing these re-composites them to the new frame.",
            width: Design.SheetWidth.standard,
            scrollsContent: true
        ) {
            SheetSection {
                SheetRow("Name") {
                    TextField("Name", text: $name)
                        .labelsHidden()
                }
            }

            SheetSection("Frame") {
                SheetRow("Size") {
                    HStack(spacing: Design.Space.close) {
                        TextField("Width", text: $widthText)
                            .labelsHidden()
                            .accessibilityHint(Self.arithmeticNote)
                            .evaluatesArithmetic($widthText)
                            .frame(width: 72)
                        Text("×")
                            .foregroundStyle(Design.textTertiary)
                        TextField("Height", text: $heightText)
                            .labelsHidden()
                            .accessibilityHint(Self.arithmeticNote)
                            .evaluatesArithmetic($heightText)
                            .frame(width: 72)
                        Text("px")
                            .font(Design.Typeface.label)
                            .foregroundStyle(Design.textTertiary)
                    }
                }
                SheetRow("Rate") {
                    HStack(spacing: Design.Space.close) {
                        TextField("Frame rate", text: $frameRateText)
                            .labelsHidden()
                            .accessibilityHint(Self.arithmeticNote)
                            .evaluatesArithmetic($frameRateText)
                            .frame(width: 72)
                        Text("fps")
                            .font(Design.Typeface.label)
                            .foregroundStyle(Design.textTertiary)
                    }
                }
                SheetNote(Self.arithmeticNote)
            }

            SheetSection("Colour") {
                SheetRow("Space") {
                    Picker("Color space", selection: $colorSpace) {
                        ForEach(ProjectColorSpace.allCases) { space in
                            Text(space.rawValue).tag(space)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SheetRow("Background") {
                    HStack(spacing: Design.Space.step) {
                        Toggle("Preview background", isOn: $hasBackground)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .help("Show a color in the viewer where nothing is drawn, instead of black")
                        ColorPicker("Background color", selection: $background, supportsOpacity: false)
                            .labelsHidden()
                            .disabled(!hasBackground)
                            .accessibilityLabel("Preview background color")
                    }
                }
                SheetNote("The background is only shown in the viewer, to see what is transparent. Exports are drawn over black.")
            }
        } actions: {
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button(isCreating ? "Create Timeline" : "Save Settings") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .onAppear { loadInitialValues() }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    // TextField(value:format:) only commits on blur, not per keystroke, so a
    // user filling the form top-to-bottom and clicking Create without
    // tabbing out of the last field would lose that field's edit. Plain
    // string fields parsed at save time commit immediately like Name does.
    private var isValid: Bool {
        guard let width = NumericExpression.evaluate(widthText),
              let height = NumericExpression.evaluate(heightText),
              let frameRate = NumericExpression.evaluate(frameRateText)
        else {
            return false
        }
        return (16...16_384).contains(width) && (16...16_384).contains(height)
            && (1...240).contains(frameRate)
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadInitialValues() {
        guard case .edit(let id) = mode, let timeline = project.timeline(id: id) else { return }
        name = timeline.name
        widthText = String(Int(timeline.frameSize.width))
        heightText = String(Int(timeline.frameSize.height))
        frameRateText = String(format: "%g", timeline.frameRate)
        colorSpace = timeline.colorSpace
        if let rgb = timeline.previewBackground, rgb.count == 3 {
            hasBackground = true
            background = CGColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        }
    }

    /// The background as saved: red, green and blue, or nil while it is off.
    private var pickedBackground: [Double]? {
        guard hasBackground, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let srgb = background.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = srgb.components, parts.count >= 3
        else { return nil }
        return parts.prefix(3).map { Double($0).clamped(between: 0, and: 1) }
    }

    private func save() {
        guard isValid,
              let width = NumericExpression.evaluate(widthText),
              let height = NumericExpression.evaluate(heightText),
              let frameRate = NumericExpression.evaluate(frameRateText)
        else {
            return
        }
        let size = CGSize(width: width.rounded(), height: height.rounded())
        switch mode {
        case .create:
            let newID = project.addTimeline(
                name: name,
                frameSize: size,
                frameRate: frameRate,
                colorSpace: colorSpace
            )
            if let background = pickedBackground {
                project.updateTimeline(newID) { $0.previewBackground = background }
            }
            onCreate?(newID)
        case .edit(let id):
            project.updateTimelineSettings(
                id,
                name: name,
                frameSize: size,
                frameRate: frameRate,
                colorSpace: colorSpace
            )
            let background = pickedBackground
            if project.timeline(id: id)?.previewBackground != background {
                project.updateTimeline(id) { $0.previewBackground = background }
            }
        }
        isPresented = false
    }
}
