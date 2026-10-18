import AVFoundation
import CoreMedia
import Foundation
import Observation

/// Records a take from an input device or an app while the timeline plays,
/// and works out where it belongs on the timeline. See docs/audio.md,
/// "Recording".
@MainActor
@Observable
final class AudioRecorder {
    /// A finished take: its file, and where on the timeline its first
    /// sample belongs.
    struct Take: Equatable {
        var url: URL
        var start: CMTime
    }

    private(set) var isRecording = false
    /// How long the take is so far.
    private(set) var seconds: Double = 0
    /// The loudest recent sample, 0...1, for a level meter.
    private(set) var level: Float = 0

    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var writer: TakeWriter?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var playedPlayer: AVPlayer?
    @ObservationIgnored private var playhead = CMTime.zero

    /// Starts recording `source`. With `playing`, the timeline plays from
    /// the playhead while it records, and the take lands where it was
    /// heard; otherwise it lands at the playhead.
    func start(_ source: RecordingSource, player: AVPlayer, from playhead: CMTime, playing: Bool) async throws {
        guard !isRecording else { return }
        if case .input = source, !(await Self.microphoneAllowed()) { throw RecordingError.microphoneDenied }
        let capture = try source.makeCapture()
        let url = FileManager.default.temporaryDirectory.appending(path: "Recording-\(UUID().uuidString).caf")

        let anchor: @Sendable (UInt64) -> CMTime?
        let timebase = playing ? player.currentItem?.timebase : nil
        if let timebase {
            // Each buffer is stamped when it reached the computer; the
            // sound was made `latency` before that. Until the timeline is
            // moving there is nothing to line it up with.
            let held = HandedOver(value: timebase)
            let latency = AVAudioTime.hostTime(forSeconds: capture.latency)
            anchor = { host in
                let timebase = held.value
                guard CMTimebaseGetRate(timebase) > 0 else { return nil }
                let made = CMClockMakeHostTimeFromSystemUnits(host > latency ? host - latency : host)
                return CMSyncConvertTime(made, from: CMClockGetHostTimeClock(), to: timebase)
            }
        } else {
            anchor = { _ in playhead }
        }
        let writer = try TakeWriter(url: url, format: capture.format, anchor: anchor)
        do {
            try capture.start(writing: writer)
        } catch {
            writer.finish()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        self.capture = capture
        self.writer = writer
        self.playhead = playhead
        isRecording = true
        seconds = 0
        if timebase != nil {
            player.play()
            playedPlayer = player
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let writer = self.writer else { return }
                self.seconds = writer.seconds
                self.level = writer.takePeak()
            }
        }
    }

    /// Stops recording and returns the take, or throws when nothing came in.
    func stop() throws -> Take {
        guard isRecording, let capture, let writer else { throw RecordingError.nothingRecorded }
        capture.stop()
        writer.finish()
        playedPlayer?.pause()
        timer?.invalidate()
        timer = nil
        self.capture = nil
        self.writer = nil
        playedPlayer = nil
        isRecording = false
        level = 0
        guard writer.seconds > 0 else {
            try? FileManager.default.removeItem(at: writer.url)
            throw RecordingError.nothingRecorded
        }
        // A take that started before the timeline does is put at its start.
        return Take(url: writer.url, start: CMTimeMaximum(.zero, writer.start ?? playhead))
    }

    /// Moves a take's file to where it is kept: the project's Media folder,
    /// or for a project not saved yet a Recordings folder in Music. Named
    /// for when it was recorded.
    static func keep(_ take: URL, packageURL: URL?, recordedAt date: Date = Date()) async throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let named = take.deletingLastPathComponent().appending(path: "Recording \(formatter.string(from: date)).caf")
        try FileManager.default.moveItem(at: take, to: named)
        if let packageURL {
            defer { try? FileManager.default.removeItem(at: named) }
            return try await PackageCoordinator.shared.run(on: [packageURL]) {
                try ProjectStore.copyIntoPackage(named, packageURL: packageURL)
            }
        }
        let folder = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appending(path: "Animation Meets Video/Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: named.lastPathComponent)
        try FileManager.default.moveItem(at: named, to: destination)
        return destination
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

extension EditingProject {
    /// Puts a recorded take on a new Sound layer at the top of its area,
    /// starting at `start`. Returns the new layer.
    @discardableResult
    mutating func addRecording(_ clip: MediaClip, at start: CMTime, in timelineID: UUID) -> UUID? {
        addMedia(clip)
        let piece = MediaPiece(assetID: clip.id, start: .zero, end: clip.duration)
        return addPieces([piece], intoTimeline: timelineID, at: start, kind: .sound)?.layerID
    }
}
