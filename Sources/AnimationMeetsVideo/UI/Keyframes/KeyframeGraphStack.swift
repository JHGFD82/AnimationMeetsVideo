import CoreMedia
import SwiftUI

/// A graph editor panel's graphs: one parameter's, or several linked into
/// the panel, stacked over one shared stretch of the timeline
/// (`KeyframeGraphLink`). Link With adds another open graph from a menu,
/// and Unlink takes a graph back out into a panel of its own. Linked, the
/// panel has one row of ease presets along the top, acting on the graph
/// last clicked, and one time dial with Fit along the bottom; each graph
/// keeps its own row (its name, values and Unlink) and value dial.
struct KeyframeGraphStack: View {
    let hud: KeyframeGraphHUDs
    let link: KeyframeGraphLink
    let input: GraphInput

    var body: some View {
        VStack(spacing: 0) {
            if link.isLinked {
                presetBar
                Divider()
            }
            ForEach(Array(link.keys.enumerated()), id: \.element) { index, key in
                if index > 0 { Groove() }
                KeyframeGraphView(hud: hud, key: key, input: input, link: link)
            }
            if link.isLinked { timeDial }
        }
    }

    /// The presets, for the active graph's selected keyframe or the one at
    /// the playhead, and Link With.
    private var presetBar: some View {
        HStack(spacing: Design.Space.step) {
            Spacer(minLength: Design.Space.step)
            if let key = link.activeKey, let timeline = hud.project.timeline(id: key.timelineID),
               let value = hud.project.components(of: key), let axis = hud.project.timeAxis(of: key) {
                let target = KeyframeGraphView.presetTarget(
                    selected: link.selected[key], value: value, axis: axis, timeline: timeline, playhead: hud.playhead
                )
                KeyframeEasePresets(hud: hud, key: key, target: target, axis: axis, timeline: timeline, named: true)
            }
            KeyframeGraphLinkMenu(hud: hud, link: link)
        }
        .font(Design.Typeface.label)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.step)
        .padding(.vertical, Design.Space.close)
        .background(Design.Surface.raised.color)
    }

    /// The shared time's dial, under the graphs, with Fit in the corner
    /// under their value dials.
    private var timeDial: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ZoomDial(axis: .horizontal, label: "Time zoom") { factor, held in
                    zoomTimes(by: factor, pinching: held)
                } onReset: {
                    link.viewport.times = nil
                } onRelease: {
                    link.timeBand.endPinch()
                }
                .frame(width: min(ZoomDial.length, max(geometry.size.width - ZoomDial.thickness - 8, 40)))
                Button(action: link.fit) {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                        .font(Design.Typeface.glyphSmall)
                        .foregroundStyle(Design.textSecondary)
                        .frame(width: ZoomDial.thickness, height: ZoomDial.thickness)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fit every graph's keyframes in view")
                .accessibilityLabel("Fit")
            }
        }
        .frame(height: ZoomDial.thickness)
        .background(Color.black.opacity(0.2))
    }

    /// Zooms the shared time about the playhead while it is in view, else
    /// the middle; past the limits the graphs stretch together.
    private func zoomTimes(by factor: Double, pinching: Bool) {
        let project = hud.project
        guard let shown = link.shownTimes(in: project), shown.upperBound > shown.lowerBound else { return }
        let playhead = hud.playhead.seconds
        let anchor = shown.contains(playhead) ? playhead : (shown.lowerBound + shown.upperBound) / 2
        let share = CGFloat((anchor - shown.lowerBound) / (shown.upperBound - shown.lowerBound))
        var band = link.timeBand
        band.zoom(by: factor, about: share, pinching: pinching) { factor in
            link.zoomTimes(by: factor, around: anchor, in: project)
        }
        link.timeBand = band
    }
}

/// Link With: the other open graphs of the timeline, to link into this
/// panel.
struct KeyframeGraphLinkMenu: View {
    let hud: KeyframeGraphHUDs
    let link: KeyframeGraphLink

    var body: some View {
        let candidates = hud.linkCandidates(for: link.id)
        Menu {
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
}
