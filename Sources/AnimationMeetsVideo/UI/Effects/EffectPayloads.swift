import Foundation
import SwiftUI

/// Things dragged around the effects panel. Like scene and transition
/// drags they travel as URLs: this app runs unbundled, so they need no
/// registered content type, and being URLs keeps one kind of drop target
/// from catching another kind of drag.
private func payloadURL(_ scheme: String, _ parts: [String]) -> URL {
    URL(string: "\(scheme):\(parts.joined(separator: ":"))")!
}

private func payloadParts(_ url: URL, scheme: String) -> [String]? {
    guard url.scheme == scheme else { return nil }
    return url.absoluteString.dropFirst(scheme.count + 1).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
}

/// A library effect being dragged onto a clip or into a stack.
struct EffectDragPayload: Transferable {
    private static let scheme = "amv-effect"

    var kind: EffectKind

    init(kind: EffectKind) {
        self.kind = kind
    }

    init?(url: URL) {
        guard let parts = payloadParts(url, scheme: Self.scheme), parts.count == 1,
              let kind = EffectKind(rawValue: parts[0])
        else { return nil }
        self.kind = kind
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { payloadURL(scheme, [$0.kind.rawValue]) }, importing: { url in
            guard let payload = EffectDragPayload(url: url) else { throw CocoaError(.coderInvalidValue) }
            return payload
        })
    }
}

/// An effect of the stack being dragged to a new place in it.
struct EffectMovePayload: Transferable {
    private static let scheme = "amv-effect-move"

    var clipID: UUID
    var effectID: UUID

    init(clipID: UUID, effectID: UUID) {
        self.clipID = clipID
        self.effectID = effectID
    }

    init?(url: URL) {
        guard let parts = payloadParts(url, scheme: Self.scheme), parts.count == 2,
              let clip = UUID(uuidString: parts[0]), let effect = UUID(uuidString: parts[1])
        else { return nil }
        clipID = clip
        effectID = effect
    }

    var url: URL { payloadURL(Self.scheme, [clipID.uuidString, effectID.uuidString]) }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.url, importing: { url in
            guard let payload = EffectMovePayload(url: url) else { throw CocoaError(.coderInvalidValue) }
            return payload
        })
    }
}

/// A control being dragged to a new place within its effect.
struct ControlMovePayload: Transferable {
    private static let scheme = "amv-control-move"

    var clipID: UUID
    var effectID: UUID
    var controlID: UUID

    init(clipID: UUID, effectID: UUID, controlID: UUID) {
        self.clipID = clipID
        self.effectID = effectID
        self.controlID = controlID
    }

    init?(url: URL) {
        guard let parts = payloadParts(url, scheme: Self.scheme), parts.count == 3,
              let clip = UUID(uuidString: parts[0]), let effect = UUID(uuidString: parts[1]), let control = UUID(uuidString: parts[2])
        else { return nil }
        clipID = clip
        effectID = effect
        controlID = control
    }

    var url: URL { payloadURL(Self.scheme, [clipID.uuidString, effectID.uuidString, controlID.uuidString]) }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(
            exporting: \.url,
            importing: { url in
                guard let payload = ControlMovePayload(url: url) else { throw CocoaError(.coderInvalidValue) }
                return payload
            }
        )
    }
}

/// A preset being dragged from the Effects Library onto a clip or into a stack. It
/// carries the preset's ID, which is its file's name.
struct PresetDragPayload: Transferable {
    private static let scheme = "amv-preset"

    var presetID: String

    init(presetID: String) {
        self.presetID = presetID
    }

    init?(url: URL) {
        guard let parts = payloadParts(url, scheme: Self.scheme), parts.count == 1,
              let id = parts[0].removingPercentEncoding, !id.isEmpty
        else { return nil }
        presetID = id
    }

    /// The ID is percent-encoded, since file names have spaces and colons.
    var url: URL {
        payloadURL(Self.scheme, [presetID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""])
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(
            exporting: { $0.url },
            importing: { url in
                guard let payload = PresetDragPayload(url: url) else { throw CocoaError(.coderInvalidValue) }
                return payload
            }
        )
    }
}

/// Any of the app's own drags, for a view that takes more than one kind.
///
/// Every payload travels as a URL, so SwiftUI sees one content type for
/// all of them: of several `dropDestination`s on one view only one ever
/// receives a drop, and a drag of another kind fails to decode there and
/// is refused. Such a view takes this instead and asks which kind it got.
struct ClipDropPayload: Transferable {
    let url: URL

    var transition: TransitionDragPayload? { TransitionDragPayload(url: url) }
    var effect: EffectDragPayload? { EffectDragPayload(url: url) }
    var effectMove: EffectMovePayload? { EffectMovePayload(url: url) }
    var controlMove: ControlMovePayload? { ControlMovePayload(url: url) }
    var preset: PresetDragPayload? { PresetDragPayload(url: url) }
    /// A file dragged in from the Finder.
    var file: URL? { url.isFileURL ? url : nil }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.url, importing: { ClipDropPayload(url: $0) })
    }
}
