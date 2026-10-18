import CoreMedia
import SwiftUI

/// Recording a take onto the timeline, from the record button in the
/// timeline's header: what to record from (an input device, or an app's
/// sound), whether the timeline plays meanwhile, and Record and Stop with
/// the take's length and level. The take lands on a new Sound layer. See
/// docs/audio.md, "Recording".
struct RecordPopover: View {
    let recorder: AudioRecorder
    /// Starts the take, with what to record from and whether to play.
    let onRecord: (RecordingSource, Bool) -> Void
    let onStop: () -> Void
    /// Why the last take failed, if it did.
    let error: String?

    @AppStorage(Preferences.recordWhilePlaying) private var playsTimeline = true
    @State private var devices = AudioDeviceList()
    @State private var apps: [AudioApp] = []
    /// What to record from, by a key that survives the lists refreshing:
    /// "input:" and a device UID (none for the default), or "app:" and an
    /// app's path.
    @AppStorage(Preferences.recordingSource) private var sourceKey = "input:"

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.group + 2) {
            SheetSection("Record from") {
                Picker("Record from", selection: $sourceKey) {
                    Section("Inputs") {
                        Text("Default Input").tag("input:")
                        ForEach(devices.inputs) { device in
                            Text(device.name).tag("input:\(device.uid)")
                        }
                    }
                    Section("Apps") {
                        ForEach(apps) { app in
                            Text(app.isPlaying ? "\(app.name) (playing)" : app.name).tag("app:\(app.id)")
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(recorder.isRecording)
                Toggle("Play the timeline while recording", isOn: $playsTimeline)
                    .disabled(recorder.isRecording)
                    .help("On, the timeline plays from the playhead and the take lands where you heard it; off, it lands at the playhead")
                if sourceKey.hasPrefix("app:") {
                    SheetNote("The first time, macOS asks whether Animation Meets Video may record other apps' sound.")
                }
            }

            Groove()

            HStack(spacing: Design.Space.step) {
                if recorder.isRecording {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                    Text(Self.duration(recorder.seconds))
                        .font(Design.Typeface.numericMicro)
                        .foregroundStyle(Design.textPrimary)
                        .accessibilityLabel("Recorded \(Int(recorder.seconds)) seconds")
                    LevelBar(level: recorder.level)
                } else {
                    Button {
                        if let source { onRecord(source, playsTimeline) }
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(source == nil)
                }
            }
            if let error {
                Text(error)
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.statusDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Design.Space.rail)
        .frame(width: 300)
        .onAppear { apps = AudioApps.list() }
    }

    /// The chosen source, if it is still there.
    private var source: RecordingSource? {
        if sourceKey.hasPrefix("input:") {
            let uid = String(sourceKey.dropFirst("input:".count))
            return .input(uid: uid.isEmpty ? nil : uid)
        }
        let path = String(sourceKey.dropFirst("app:".count))
        return apps.first { $0.id == path }.map(RecordingSource.app)
    }

    /// "0:07" or "1:02:07".
    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// How loud the take is coming in, on the meter's decibel scale.
private struct LevelBar: View {
    let level: Float

    var body: some View {
        let decibels = MeterBallistics.decibels(level)
        let fraction = (decibels - MeterBallistics.floor) / -MeterBallistics.floor
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Design.Surface.well.color)
                Capsule()
                    .fill(decibels > -6 ? Design.statusDanger : decibels > -18 ? Design.statusWarning : Design.statusDone)
                    .frame(width: geometry.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(decibels <= MeterBallistics.floor ? "silent" : "\(Int(decibels.rounded())) decibels")
    }
}
