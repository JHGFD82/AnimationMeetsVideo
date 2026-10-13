import SwiftUI

/// A transition being dragged from the panel onto a clip. It travels as an
/// `amv-transition:` URL: like scene drags it needs no registered content
/// type (this app runs unbundled), and being a URL rather than text keeps a
/// clip's transition drop target from catching scenes dropped on the
/// timeline.
struct TransitionDragPayload: Transferable {
    private static let scheme = "amv-transition"

    var kind: TransitionKind

    init(kind: TransitionKind) {
        self.kind = kind
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let kind = TransitionKind(rawValue: String(url.absoluteString.dropFirst(Self.scheme.count + 1)))
        else { return nil }
        self.kind = kind
    }

    var url: URL { URL(string: "\(Self.scheme):\(kind.rawValue)")! }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { $0.url }, importing: { url in
            guard let payload = TransitionDragPayload(url: url) else { throw CocoaError(.coderInvalidValue) }
            return payload
        })
    }
}

/// The transitions that can be dragged onto either end of a clip, shown to
/// the right of the timeline.
struct TransitionsPanel: View {
    let onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Transitions", systemImage: "square.on.square.dashed")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close transitions")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(TransitionKind.allCases) { kind in
                        TransitionTile(kind: kind)
                            .draggable(TransitionDragPayload(kind: kind)) {
                                TransitionTile(kind: kind)
                            }
                    }
                }
                .padding(12)
            }

            Text("Drag onto the start or end of a clip.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 12)
        .background(.background)
    }
}

private struct TransitionTile: View {
    let kind: TransitionKind

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .font(.title2)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)))
            Text(kind.name)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(4)
        .contentShape(Rectangle())
        .help("\(kind.name): drag onto the start or end of a clip")
    }
}
