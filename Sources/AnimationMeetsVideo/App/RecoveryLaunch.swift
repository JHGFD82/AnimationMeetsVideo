import AppKit

/// A launch without effect packages from outside the app, for when one
/// keeps it from working (docs/effect-packages.md, "Safety"; decision D8):
/// a kernel that stalls the GPU, say, in a project reopened at launch.
/// Holding Shift as the app opens asks for it, or the
/// `disableExternalEffects` setting, given at launch as
/// `open -a AnimationMeetsVideo --args -disableExternalEffects YES`.
enum RecoveryLaunch {
    static func externalEffectsOff(
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags, defaults: UserDefaults = .standard
    ) -> Bool {
        modifiers.contains(.shift) || defaults.bool(forKey: Preferences.disableExternalEffects)
    }
}
