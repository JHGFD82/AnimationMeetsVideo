import AppKit
import CoreMedia
import SwiftUI

/// The beat match panel: the song's transport along the top (with the tick
/// once there are beats to tick on), and the step the person is on and
/// the selected section or beat to the left of the waveform. See
/// docs/beat-matching.md.
///
/// Keys: Space plays, M drops a beat or anchor at the playhead, ← → nudge
/// the selected beat (1 ms; ⌥ one sample; ⇧ 10 ms), ↑ ↓ select the
/// previous and next beat, Delete removes the selected beat or section,
/// L loops, F fills the gap at the playhead, [ and ] move the selected
/// section's edges to the playhead, Return fills the selected section,
/// ⌘= and ⌘- zoom and ⌘0 fits.
struct BeatMatchView: View {
    @Bindable var session: BeatMatchSession
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @AppStorage(ClickToneSettings.frequencyKey) private var frequency = ClickToneSettings.defaultFrequency
    @AppStorage(ClickToneSettings.volumeKey) private var volume = ClickToneSettings.defaultVolume
    @State private var tempoText = ""
    @State private var confirmingStartOver = false

    var body: some View {
        VStack(spacing: 0) {
            transport
                .padding(.horizontal, Design.Space.rail)
                .padding(.vertical, Design.Space.step)
            Groove()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 280)
                Groove(axis: .vertical)
                waveformArea
            }
        }
        .background(Design.Surface.base.color)
        .preferredColorScheme(.dark)
        .tint(Design.accent)
        .background(KeyPressMonitor(handler: handleKey))
        .onChange(of: frequency, initial: true) { _, hertz in session.clicks.frequency = hertz }
        .onChange(of: volume, initial: true) { _, level in session.clicks.volume = Float(level) }
        .onChange(of: session.selectedTempo, initial: true) { _, tempo in
            tempoText = tempo.map { String(format: "%.2f", $0) } ?? ""
        }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: Design.Space.group) {
            Button(action: session.togglePlayback) {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .help(session.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
            // Follows the player on its own, so playing redraws only this.
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !session.isPlaying)) { context in
                let time = BeatMatchWaveform.timeText(session.playhead(at: context.date))
                Text(time)
                    .font(Design.Typeface.timecode)
                    .foregroundStyle(Design.textPrimary)
                    .frame(width: 92, alignment: .leading)
                    .accessibilityLabel("Playhead")
                    .accessibilityValue(time)
            }
            Toggle(isOn: $session.isLooping) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .disabled(session.selectedBeat == nil)
            .help("Loop the two measures around the selected beat (L)")
            .accessibilityLabel("Loop around the selected beat")
            HStack(spacing: Design.Space.close) {
                Image(systemName: "music.note")
                    .foregroundStyle(Design.textSecondary)
                    .accessibilityHidden(true)
                Slider(value: $session.songVolume, in: 0...1)
                    .frame(width: 90)
                    .help("The song's volume here; the timeline's mix is untouched")
                    .accessibilityLabel("Song volume")
                    .accessibilityValue("\(Int((session.songVolume * 100).rounded())) percent")
            }
            // Nothing to tick on until a beat is placed.
            if session.hasBeats {
                Toggle("Tick", isOn: $session.clicksOn)
                    .toggleStyle(.checkbox)
                    .help("Play a tick on every beat; downbeats an octave up")
                ClickToneControls(frequency: $frequency, volume: $volume) { session.clicks.preview() }
                    .frame(width: 300)
                    .disabled(!session.clicksOn)
            }
            Spacer()
            HStack(spacing: Design.Space.tight) {
                Button(action: session.zoomOut) { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (⌘-)")
                    .accessibilityLabel("Zoom out")
                Button(action: session.zoomIn) { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (⌘=)")
                    .accessibilityLabel("Zoom in")
                Button(action: session.fit) { Image(systemName: "arrow.left.and.right.square") }
                    .help("Fit the whole song (⌘0)")
                    .accessibilityLabel("Fit the whole song")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var waveformArea: some View {
        if let error = session.loadError {
            ContentUnavailableView("Couldn't Read the Song", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.audio == nil {
            VStack(spacing: Design.Space.step) {
                ProgressView(value: session.loadProgress)
                    .frame(width: 220)
                Text("Reading the song…")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            BeatMatchWaveform(session: session)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.group) {
                Text(session.instructions)
                    .font(Design.Typeface.body)
                    .foregroundStyle(Design.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = session.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch session.step {
                case .chooseMode: modeChoice
                case .drawSections: drawingControls
                case .mark: markingControls
                }
                Groove()
                Button("Start Over…") { confirmingStartOver = true }
                    .disabled(session.step == .chooseMode)
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Confirm", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .tint(Design.accentFill)
                        .help("Put these beats on the timeline; until then nothing here changes it")
                }
            }
            .padding(Design.Space.rail)
        }
        .confirmationDialog("Start over?", isPresented: $confirmingStartOver) {
            Button("Start Over", role: .destructive, action: session.startOver)
        } message: {
            Text("Every section and beat of this song is removed. You can undo this.")
        }
    }

    private var modeChoice: some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            Button("One Tempo", action: session.chooseOneTempo)
                .buttonStyle(.borderedProminent)
                .tint(Design.accentFill)
                .help("The whole song is one consistent section")
            Button("Sections", action: session.chooseSections)
                .help("Draw sections of one tempo, ramps between them, and parts not to analyze")
        }
    }

    private var drawingControls: some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            // With a section selected, its kind; picking one changes it.
            Picker("Kind", selection: Binding(
                get: { session.selectedSection?.kind ?? session.drawKind },
                set: { session.chooseKind($0) }
            )) {
                ForEach(BeatSection.Kind.allCases) { kind in Text(kind.name).tag(kind) }
            }
            .pickerStyle(.segmented)
            .help(session.selectedSection == nil
                  ? "The kind of section a drag draws"
                  : "The selected section's kind, and what a drag draws next")
            Button("Fill Gap at Playhead (F)") { session.fillGap(at: session.livePlayhead) }
            if let section = session.selectedSection {
                sectionSummary(section)
                HStack {
                    Button("Start to Playhead ([)") { session.moveSelectedEdgeToPlayhead(.start) }
                    Button("End to Playhead (])") { session.moveSelectedEdgeToPlayhead(.end) }
                }
                .font(Design.Typeface.label)
                Button("Delete Section", role: .destructive, action: session.deleteSelectedSection)
            }
            Button("Done Drawing", action: session.finishDrawing)
                .buttonStyle(.borderedProminent)
                .tint(Design.accentFill)
                .disabled(!session.map.sections.contains { $0.kind != .none })
        }
    }

    private func sectionSummary(_ section: BeatSection) -> some View {
        Text("\(section.kind.name): \(BeatMatchWaveform.timeText(section.start.seconds)) to \(BeatMatchWaveform.timeText(section.end.seconds))")
            .font(Design.Typeface.numericSmall)
            .foregroundStyle(Design.textSecondary)
    }

    @ViewBuilder
    private var markingControls: some View {
        if session.map.usesSections {
            Picker("Section", selection: Binding(get: { session.selectedSectionID }, set: { session.selectSection($0) })) {
                ForEach(Array(session.map.sections.enumerated()), id: \.element.id) { index, section in
                    Text("\(index + 1). \(section.kind.name)\(section.isConfirmed ? " ✓" : "")").tag(UUID?.some(section.id))
                }
            }
            Button("Edit Sections") { session.isDrawing = true }
        }
        if let section = session.selectedSection {
            sectionControls(section)
        }
        if let beat = session.selectedMappedBeat, let section = session.selectedSection {
            Groove()
            beatControls(beat, in: section)
        }
    }

    @ViewBuilder
    private func sectionControls(_ section: BeatSection) -> some View {
        sectionSummary(section)
        if section.kind != .none {
            Stepper(value: Binding(get: { section.beatsPerMeasure }, set: { session.setBeatsPerMeasure($0) }),
                    in: BeatSection.beatsPerMeasureRange) {
                Text("\(section.beatsPerMeasure) beats a measure")
            }
            .help("Only the count: 4/4 and 4/8 are both 4, 6/8 is 6")
        }
        if section.kind == .consistent {
            Toggle("Tempo drifts (played live, meant to be steady)", isOn: Binding(
                get: { section.steadiness == .intent },
                set: { session.setSteadiness($0 ? .intent : .click) }
            ))
            .toggleStyle(.checkbox)
            .help("Off for music produced to a click track: the beats are an exact grid. On, detection moves each beat onto the music.")
            Button("Drop Anchor at Playhead (M)", action: session.addBeatAtPlayhead)
            HStack {
                Button(section.isConfirmed ? "Reanalyze" : "Fill Beats") { session.fillSelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accentFill)
                    .disabled(section.pinnedBeats.count < 2 || session.audio == nil || session.isFilling)
                    .help(section.isConfirmed ? "Keep the pinned beats and fit the rest to them" : "Find the tempo from the two anchors and fill the section")
                if session.isFilling { ProgressView().controlSize(.small) }
            }
            if section.isConfirmed { tempoControls }
            copyPasteControls
        } else if section.kind == .ramp {
            Button("Drop Beat at Playhead (M)", action: session.addBeatAtPlayhead)
            HStack {
                Button(section.isConfirmed ? "Reanalyze Ramp" : "Fill Ramp") { session.fillSelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accentFill)
                    .disabled(session.audio == nil || session.isFilling)
                if session.isFilling { ProgressView().controlSize(.small) }
            }
        }
    }

    /// Copy and paste of a consistent section's tempo, beats per measure
    /// and steadiness; ramps and unanalyzed sections have none to share.
    @ViewBuilder
    private var copyPasteControls: some View {
        HStack {
            Button("Copy Tempo", action: session.copyDetails)
                .disabled(session.selectedDetails == nil)
                .help("Copy this section's tempo, beats a measure and steadiness (⌘C)")
            Button("Paste Tempo", action: session.pasteDetails)
                .disabled(!session.canPasteDetails)
                .help("Fill this section at the copied tempo, its start taken as beat 1 (⌘V)")
        }
        if let copied = session.copiedDetails {
            Text("Copied: \(String(format: "%.2f", copied.tempo)) BPM, \(copied.beatsPerMeasure) beats a measure")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
        }
    }

    private var tempoControls: some View {
        HStack(spacing: Design.Space.close) {
            TextField("Tempo", text: $tempoText)
                .frame(width: 70)
                .onSubmit {
                    if let tempo = Double(tempoText), tempo > 0 { session.fillSelected(tempo: tempo) }
                }
                .accessibilityLabel("Tempo in beats per minute")
            Text("BPM")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
            Button("×2", action: session.doubleTempo)
                .disabled(!session.canDoubleTempo)
                .help("Double the tempo: a beat between each two")
                .accessibilityLabel("Double the tempo")
            Button("÷2", action: session.halveTempo)
                .disabled(!session.canHalveTempo)
                .help(session.canHalveTempo
                      ? "Halve the tempo: keep every other beat"
                      : "Can't halve: it would drop a pinned beat or go below \(Int(BeatFitting.slowestHalved)) BPM")
                .accessibilityLabel("Halve the tempo")
        }
    }

    @ViewBuilder
    private func beatControls(_ beat: MappedBeat, in section: BeatSection) -> some View {
        Text("Beat at \(BeatMatchWaveform.timeText(beat.time.seconds))\(beat.isPinned ? " · pinned" : "")")
            .font(Design.Typeface.numericSmall)
            .foregroundStyle(Design.textSecondary)
        Picker("Beat of the measure", selection: Binding(get: { beat.position }, set: { session.setSelectedPosition($0) })) {
            ForEach(1...section.beatsPerMeasure, id: \.self) { Text("\($0)").tag($0) }
        }
        Text("Drag the beat to move it, or use ← and → for 1 ms, with ⌥ for one sample and with ⇧ for 10 ms.")
            .font(Design.Typeface.label)
            .foregroundStyle(Design.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            if beat.isPinned {
                Button("Unpin", action: session.unpinSelected)
                    .help("Let reanalysis move this beat again")
            }
            Button("Delete Beat", role: .destructive, action: session.deleteSelectedBeat)
        }
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "=", "+": session.zoomIn(); return true
            case "-": session.zoomOut(); return true
            case "0": session.fit(); return true
            case "c": session.copyDetails(); return session.selectedDetails != nil
            case "v":
                guard session.canPasteDetails else { return false }
                session.pasteDetails()
                return true
            default: return false
            }
        }
        let step = flags.contains(.option) ? session.sampleDuration : flags.contains(.shift) ? 0.01 : 0.001
        switch Int(event.keyCode) {
        case 49: session.togglePlayback()  // space
        case 123:  // left
            if session.selectedBeat != nil { session.nudgeSelected(by: -step) } else { session.seek(to: session.livePlayhead - 1) }
        case 124:  // right
            if session.selectedBeat != nil { session.nudgeSelected(by: step) } else { session.seek(to: session.livePlayhead + 1) }
        case 126: session.selectBeat(step: -1)  // up
        case 125: session.selectBeat(step: 1)  // down
        case 51, 117:  // delete, forward delete
            if session.selectedBeat != nil { session.deleteSelectedBeat() } else if session.step == .drawSections { session.deleteSelectedSection() } else { return false }
        case 36, 76:  // return, enter
            if session.step == .mark, session.selectedSection?.kind != BeatSection.Kind.none { session.fillSelected() } else { return false }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "m": session.addBeatAtPlayhead()
            case "l": session.isLooping.toggle()
            case "f": session.fillGap(at: session.livePlayhead)
            case "[": session.moveSelectedEdgeToPlayhead(.start)
            case "]": session.moveSelectedEdgeToPlayhead(.end)
            default: return false
            }
        }
        return true
    }
}
