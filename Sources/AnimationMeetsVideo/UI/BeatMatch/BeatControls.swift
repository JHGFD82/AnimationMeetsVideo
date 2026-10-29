import CoreMedia
import SwiftUI

/// While marking, the selected beat: where it is, its place in the
/// measure, how a fill moved it, and what can be done to it.
struct BeatControls: View {
    let session: BeatMatchSession

    var body: some View {
        if let beat = session.selectedMappedBeat, let section = session.selectedSection {
            Groove(subtle: true)
            BeatMatchGroup("Selected Beat") {
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
                note("Drag to move it, or ← → for 1 ms (⌥ one sample, ⇧ 10 ms).")
                if let heard = beat.heardTime {
                    let moved = CMTimeSubtract(beat.time, heard).seconds * 1000
                    note("Snapped \(String(format: "%.1f", abs(moved))) ms \(moved > 0 ? "later" : "earlier") onto its onset.")
                    BeatMatchCommand("Undo Snap", help: "Put the beat back where you placed it; fills then leave it there",
                                     action: session.undoSnap)
                } else if beat.isPinned, !beat.snapsToOnset {
                    note("Kept where you placed it: fills don't snap it.")
                    BeatMatchCommand("Snap Again", help: "Move the beat onto its onset again, as fills do", action: session.snapAgain)
                        .disabled(session.audio == nil)
                }
                if beat.isPinned {
                    BeatMatchCommand("Unpin", help: "Let reanalysis move this beat again", action: session.unpinSelected)
                }
                BeatMatchCommand("Delete Beat", key: "⌫", role: .destructive, action: session.deleteSelectedBeat)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Design.Typeface.label)
            .foregroundStyle(Design.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
