import SwiftUI

/// The three steps in a row, so the person can see where they are and
/// what is left: choosing, drawing sections (skipped for one tempo), and
/// marking beats, with how many sections are filled. Drawn sections can
/// be gone back to from their step while marking.
struct BeatMatchStepHeader: View {
    let session: BeatMatchSession

    private enum StepMark { case done, current, upcoming, skipped }

    private static let titles = ["Tempo", "Sections", "Beats"]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.close) {
            HStack(spacing: Design.Space.close) {
                ForEach(Self.titles.indices, id: \.self) { index in
                    if index > 0 {
                        Rectangle()
                            .fill(Design.textTertiary.opacity(0.35))
                            .frame(width: 10, height: 1)
                            .accessibilityHidden(true)
                    }
                    step(index)
                }
            }
            if session.step == .mark, let progress = markingProgress {
                Text(progress)
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func mark(of index: Int) -> StepMark {
        switch index {
        case 0: session.step == .chooseMode ? .current : .done
        case 1:
            switch session.step {
            case .chooseMode: .upcoming
            case .drawSections: .current
            case .mark: session.map.usesSections ? .done : .skipped
            }
        default: session.step == .mark ? .current : .upcoming
        }
    }

    @ViewBuilder
    private func step(_ index: Int) -> some View {
        let title = Self.titles[index]
        let mark = mark(of: index)
        // Only the drawn sections can be gone back to; the tempo's choice
        // is undone with Start Over.
        if index == 1, mark == .done {
            Button { session.isDrawing = true } label: {
                chip(number: index + 1, title: title, mark: mark)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit sections")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Goes back to drawing sections")
        } else {
            chip(number: index + 1, title: title, mark: mark)
        }
    }

    /// "2 of 3 sections filled", counting the sections that take beats.
    private var markingProgress: String? {
        var marked = 0
        var filled = 0
        for section in session.map.sections where section.kind != .none {
            marked += 1
            if section.isConfirmed { filled += 1 }
        }
        guard marked > 1 else { return nil }
        return "\(filled) of \(marked) sections filled"
    }

    private func chip(number: Int, title: String, mark: StepMark) -> some View {
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
        .accessibilityLabel(description(title, mark))
    }

    private func description(_ title: String, _ mark: StepMark) -> String {
        switch mark {
        case .done: "\(title), done"
        case .current: "\(title), current step"
        case .upcoming: "\(title), to come"
        case .skipped: "\(title), skipped"
        }
    }
}
