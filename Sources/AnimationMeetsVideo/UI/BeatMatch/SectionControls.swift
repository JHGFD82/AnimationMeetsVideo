import SwiftUI

/// While marking, the selected section's measure, its beats and, once a
/// consistent section is filled, its tempo.
struct SectionControls: View {
    let session: BeatMatchSession

    var body: some View {
        if let section = session.selectedSection {
            if section.kind != .none {
                measure(section)
            }
            switch section.kind {
            case .consistent:
                BeatMatchGroup("Beats") {
                    BeatMatchCommand(section.pinnedBeats.isEmpty ? "Drop Anchor at Playhead" : "Drop Beat at Playhead", key: "M",
                                     help: BeatMatchView.tapHelp, action: session.addBeatAtPlayhead)
                    fillCommand(
                        section.isConfirmed ? "Reanalyze" : "Fill Beats", prominent: !section.isConfirmed,
                        help: section.isConfirmed
                            ? "Keep the pinned beats and fit the rest to them (Return)"
                            : "Find the tempo from the two anchors and fill the section (Return)"
                    )
                }
                BeatMatchGroup("Tempo") {
                    // A filled section's beats can be deleted down to too
                    // few to have a tempo.
                    if session.selectedTempo != nil { TempoControls(session: session) }
                    CopyPasteControls(session: session)
                }
            case .ramp:
                BeatMatchGroup("Beats") {
                    BeatMatchCommand("Drop Beat at Playhead", key: "M", help: BeatMatchView.tapHelp, action: session.addBeatAtPlayhead)
                    fillCommand(section.isConfirmed ? "Reanalyze Ramp" : "Fill Ramp", prominent: !section.isConfirmed)
                }
            case .none:
                EmptyView()
            }
        }
    }

    private func measure(_ section: BeatSection) -> some View {
        BeatMatchGroup("Measure") {
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

    private func fillCommand(_ title: String, prominent: Bool, help: String? = nil) -> some View {
        BeatMatchCommand(title, key: "↩", prominent: prominent, isBusy: session.isFilling, help: help) {
            session.fillSelected()
        }
        .disabled(!session.canFillSelected)
    }
}

/// A filled consistent section's tempo, to type another to fill at, or to
/// double or halve.
private struct TempoControls: View {
    let session: BeatMatchSession

    /// The tempos a typed one can be: those doubling and halving reach.
    private static let tempos = BeatFitting.slowestHalved...BeatFitting.fastestDoubled

    var body: some View {
        HStack(spacing: Design.Space.close) {
            // Committed by Return, or by leaving the field. The setter is a
            // closure, not `apply` itself: Swift 6.3's compiler crashes
            // making the method into the binding's setter.
            TextField("Tempo", value: Binding(get: { session.selectedTempo ?? 0 }, set: { apply($0) }),
                      format: .number.precision(.fractionLength(2)))
                .font(Design.Typeface.numeric)
                .frame(width: 70)
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

    /// Fills again at a typed tempo. The tempo shown is rounded, so one
    /// that rounds the same is left alone; one out of range is explained,
    /// and the field goes back to the section's tempo.
    private func apply(_ tempo: Double) {
        if let current = session.selectedTempo, abs(current - tempo) < 0.005 { return }
        guard Self.tempos.contains(tempo) else {
            session.explain("A tempo can be from \(Int(Self.tempos.lowerBound)) to \(Int(Self.tempos.upperBound)) BPM.")
            return
        }
        session.fillSelected(tempo: tempo)
    }
}

/// Copy and paste of a consistent section's tempo, beats per measure
/// and steadiness; ramps and unanalyzed sections have none to share.
private struct CopyPasteControls: View {
    let session: BeatMatchSession

    var body: some View {
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
}
