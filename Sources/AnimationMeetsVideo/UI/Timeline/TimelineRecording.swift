import CoreMedia
import SwiftUI

// Recording takes from the header's record button (see `RecordPopover`).
extension TimelineView {
    func startRecording(_ source: RecordingSource, playing: Bool) {
        guard !isSavingTake, !recorder.isRecording else { return }
        recordError = nil
        let playhead = playheadTime
        recordingTimelineID = timelineID
        // A take over the playing timeline lines up with it, so the loop
        // lets it play straight on until the take stops.
        if playing { playback.loop.isSuspended = true }
        Task {
            do {
                try await recorder.start(source, player: playback.player, from: playhead, playing: playing)
            } catch {
                playback.loop.isSuspended = false
                recordError = error.localizedDescription
            }
        }
    }

    /// Stops the take, keeps its file with the project, and puts it on a
    /// new Sound layer where it was recorded: in the timeline it was
    /// started in, even if another is open now. A failure opens the
    /// popover again to say why, as it may have been closed meanwhile.
    func stopRecording() {
        let take: AudioRecorder.Take
        let timelineID = recordingTimelineID ?? timelineID
        recordingTimelineID = nil
        playback.loop.isSuspended = false
        do {
            take = try recorder.stop()
        } catch {
            failRecording(error)
            return
        }
        // Where the package is now, followed if it was moved (F123).
        let packageURL = ProjectSession.packageNow(renderer?.packageURL)
        isSavingTake = true
        Task {
            defer { isSavingTake = false }
            do {
                let url = try await AudioRecorder.keep(take.url, packageURL: packageURL)
                var clip = try await MediaImporter.importClip(at: url, packageURL: packageURL)
                clip.name = url.deletingPathExtension().lastPathComponent
                host.dispatch(.editProject { $0.addRecording(clip, at: take.start, in: timelineID) })
                showingRecord = false
            } catch {
                failRecording(error)
            }
        }
    }

    private func failRecording(_ error: Error) {
        recordError = error.localizedDescription
        showingRecord = true
    }
}
