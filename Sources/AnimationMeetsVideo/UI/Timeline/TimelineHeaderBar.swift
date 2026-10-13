import SwiftUI

struct TimelineHeaderBar: View {
    @Binding var project: EditingProject
    @Binding var timelineID: UUID
    @State private var showingSettings = false
    @State private var showingNew = false

    private var currentTimeline: Timeline? {
        project.timeline(id: timelineID)
    }

    var body: some View {
        HStack {
            Menu(currentTimeline?.name ?? "Timeline") {
                ForEach(project.timelines) { timeline in
                    Button(timeline.name) { timelineID = timeline.id }
                }
            }
            .frame(width: 160)
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Timeline settings")
            .disabled(currentTimeline == nil)
            Button {
                showingNew = true
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .help("New timeline")

            Spacer()
            if let currentTimeline {
                Text(currentTimeline.timebaseSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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

    var body: some View {
        Form {
            TextField("Name", text: $name)
            HStack {
                TextField("Width", text: $widthText)
                    .evaluatesArithmetic($widthText)
                Text("×")
                TextField("Height", text: $heightText)
                    .evaluatesArithmetic($heightText)
            }
            TextField("Frame rate", text: $frameRateText)
                .evaluatesArithmetic($frameRateText)
            Picker("Color space", selection: $colorSpace) {
                ForEach(ProjectColorSpace.allCases) { space in
                    Text(space.rawValue).tag(space)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button(saveTitle) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { loadInitialValues() }
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

    private var saveTitle: String {
        switch mode {
        case .create: "Create"
        case .edit: "Save"
        }
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
