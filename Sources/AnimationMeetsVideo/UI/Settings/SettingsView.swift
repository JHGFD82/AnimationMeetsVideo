import AVFoundation
import SwiftUI

/// The app's Settings window (⌘,): how the editor behaves for every
/// project. What belongs to one project is in File > Project Settings.
///
/// Each setting here is also where it is used — the viewer's options
/// menu, the timeline's view options, the library's thumbnail popover —
/// so it can be changed without leaving the work. This is where all of
/// them can be found at once, and the only place to put the panels back.
/// Both read the same `Preferences` keys, so a change in either shows in
/// the other at once.
struct SettingsView: View {
    enum Tab: String, Hashable {
        case viewer, timeline, sound, library, projects, layout
    }

    @AppStorage("settingsTab") private var tab = Tab.viewer

    var body: some View {
        TabView(selection: $tab) {
            ViewerSettings()
                .tabItem { Label("Viewer", systemImage: "play.rectangle") }
                .tag(Tab.viewer)
            TimelineSettings()
                .tabItem { Label("Timeline", systemImage: "timeline.selection") }
                .tag(Tab.timeline)
            SoundSettings()
                .tabItem { Label("Sound", systemImage: "speaker.wave.2") }
                .tag(Tab.sound)
            LibrarySettings()
                .tabItem { Label("Browser", systemImage: "photo.on.rectangle") }
                .tag(Tab.library)
            ProjectsSettings()
                .tabItem { Label("Projects", systemImage: "externaldrive") }
                .tag(Tab.projects)
            LayoutSettings()
                .tabItem { Label("Layout", systemImage: "rectangle.3.group") }
                .tag(Tab.layout)
        }
        .frame(width: Design.SheetWidth.standard)
        .background(Design.Surface.floating.color)
        .preferredColorScheme(.dark)
        .tint(Design.accent)
    }
}

/// One tab's options, laid out as the dialogs lay theirs out.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.group + 2) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Design.Space.sheet)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Viewer

private struct ViewerSettings: View {
    @AppStorage(Preferences.previewQuality) private var quality = PreviewQuality.auto
    @AppStorage(Preferences.motionBlurInPreview) private var motionBlur = true

