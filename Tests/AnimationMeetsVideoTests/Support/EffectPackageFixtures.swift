import Foundation
@testable import AnimationMeetsVideo

/// Writes an effect package: `manifest` as its effect.json, and `kernel` as
/// its kernel.metal. Approved to run for this test run, as written
/// (`EffectApproval`, never saved), unless `approved` is false: the
/// packages tests write stand for ones the person approved, but for the
/// tests of approval itself.
@discardableResult
func writeEffectPackage(_ manifest: [String: Any], kernel: String, in folder: URL, named name: String, approved: Bool = true) throws -> URL {
    let url = folder.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    try data.write(to: url.appending(path: "effect.json"))
    try kernel.write(to: url.appending(path: "kernel.metal"), atomically: true, encoding: .utf8)
    if approved { EffectApproval.shared.approveInSession(hash: EffectPackage.approvalHash(data, kernel)) }
    return url
}

/// The manifest of a one-kernel package `id`, recolor by default.
func effectManifest(
    _ id: String, function: String, type: String = "color", controls: [[String: Any]] = [], arguments: [String] = [],
    extra: [String: Any] = [:]
) -> [String: Any] {
    [
        "formatVersion": 1, "id": id, "version": 1, "name": id, "category": "recolor", "symbol": "sparkles",
        "kernel": ["file": "kernel.metal", "function": function, "type": type],
        "controls": controls, "arguments": arguments,
    ].merging(extra) { _, new in new }
}
