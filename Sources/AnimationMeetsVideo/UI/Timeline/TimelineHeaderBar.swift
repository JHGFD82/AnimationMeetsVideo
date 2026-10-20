import SwiftUI

struct TimelineHeaderBar: View {
    @Binding var project: EditingProject
    @Binding var timelineID: UUID
    /// The timelines gone into to reach this one, outermost first, shown as
    /// a breadcrumb to go back along.
    var trail: [UUID] = []
    /// Goes back out to the timeline at this place on the trail.
    var onLeaveTo: (Int) -> Void = { _ in }
    @State private var showingSettings = false
    @State private var showingNew = false

    private var currentTimeline: Timeline? {
        project.timeline(id: timelineID)
    }

    var body: some View {
        HStack(spacing: Design.Space.close) {
            // Where this timeline was reached from; each is a button back.
            ForEach(Array(trail.enumerated()), id: \.offset) { index, ancestorID in
                Button(project.timeline(id: ancestorID)?.name ?? "Timeline") { onLeaveTo(index) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Design.textSecondary)
                    .help("Back to \(project.timeline(id: ancestorID)?.name ?? "this timeline")")
                    .accessibilityLabel("Back to \(project.timeline(id: ancestorID)?.name ?? "the outer timeline")")
                Image(systemName: "chevron.right")
                    .font(Design.Typeface.glyphTiny)
                    .foregroundStyle(Design.textTertiary)
                    .accessibilityHidden(true)
            }
            Menu(currentTimeline?.name ?? "Timeline") {
                ForEach(project.timelines) { timeline in
                    Button(timeline.name) { timelineID = timeline.id }
                }
            }
            // Its own width, so the name starts at the rail's inset like
            // every other rail's first item; a fixed frame centred it.
            .fixedSize()
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

            Spacer()
            if let currentTimeline {
                Text(currentTimeline.timebaseSummary)
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textTertiary)
            }
        }
        .padding(.horizontal, Design.Space.rail)
        .padding(.vertical, Design.Space.step)
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
            onCreate?(newID)
        case .edit(let id):
            project.updateTimelineSettings(
                id,
                name: name,
                frameSize: size,
                frameRate: frameRate,
                colorSpace: colorSpace
            )
        }
        isPresented = false
    }
}
