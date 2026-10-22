import SwiftUI

/// A graph editor panel's graphs: one parameter's, or several linked into
/// the panel, stacked over one shared stretch of the timeline
/// (`KeyframeGraphLink`). Dragging another graph panel by its title bar
/// onto this one links its graphs in; while it is over this one, an
/// outline says whether letting go will. Link With does the same from a
/// menu, and Unlink takes a graph back out into a panel of its own.
struct KeyframeGraphStack: View {
    let hud: KeyframeGraphHUDs
    let link: KeyframeGraphLink
    let input: GraphInput

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(link.keys.enumerated()), id: \.element) { index, key in
                if index > 0 { Groove() }
                header(key, first: index == 0)
                KeyframeGraphView(hud: hud, key: key, input: input, link: link.isLinked ? link : nil)
            }
        }
        .overlay { dropIndicator }
    }

    /// The graph's name when linked, with Unlink; the first row also has
    /// Link With.
    private func header(_ key: ParameterKey, first: Bool) -> some View {
        HStack(spacing: Design.Space.step) {
            if link.isLinked {
                Text(hud.project.parameterTitle(of: key))
                    .font(Design.Typeface.groupTitle)
                    .foregroundStyle(Design.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Drag another graph's panel here to link their time")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Design.Space.step)
            if first { linkMenu }
            if link.isLinked {
                Button("Unlink") { hud.unlink(key, from: link.id) }
                    .help("Take this graph out into a panel of its own")
                    .accessibilityLabel("Unlink \(hud.project.parameterTitle(of: key))")
            }
        }
        .font(Design.Typeface.label)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.step)
        .padding(.vertical, 3)
        .background(Design.Surface.raised.color)
    }

    /// The other open graphs this panel's can link with.
    private var linkMenu: some View {
        let candidates = hud.linkCandidates(for: link.id)
        return Menu {
            ForEach(candidates, id: \.id) { candidate in
                Button(candidate.title) { hud.link(candidate.id, into: link.id) }
            }
        } label: {
            Image(systemName: "link")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(candidates.isEmpty)
        .help(candidates.isEmpty ? "Open another graph of this timeline to link it here" : "Link another open graph into this panel")
        .accessibilityLabel("Link with another graph")
    }

    /// While another graph panel is dragged over this one: an outline in
    /// the accent and what letting go will do, or why it won't.
    @ViewBuilder
    private var dropIndicator: some View {
        if let target = hud.dropTarget, target.link == link.id {
            let tone = target.allowed ? Design.accent : Design.statusDanger
            ZStack {
                tone.opacity(0.12)
                RoundedRectangle(cornerRadius: Design.Radius.chip)
                    .strokeBorder(tone, lineWidth: 3)
                Label(
                    target.allowed ? "Release to link these graphs on one timeline" : "Graphs of different timelines can't be linked",
                    systemImage: target.allowed ? "link" : "nosign"
                )
                .font(Design.Typeface.bodyEmphasis)
                .foregroundStyle(Design.textPrimary)
                .padding(.horizontal, Design.Space.rail)
                .padding(.vertical, Design.Space.step)
                .floatingSurface(radius: Design.Radius.chip)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}
