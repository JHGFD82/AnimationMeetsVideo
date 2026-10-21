import Foundation

/// What the app remembers between launches, by its `UserDefaults` key.
///
/// These are the person's, not the project's: they hold for every project
/// and live in the app's defaults, not in `project.json`. Each key used to
/// be a string literal at the view that read it, and some views read the
/// same key under the same literal twice. The Settings window and the
/// panels now name them here, so they can't drift apart.
enum Preferences {
    // MARK: Viewer

    /// A `PreviewQuality` raw value.
    static let previewQuality = "previewQuality"
    static let motionBlurInPreview = "motionBlurInPreview"

    // MARK: Timeline

    static let snapping = "snapping"
    static let followsPlayhead = "followsPlayhead"
    static let clickOnBeats = "clickOnBeats"

    // MARK: Library

    /// The `LookRecipes.version` last written into the Presets folder.
    static let recipesInstalled = "recipesInstalled"

    /// A `ThumbnailInterval` raw value.
    static let thumbnailInterval = "browserThumbnailInterval"
    /// A `ThumbnailSize` raw value.
    static let thumbnailSize = "browserThumbnailSize"

    // MARK: Layout

    static let timelineHeight = "timelineHeight"
    static let browserWidth = "browserWidth"
    static let inspectorPanelWidth = "inspectorPanelWidth"
    static let effectsPanelWidth = "effectsPanelWidth"
    static let showsSidePanel = "showsSidePanel"
    static let sidePanelTab = "sidePanelTab"
    static let showsEffectsLibrary = "showsEffectsLibrary"
    static let effectsLibraryTab = "effectsLibraryTab"
    static let showsAudioMeter = "showsAudioMeter"
    /// An `EqualizerSpectrumMode` raw value: what an EQ's graph shows
    /// behind its curves.
    static let equalizerSpectrum = "equalizerSpectrum"
    /// The UID of the device the editor's sound plays out of; empty or
    /// absent for the system's default (see `AudioDevices`).
    static let playbackOutputDevice = "playbackOutputDevice"
    /// The UID of the device the beat tick plays out of; empty or absent
    /// for the same as the editor's sound.
    static let clickOutputDevice = "clickOutputDevice"
    /// Whether moving the playhead while paused, or skimming the timeline,
    /// plays the sound under it.
    static let scrubAudio = "scrubAudio"
    /// Whether the timeline's frame under the pointer shows in the viewer
    /// as the pointer moves over it, without moving the playhead. Off
    /// unless turned on.
    static let timelineSkimming = "timelineSkimming"
    /// Whether a clip's frame under the pointer shows in the viewer as the
    /// pointer moves over its filmstrip in the browser.
    static let browserSkimming = "browserSkimming"
    /// Whether skimming a clip in the browser plays its sound under the
    /// pointer.
    static let browserSkimAudio = "browserSkimAudio"
    /// Whether the timeline plays while a take is recorded.
    static let recordWhilePlaying = "recordWhilePlaying"
    /// What takes are recorded from (see `RecordPopover`).
    static let recordingSource = "recordingSource"
    /// Whether movie exports carry each layer's stem after the mix
    /// (`ExportAudioTracks`).
    static let exportAudioTracks = "exportAudioTracks"
    /// The `LoudnessTarget` exports are delivered at.
    static let exportLoudness = "exportLoudness"
    static let browserTab = "browserTab"
    static let timelineAreaLayout = "timelineAreaLayout"
    static let effectsPanelShowsKeyframeLanes = "effectsPanelShowsKeyframeLanes"

    /// Everything about where the panels are and how big: their sizes,
    /// which are open and on which tab, and the timeline's areas.
    static let layoutKeys = [
        timelineHeight, browserWidth, inspectorPanelWidth, effectsPanelWidth,
        showsSidePanel, sidePanelTab, showsEffectsLibrary, effectsLibraryTab,
        showsAudioMeter, browserTab, timelineAreaLayout, effectsPanelShowsKeyframeLanes,
    ]

    /// Puts the panels back as a first launch has them. Views read these
    /// through `@AppStorage`, which falls back to its default once the
    /// key is gone, so an open window rearranges at once.
    static func resetLayout(in defaults: UserDefaults = .standard) {
        for key in layoutKeys { defaults.removeObject(forKey: key) }
    }

    /// Whether any panel has been moved, resized, opened or closed.
    static func hasCustomLayout(in defaults: UserDefaults = .standard) -> Bool {
        layoutKeys.contains { defaults.object(forKey: $0) != nil }
    }
}
