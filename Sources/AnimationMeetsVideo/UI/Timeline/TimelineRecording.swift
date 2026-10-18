import CoreMedia
import SwiftUI

// Recording takes from the header's record button (see `RecordPopover`).
extension TimelineView {
    func startRecording(_ source: RecordingSource, playing: Bool) {
        recordError = nil
        let playhead = playheadTime
        Task {
            do {
                try await recorder.start(source, player: playback.player, from: playhead, playing: playing)
            } catch {
                recordError = error.localizedDescription
            }
        }
    }

    /// Stops the take, keeps its file with the project, and puts it on a
    /// new Sound layer where it was recorded.
    func stopRecording() {
        let take: AudioRecorder.Take
        do {
            take = try recorder.stop()
        } catch {
            recordError = error.localizedDescription
            return
        }
        let packageURL = renderer?.packageURL
        let timelineID = timelineID
        Task {
            do {
                let url = try await AudioRecorder.keep(take.url, packageURL: packageURL)
                var clip = try await MediaImporter.importClip(at: url)
                clip.name = url.deletingPathExtension().lastPathComponent
                onEditProject { $0.addRecording(clip, at: take.start, in: timelineID) }
                showingRecord = false
            } catch {
                recordError = error.localizedDescription
            }
        }
    }
}
