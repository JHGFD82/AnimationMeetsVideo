import AppKit
import CoreMedia
import SwiftUI

/// The beat match panel: the song's transport along the top (with the tick
/// once there are beats to tick on), and the step the person is on and
/// the selected section or beat to the left of the waveform. See
/// docs/beat-matching.md.
///
/// Keys: Space plays, M drops a beat or anchor at the playhead (while
/// playing, taps in a row count on through the measure), ← → nudge
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

    @State private var showsTickSettings = false

    var body: some View {
        VStack(spacing: 0) {
            transport
                .padding(.horizontal, Design.Space.rail)
                .padding(.vertical, Design.Space.close)
                .rail(.raised)
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

    /// One line whatever the step, so the waveform below never jumps: the
    /// tick's pitch and volume open in a popover rather than adding a row.
    private var transport: some View {
        HStack(spacing: Design.Space.group) {
            HStack(spacing: Design.Space.step) {
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
                .toggleStyle(.icon)
                .disabled(session.selectedBeat == nil)
                .help("Loop the two measures around the selected beat (L)")
                .accessibilityLabel("Loop around the selected beat")
            }
            Groove(axis: .vertical).frame(height: 18)
            HStack(spacing: Design.Space.close) {
                Image(systemName: "music.note")
                    .font(Design.Typeface.icon)
                    .foregroundStyle(Design.textSecondary)
                    .accessibilityHidden(true)
                Slider(value: $session.songVolume, in: 0...1)
                    .controlSize(.small)
                    .frame(width: 90)
                    .help("The song's volume here; the timeline's mix is untouched")
                    .accessibilityLabel("Song volume")
                    .accessibilityValue("\(Int((session.songVolume * 100).rounded())) percent")
            }
            // Nothing to tick on until a beat is placed.
            if session.hasBeats {
                HStack(spacing: 2) {
                    Toggle(isOn: $session.clicksOn) {
                        Image(systemName: "metronome")
                    }
                    .toggleStyle(.icon)
                    .help("Play a tick on every beat; downbeats an octave up")
                    .accessibilityLabel("Tick on every beat")
                    Button { showsTickSettings.toggle() } label: {
                        Image(systemName: "chevron.down").font(Design.Typeface.glyphSmall)
                    }
                    .buttonStyle(.icon)
                    .help("The tick's pitch and volume")
                    .accessibilityLabel("Tick settings")
                    .popover(isPresented: $showsTickSettings, arrowEdge: .bottom) {
                        ClickToneControls(frequency: $frequency, volume: $volume) { session.clicks.preview() }
                            .frame(width: 300)
                            .padding(Design.Space.group)
                    }
                }
            }
            Spacer()
            HStack(spacing: 2) {
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
            .buttonStyle(.icon)
        }
        .frame(minHeight: 28)
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

    /// Where the person is, what to do, the controls for it, and, pinned
    /// below so they never scroll away, the ways out.
    private var sidebar: some View {
        VStack(spacing: 0) {
            stepHeader
                .padding(.horizontal, Design.Space.rail)
                .padding(.vertical, Design.Space.step + 2)
            Groove(subtle: true)
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.group + 2) {
                    guidance
                    if let message = session.message {
                        SheetCallout(.warning, message)
                    }
                    switch session.step {
                    case .chooseMode: modeChoice
                    case .drawSections: drawingControls
                    case .mark: markingControls
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Design.Space.rail)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .confirmationDialog("Start over?", isPresented: $confirmingStartOver) {
            Button("Start Over", role: .destructive, action: session.startOver)
        } message: {
            Text("Every section and beat of this song is removed. You can undo this.")
        }
    }

    private var footer: some View {
        HStack(spacing: Design.Space.step) {
            Button { confirmingStartOver = true } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.icon)
            .disabled(session.step == .chooseMode)
            .help("Start over: remove every section and beat of this song")
            .accessibilityLabel("Start over")
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Confirm", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .tint(Design.accentFill)
                .help("Put these beats on the timeline; until then nothing here changes it")
        }
        .padding(.horizontal, Design.Space.rail)
        .padding(.vertical, Design.Space.step + 2)
        .background(Design.Surface.raised.color)
        .overlay(alignment: .top) { Groove() }
    }

    // MARK: Steps

    private enum StepMark { case done, current, upcoming, skipped }

    /// The three steps in a row, so the person can see where they are and
    /// what is left: choosing, drawing sections (skipped for one tempo),
    /// and marking beats, with how many sections are filled.
    private var stepHeader: some View {
        let steps: [(String, StepMark)] = [
            ("Tempo", session.step == .chooseMode ? .current : .done),
            ("Sections", sectionsMark),
            ("Beats", session.step == .mark ? .current : .upcoming),
        ]
        return VStack(alignment: .leading, spacing: Design.Space.close) {
            HStack(spacing: Design.Space.close) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 {
                        Rectangle()
                            .fill(Design.textTertiary.opacity(0.35))
                            .frame(width: 10, height: 1)
                            .accessibilityHidden(true)
                    }
                    stepChip(number: index + 1, title: step.0, mark: step.1)
                }
            }
            if session.step == .mark, let progress = markingProgress {
                Text(progress)
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var sectionsMark: StepMark {
        switch session.step {
        case .chooseMode: .upcoming
        case .drawSections: .current
        case .mark: session.map.usesSections ? .done : .skipped
        }
    }

    /// "2 of 3 sections filled", counting the sections that take beats.
    private var markingProgress: String? {
        let marked = session.map.sections.filter { $0.kind != .none }
        guard marked.count > 1 else { return nil }
        let filled = marked.filter(\.isConfirmed).count
        return "\(filled) of \(marked.count) sections filled"
    }

    private func stepChip(number: Int, title: String, mark: StepMark) -> some View {
        HStack(spacing: Design.Space.tight) {
            ZStack {
                Circle()
                    .fill(mark == .current ? Design.accentFill : mark == .done ? Design.Surface.floating.color : .clear)
                Circle()
                    .strokeBorder(mark == .upcoming || mark == .skipped ? Design.textTertiary.opacity(0.5) : .clear, lineWidth: 1)
                if mark == .done {
                    Image(systemName: "checkmark")
                        .font(Design.Typeface.glyphTiny.weight(.bold))
                        .foregroundStyle(Design.statusDone)
                } else {
                    Text("\(number)")
                        .font(Design.Typeface.numericTag)
                        .foregroundStyle(mark == .current ? Design.textOnColor : Design.textTertiary)
                }
            }
            .frame(width: 16, height: 16)
            Text(title)
                .font(mark == .current ? Design.Typeface.groupTitle : Design.Typeface.label)
                .foregroundStyle(mark == .current ? Design.textPrimary : Design.textSecondary)
                .strikethrough(mark == .skipped, color: Design.textTertiary)
        }
        .opacity(mark == .skipped ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stepDescription(title, mark))
    }

    private func stepDescription(_ title: String, _ mark: StepMark) -> String {
        switch mark {
        case .done: "\(title), done"
        case .current: "\(title), current step"
        case .upcoming: "\(title), to come"
        case .skipped: "\(title), skipped"
        }
    }

    private var guidance: some View {
        let guidance = session.guidance
        return VStack(alignment: .leading, spacing: Design.Space.step) {
            Text(guidance.lead)
                .font(Design.Typeface.bodyEmphasis)
                .foregroundStyle(Design.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(guidance.tips, id: \.self) { tip in
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.close) {
                    Text(verbatim: "•")
                        .foregroundStyle(Design.textTertiary)
                        .accessibilityHidden(true)
                    Text(tip)
                        .foregroundStyle(Design.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Design.Typeface.label)
            }
        }
    }

    // MARK: Controls

    /// A group of the sidebar's controls under a heading, as sheets group
    /// their options.
    private func group<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            if let title {
                Text(title)
                    .font(Design.Typeface.groupTitle)
                    .foregroundStyle(Design.textSecondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A full-width command with its key beside its name, so the sidebar's
    /// buttons line up in one column and the keys can be learned.
    private func command(
        _ title: String, key: String? = nil, role: ButtonRole? = nil, prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: Design.Space.close) {
                Text(title)
                Spacer(minLength: Design.Space.step)
                if let key { KeyCap(key) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ProminenceStyle(prominent: prominent))
        .help(key.map { "\(title) (\($0))" } ?? title)
    }

    private var modeChoice: some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            modeCard(
                "One Tempo", symbol: "metronome",
                detail: "The whole song is one consistent section.",
                action: session.chooseOneTempo
            )
            modeCard(
                "Sections", symbol: "rectangle.split.3x1",
                detail: "Draw sections of one tempo, ramps between them, and parts not to analyze.",
                action: session.chooseSections
            )
        }
    }

    private func modeCard(_ title: String, symbol: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Design.Space.step + 2) {
                Image(systemName: symbol)
                    .font(Design.Typeface.glyphLarge)
                    .foregroundStyle(Design.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Design.Typeface.bodyEmphasis)
                        .foregroundStyle(Design.textPrimary)
                    Text(detail)
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Design.Space.step + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .beveledChip(fill: Design.Surface.overlay.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(detail)
    }

    private var drawingControls: some View {
        VStack(alignment: .leading, spacing: Design.Space.group + 2) {
            group("Kind") {
                // With a section selected, its kind; picking one changes it.
                Picker("Kind", selection: Binding(
                    get: { session.selectedSection?.kind ?? session.drawKind },
                    set: { session.chooseKind($0) }
                )) {
                    ForEach(BeatSection.Kind.allCases) { kind in Text(kind.name).tag(kind) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(session.selectedSection == nil
                      ? "The kind of section a drag draws"
                      : "The selected section's kind, and what a drag draws next")
                command("Fill Gap at Playhead", key: "F") { session.fillGap(at: session.livePlayhead) }
            }
            if let section = session.selectedSection {
                group("Selected Section") {
                    sectionSummary(section)
                    command("Start to Playhead", key: "[") { session.moveSelectedEdgeToPlayhead(.start) }
                    command("End to Playhead", key: "]") { session.moveSelectedEdgeToPlayhead(.end) }
                    command("Delete Section", key: "⌫", role: .destructive, action: session.deleteSelectedSection)
                }
            }
            command("Done Drawing", prominent: true, action: session.finishDrawing)
                .disabled(!session.map.sections.contains { $0.kind != .none })
        }
    }

    private func sectionSummary(_ section: BeatSection) -> some View {
        HStack(spacing: Design.Space.close) {
            RoundedRectangle(cornerRadius: 2)
                .fill(section.kind.tone)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(section.kind.name)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textPrimary)
            Spacer(minLength: 0)
            Text("\(BeatMatchWaveform.timeText(section.start.seconds))–\(BeatMatchWaveform.timeText(section.end.seconds))")
                .font(Design.Typeface.numericMicro)
                .foregroundStyle(Design.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var markingControls: some View {
        if session.map.usesSections {
            group("Section") {
                HStack(spacing: Design.Space.close) {
                    Picker("Section", selection: Binding(get: { session.selectedSectionID }, set: { session.selectSection($0) })) {
                        ForEach(Array(session.map.sections.enumerated()), id: \.element.id) { index, section in
                            Text("\(index + 1). \(section.kind.name)\(section.isConfirmed ? " ✓" : "")").tag(UUID?.some(section.id))
                        }
                    }
                    .labelsHidden()
                    Button { session.isDrawing = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.icon)
                        .help("Edit sections")
                        .accessibilityLabel("Edit sections")
                }
                if let section = session.selectedSection { sectionSummary(section) }
            }
        }
        if let section = session.selectedSection {
            sectionControls(section)
        }
        if let beat = session.selectedMappedBeat, let section = session.selectedSection {
            beatControls(beat, in: section)
        }
    }

    @ViewBuilder
    private func sectionControls(_ section: BeatSection) -> some View {
        if section.kind != .none {
            group("Measure") {
                Stepper(value: Binding(get: { section.beatsPerMeasure }, set: { session.setBeatsPerMeasure($0) }),
                        in: BeatSection.beatsPerMeasureRange) {
                    Text("\(section.beatsPerMeasure) beats a measure")
                        .font(Design.Typeface.body)
                }
                .help("Only the count: 4/4 and 4/8 are both 4, 6/8 is 6")
                if section.kind == .consistent {
                    Toggle("Tempo drifts (played live)", isOn: Binding(
                        get: { section.steadiness == .intent },
                        set: { session.setSteadiness($0 ? .intent : .click) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(Design.Typeface.body)
                    .help("Off for music produced to a click track: the beats are an exact grid. On, detection moves each beat onto the music.")
                }
            }
        }
        if section.kind == .consistent {
            group("Beats") {
                command(section.pinnedBeats.isEmpty ? "Drop Anchor at Playhead" : "Drop Beat at Playhead", key: "M",
                        action: session.addBeatAtPlayhead)
                fillCommand(section.isConfirmed ? "Reanalyze" : "Fill Beats", prominent: !section.isConfirmed)
                    .disabled(section.pinnedBeats.count < 2 || session.audio == nil || session.isFilling)
                    .help(section.isConfirmed ? "Keep the pinned beats and fit the rest to them (Return)" : "Find the tempo from the two anchors and fill the section (Return)")
            }
            group("Tempo") {
                if section.isConfirmed { tempoControls }
                copyPasteControls
            }
        } else if section.kind == .ramp {
            group("Beats") {
                command("Drop Beat at Playhead", key: "M", action: session.addBeatAtPlayhead)
                fillCommand(section.isConfirmed ? "Reanalyze Ramp" : "Fill Ramp", prominent: !section.isConfirmed)
                    .disabled(session.audio == nil || session.isFilling)
            }
        }
    }

    private func fillCommand(_ title: String, prominent: Bool) -> some View {
        Button { session.fillSelected() } label: {
            HStack(spacing: Design.Space.close) {
                Text(title)
                Spacer(minLength: Design.Space.step)
                if session.isFilling {
                    ProgressView().controlSize(.mini)
                } else {
                    KeyCap("↩")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ProminenceStyle(prominent: prominent))
    }

    /// Copy and paste of a consistent section's tempo, beats per measure
    /// and steadiness; ramps and unanalyzed sections have none to share.
    @ViewBuilder
    private var copyPasteControls: some View {
        HStack(spacing: Design.Space.close) {
            Button(action: session.copyDetails) {
                HStack(spacing: Design.Space.tight) { Text("Copy"); KeyCap("⌘C") }.frame(maxWidth: .infinity)
            }
            .disabled(session.selectedDetails == nil)
            .help("Copy this section's tempo, beats a measure and steadiness (⌘C)")
            Button(action: session.pasteDetails) {
                HStack(spacing: Design.Space.tight) { Text("Paste"); KeyCap("⌘V") }.frame(maxWidth: .infinity)
            }
            .disabled(!session.canPasteDetails)
            .help("Fill this section at the copied tempo, its start taken as beat 1 (⌘V)")
        }
        if let copied = session.copiedDetails {
            Text("Copied: \(String(format: "%.2f", copied.tempo)) BPM, \(copied.beatsPerMeasure) beats a measure")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
        }
    }

    private var tempoControls: some View {
        HStack(spacing: Design.Space.close) {
            TextField("Tempo", text: $tempoText)
                .font(Design.Typeface.numeric)
                .frame(width: 70)
                .onSubmit {
                    if let tempo = Double(tempoText), tempo > 0 { session.fillSelected(tempo: tempo) }
                }
                .accessibilityLabel("Tempo in beats per minute")
                .help("Type a tempo and press Return to fill again at it")
            Text("BPM")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
            Spacer(minLength: 0)
            Button("×2", action: session.doubleTempo)
                .font(Design.Typeface.numericSmall)
                .disabled(!session.canDoubleTempo)
                .help("Double the tempo: a beat between each two")
                .accessibilityLabel("Double the tempo")
            Button("÷2", action: session.halveTempo)
                .font(Design.Typeface.numericSmall)
                .disabled(!session.canHalveTempo)
                .help(session.canHalveTempo
                      ? "Halve the tempo: keep every other beat"
                      : "Can't halve: it would drop a pinned beat or go below \(Int(BeatFitting.slowestHalved)) BPM")
                .accessibilityLabel("Halve the tempo")
        }
    }

    @ViewBuilder
    private func beatControls(_ beat: MappedBeat, in section: BeatSection) -> some View {
        Groove(subtle: true)
        group("Selected Beat") {
            HStack(spacing: Design.Space.close) {
                Text(BeatMatchWaveform.timeText(beat.time.seconds))
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textPrimary)
                if beat.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.beat)
                }
                Spacer(minLength: 0)
                Picker("Beat of the measure", selection: Binding(get: { beat.position }, set: { session.setSelectedPosition($0) })) {
                    ForEach(1...section.beatsPerMeasure, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("The beat's place in the measure; 1 is the downbeat")
            }
            Text("Drag to move it, or ← → for 1 ms (⌥ one sample, ⇧ 10 ms).")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.Space.close) {
                if beat.isPinned {
                    Button("Unpin", action: session.unpinSelected)
                        .help("Let reanalysis move this beat again")
                }
                Button("Delete Beat", role: .destructive, action: session.deleteSelectedBeat)
                    .help("Delete the beat (⌫)")
            }
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

/// A sidebar command: bordered, or filled with the accent for the step's
/// one next action.
private struct ProminenceStyle: PrimitiveButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.borderedProminent)
                .tint(Design.accentFill)
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.bordered)
        }
    }
}
