import SwiftUI

/// A timeline-like view's time zoom: its slider, then zoom out, zoom in and
/// fit, in the order and look the main timeline's header has them. The
/// scene splitter, beat matcher and motion designer all zoom with one, so
/// moving between them nothing has to be found again.
struct ZoomControls: View {
    /// 0 is the farthest zoom; 1 the closest.
    @Binding var fraction: Double
    /// Which keys zoom, for the buttons' help.
    var keys: Keys = .plain
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    /// Fits the view, and what VoiceOver calls doing so.
    var fit: (action: () -> Void, label: String)?

    /// A panel that takes typing (a sheet with fields) zooms with Command;
    /// one that doesn't, with the keys alone, as the timeline does.
    enum Keys {
        case plain, command

        var prefix: String { self == .command ? "⌘" : "" }
        /// The main timeline's fit key is \; the panels' is ⌘0.
        var fit: String { self == .command ? "⌘0" : "\\" }
    }

    var body: some View {
        HStack(spacing: Design.Space.step) {
            ZoomSlider(
                fraction: $fraction, label: "Time zoom",
                help: "Zoom time (pinch, \(keys.prefix)- and \(keys.prefix)=)"
            )
            HStack(spacing: 2) {
                Button(action: zoomOut) { Image(systemName: Design.Symbol.zoomOut) }
                    .help("Zoom out (\(keys.prefix)-)")
                    .accessibilityLabel("Zoom out")
                Button(action: zoomIn) { Image(systemName: Design.Symbol.zoomIn) }
                    .help("Zoom in (\(keys.prefix)=)")
                    .accessibilityLabel("Zoom in")
                if let fit {
                    Button(action: fit.action) { Image(systemName: Design.Symbol.zoomToFit) }
                        .help("\(fit.label) (\(keys.fit))")
                        .accessibilityLabel(fit.label)
                }
            }
            .buttonStyle(.icon)
        }
    }
}
