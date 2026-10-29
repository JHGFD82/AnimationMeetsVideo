import SwiftUI

/// Left of the waveform: where the person is, what to do, the controls
/// for it, and, pinned below so they never scroll away, the ways out.
struct BeatMatchSidebar: View {
    let session: BeatMatchSession
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            BeatMatchStepHeader(session: session)
                .padding(.horizontal, Design.Space.rail)
                .padding(.vertical, Design.Space.step + 2)
            Groove(subtle: true)
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.group + 2) {
                    Guidance(session: session)
                    if let message = session.message {
                        SheetCallout(.warning, message)
                    }
                    // By place: two hints may say the same.
                    ForEach(session.fillHints.indices, id: \.self) { index in
                        SheetCallout(.info, session.fillHints[index])
                    }
                    switch session.step {
                    case .chooseMode: modeChoice
                    case .drawSections: DrawingControls(session: session)
                    case .mark:
                        if session.map.usesSections { SectionPicker(session: session) }
                        SectionControls(session: session)
                        BeatControls(session: session)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Design.Space.rail)
            }
            .scrollBounceBehavior(.basedOnSize)
            BeatMatchFooter(session: session, onConfirm: onConfirm, onCancel: onCancel)
        }
    }

    private var modeChoice: some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            modeCard(
                "One Tempo", symbol: Design.Symbol.tick,
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
}

/// What to do next, as one line with tips under it.
private struct Guidance: View {
    let session: BeatMatchSession

    var body: some View {
        let guidance = session.guidance
        VStack(alignment: .leading, spacing: Design.Space.step) {
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
}

private struct DrawingControls: View {
    let session: BeatMatchSession

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.group + 2) {
            BeatMatchGroup("Kind") {
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
                BeatMatchCommand("Mark to Playhead", key: "M", help: "Mark from the section before the playhead up to it (M)",
                                 action: session.drawSectionToPlayhead)
                BeatMatchCommand("Fill Gap at Playhead", key: "F") { session.fillGap(at: session.livePlayhead) }
            }
            if let section = session.selectedSection {
                BeatMatchGroup("Selected Section") {
                    BeatMatchSectionSummary(section: section)
                    BeatMatchCommand("Start to Playhead", key: "[") { session.moveSelectedEdgeToPlayhead(.start) }
                    BeatMatchCommand("End to Playhead", key: "]") { session.moveSelectedEdgeToPlayhead(.end) }
                    BeatMatchCommand("Delete Section", key: "⌫", role: .destructive, action: session.deleteSelectedSection)
                }
            }
        }
    }
}

/// While marking a song drawn in sections, which section is being marked.
private struct SectionPicker: View {
    let session: BeatMatchSession

    var body: some View {
        BeatMatchGroup("Section") {
            HStack(spacing: Design.Space.close) {
                Picker("Section", selection: Binding(get: { session.selectedSectionID }, set: { session.selectSection($0) })) {
                    ForEach(session.map.sections, id: \.id) { section in
                        Text("\(number(of: section)). \(section.kind.name)\(section.isConfirmed ? " ✓" : "")")
                            .tag(UUID?.some(section.id))
                    }
                }
                .labelsHidden()
                Button { session.isDrawing = true } label: { Image(systemName: Design.Symbol.edit) }
                    .buttonStyle(.icon)
                    .help("Edit sections")
                    .accessibilityLabel("Edit sections")
            }
            if let section = session.selectedSection { BeatMatchSectionSummary(section: section) }
        }
    }

    private func number(of section: BeatSection) -> Int {
        (session.map.sections.firstIndex { $0.id == section.id } ?? 0) + 1
    }
}

/// A group of the sidebar's controls under a heading, as sheets group
/// their options.
struct BeatMatchGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            if let title {
                Text(title)
                    .font(Design.Typeface.groupTitle)
                    .foregroundStyle(Design.textSecondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A full-width sidebar command with its key beside its name, so the
/// sidebar's buttons line up in one column and the keys can be learned:
/// bordered, or filled with the accent for the step's one next action.
struct BeatMatchCommand: View {
    let title: String
    let key: String?
    let role: ButtonRole?
    let prominent: Bool
    /// Shows a spinner in place of the key while what it started runs.
    let isBusy: Bool
    let help: String?
    let action: () -> Void

    init(
        _ title: String, key: String? = nil, role: ButtonRole? = nil, prominent: Bool = false,
        isBusy: Bool = false, help: String? = nil, action: @escaping () -> Void
    ) {
        self.title = title
        self.key = key
        self.role = role
        self.prominent = prominent
        self.isBusy = isBusy
        self.help = help
        self.action = action
    }

    var body: some View {
        styled(
            Button(role: role, action: action) {
                HStack(spacing: Design.Space.close) {
                    Text(title)
                    Spacer(minLength: Design.Space.step)
                    if isBusy {
                        ProgressView().controlSize(.mini)
                    } else if let key {
                        KeyCap(key)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        )
        .help(help ?? key.map { "\(title) (\($0))" } ?? title)
    }

    @ViewBuilder
    private func styled(_ button: some View) -> some View {
        if prominent {
            button.buttonStyle(.borderedProminent).tint(Design.accentFill)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// A section's kind and where it lies.
struct BeatMatchSectionSummary: View {
    let section: BeatSection

    var body: some View {
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
}