    var body: some View {
        SettingsPane {
            SheetSection("Preview") {
                SheetRow("Quality") {
                    Picker("Preview quality", selection: $quality) {
                        ForEach(PreviewQuality.allCases) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SheetNote("Auto draws full size when paused and as large as keeps up while playing. Export always draws full size.")
                SheetRow("Motion blur", alignment: .center) {
                    Toggle("Draw in the viewer", isOn: $motionBlur)
                }
                SheetNote("Off, the viewer draws frames without motion blur, which is quicker. Export and background renders always draw it.")
            }
        }
    }
}

// MARK: - Timeline

private struct TimelineSettings: View {
    @AppStorage(Preferences.snapping) private var snapping = true
    @AppStorage(Preferences.followsPlayhead) private var followsPlayhead = true
    @AppStorage(Preferences.timelineSkimming) private var skimming = true
    @AppStorage(Preferences.clickOnBeats) private var clickOnBeats = false
    @AppStorage(ClickToneSettings.frequencyKey) private var frequency = ClickToneSettings.defaultFrequency
    @AppStorage(ClickToneSettings.volumeKey) private var volume = ClickToneSettings.defaultVolume
    /// Made on the first preview: a tick needs an audio engine, and most
    /// visits here never play one.
    @State private var tick: BeatClickPlayer?

    var body: some View {
        SettingsPane {
            SheetSection("Editing") {
                SheetRow("Snapping", alignment: .center) {
                    Toggle("Snap edges", isOn: $snapping)
                        .accessibilityHint("Edges snap to clips, the playhead and beat markers")
                }
                SheetNote("Edges snap to clips, the playhead and beat markers. N turns it on and off.")
                SheetRow("Playback", alignment: .center) {
                    Toggle("Follow the playhead", isOn: $followsPlayhead)
                }
                SheetNote("When zoomed in, the view turns a page each time playback runs off its edge.")
                SheetRow("Skimming", alignment: .center) {
                    Toggle("Show the frame under the pointer", isOn: $skimming)
                }
                SheetNote("While paused, moving the pointer over the timeline shows its frames in the viewer, and the playhead stays put. Space plays from there. Also in the Timeline menu.")
            }
            Groove()
            SheetSection("Beat tick") {
                SheetRow("Timeline", alignment: .center) {
                    Toggle("Tick on beats while playing", isOn: $clickOnBeats)
                }
                SheetRow("Sound", alignment: .top) {
                    ClickToneControls(frequency: $frequency, volume: $volume, onPreview: preview)
                }
                SheetNote("The same tick plays in Beat Match. Downbeats play an octave higher.")
            }
        }
    }

    private func preview() {
        let player = tick ?? BeatClickPlayer(player: AVPlayer())
        tick = player
        player.frequency = frequency
        player.volume = Float(volume)
        player.preview()
    }
}

// MARK: - Sound

private struct SoundSettings: View {
    @AppStorage(Preferences.playbackOutputDevice) private var playbackDevice = ""
    @AppStorage(Preferences.clickOutputDevice) private var clickDevice = ""
    @AppStorage(Preferences.scrubAudio) private var scrubAudio = true
    @AppStorage(Preferences.browserSkimAudio) private var browserSkimAudio = true
    @AppStorage(Preferences.browserSkimming) private var browserSkimming = true
    @State private var list = AudioDeviceList()

    var body: some View {
        SettingsPane {
            SheetSection("Output") {
                SheetRow("Playback", alignment: .center) {
                    devicePicker("Playback output", selection: $playbackDevice, automatic: "System Default")
                }
                SheetRow("Beat tick", alignment: .center) {
                    devicePicker("Beat tick output", selection: $clickDevice, automatic: "Same as Playback")
                }
                SheetNote("Play the timeline on the room's speakers and the tick only in your headphones, say. A device that is unplugged plays out of the system's default until it is back.")
            }
            Groove()
            SheetSection("Scrubbing") {
                SheetRow("Timeline", alignment: .center) {
                    Toggle("Play the sound under the playhead as it moves", isOn: $scrubAudio)
                }
                SheetNote("While paused, dragging or stepping the playhead, or skimming, plays a moment of the mix at each place it stops. Also Scrub Audio in the Timeline menu.")
                SheetRow("Browser", alignment: .center) {
                    Toggle("Play a clip's sound as it is skimmed", isOn: $browserSkimAudio)
                        .disabled(!browserSkimming)
                }
                SheetNote("Skimming a filmstrip plays a moment of the clip's own sound at each frame, while skimming is on (Browser tab). Also in the browser's view options.")
            }
        }
    }

    /// The devices to choose from, with the automatic choice first and a
    /// chosen device that is unplugged kept, marked, so it isn't lost.
    private func devicePicker(_ label: String, selection: Binding<String>, automatic: String) -> some View {
        Picker(label, selection: selection) {
            Text(automatic).tag("")
            Divider()
            ForEach(list.devices) { device in
                Text(device.name).tag(device.uid)
            }
            if !selection.wrappedValue.isEmpty, !list.devices.contains(where: { $0.uid == selection.wrappedValue }) {
                Text("Unplugged Device").tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 280, alignment: .leading)
    }
}

// MARK: - Library

private struct LibrarySettings: View {
    @AppStorage(Preferences.thumbnailInterval) private var interval = ThumbnailInterval.all
    @AppStorage(Preferences.thumbnailSize) private var size = ThumbnailSize.medium
    @AppStorage(Preferences.browserSkimming) private var skimming = true
    @AppStorage(Preferences.browserMutesAddedSound) private var mutesAddedSound = false

    var body: some View {
        SettingsPane {
            SheetSection("Skimming") {
                SheetRow("Browser", alignment: .center) {
                    Toggle("Show the frame under the pointer", isOn: $skimming)
                }
                SheetNote("Moving the pointer over a clip shows its frames in the viewer. Off, click a clip to show the frame clicked. Also in the browser's view options.")
            }
            Groove()
            SheetSection("Thumbnails") {
                SheetRow("Size") {
                    Picker("Thumbnail size", selection: $size) {
                        ForEach(ThumbnailSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SheetRow("One every") {
                    Picker("Time per thumbnail", selection: $interval) {
                        ForEach(Array(ThumbnailInterval.allCases.reversed())) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SheetNote("More thumbnails show more of each clip, as a filmstrip, and take longer to draw.")
            }
            Groove()
            SheetSection("Adding to a Timeline") {
                SheetRow("Sound", alignment: .center) {
                    Toggle("Mute a video's sound when it is added", isOn: $mutesAddedSound)
                }
                SheetNote("The clip keeps its sound, muted: unmute it from the clip's menu, or detach it and it plays on a sound layer of its own. Also in the browser's view options.")
            }
        }
    }
}

// MARK: - Projects

private struct ProjectsSettings: View {
    @AppStorage(Preferences.savesAutomatically) private var savesAutomatically = true
    @AppStorage(Preferences.backsUpProjects) private var backsUp = true
    @AppStorage(Preferences.backupLocation) private var backupPath = ""
    @AppStorage(Preferences.backupInterval) private var backupMinutes = 15

    private var backupLocation: URL {
        backupPath.isEmpty ? ProjectBackups.defaultLocation : URL(fileURLWithPath: backupPath, isDirectory: true)
    }

    /// The folder as people read paths: the home folder as ~.
    private var backupLocationText: String {
        let path = backupLocation.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        SettingsPane {
            SheetSection("Saving") {
                SheetRow("Projects", alignment: .center) {
                    Toggle("Save after every change", isOn: $savesAutomatically)
                        .accessibilityHint("Each edit is written to the project as soon as it is made")
                }
                SheetNote(savesAutomatically
                    ? "Each edit is written to the project a moment after it is made, as Final Cut Pro saves, so there is nothing to remember to save. A drag is saved when it ends. Undo still steps back through every edit."
                    : "The project is written only when you choose Save. Closing a window or quitting asks about unsaved changes, and an autosave in the project's Backups folder is offered back after a crash.")
            }
            Groove()
            SheetSection("Backups") {
                SheetRow("Backups", alignment: .center) {
                    Toggle("Back up projects", isOn: $backsUp)
                        .accessibilityHint("Keeps copies of each open project in the backup folder")
                }
                SheetRow("Folder", alignment: .top) {
                    VStack(alignment: .leading, spacing: Design.Space.close) {
                        Text(backupLocationText)
                            .font(Design.Typeface.body)
                            .foregroundStyle(Design.textPrimary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .help(backupLocation.path)
                            .accessibilityLabel("Backup folder, \(backupLocationText)")
                        HStack(spacing: Design.Space.step) {
                            // Named in full for VoiceOver, which reads them
                            // without the row's label.
                            Button("Choose…", action: chooseBackupLocation)
                                .accessibilityLabel("Choose backup folder")
                            Button("Show in Finder") {
                                try? FileManager.default.createDirectory(at: backupLocation, withIntermediateDirectories: true)
                                NSWorkspace.shared.activateFileViewerSelecting([backupLocation])
                            }
                            .accessibilityLabel("Show backup folder in Finder")
                        }
                    }
                }
                .disabled(!backsUp)
                SheetRow("Every", alignment: .center) {
                    Picker("Back up every", selection: $backupMinutes) {
                        ForEach(Preferences.backupIntervals, id: \.self) { minutes in
                            Text(minutes < 60 ? "\(minutes) minutes" : "hour").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Back up every")
                }
                .disabled(!backsUp)
                SheetNote("While a project changes, a backup of it (its edits, the media copied into it and what was learned about each file) goes to its own folder here, and the newest \(ProjectBackups.kept) are kept. Unchanged files are cloned from the backup before, so after the first one each costs only what changed. A folder on another disk survives that disk failing; one on the project's disk costs nothing. Double-click a backup to make a new project from it, beside the original, which is left as it is.")
            }
        }
    }

    private func chooseBackupLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = backupLocation
        panel.prompt = "Choose"
        panel.message = "Choose where project backups go."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupPath = url.path
    }
}

// MARK: - Layout

private struct LayoutSettings: View {
    @State private var isCustom = Preferences.hasCustomLayout()

    var body: some View {
        SettingsPane {
            SheetSection("Panels") {
                SheetRow("Arrangement", alignment: .center) {
                    Button("Reset Panel Layout") {
                        Preferences.resetLayout()
                        isCustom = false
                    }
                    .disabled(!isCustom)
                }
                SheetNote("Puts every panel back to its first-launch size and place: the browser, inspector, effects and timeline, which are open, and the timeline's areas and layer heights. Projects are untouched. Also in the Window menu.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            isCustom = Preferences.hasCustomLayout()
        }
    }
}
