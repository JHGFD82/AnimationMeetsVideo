import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Times the backups `ProjectBackups` keeps beside a package, on the
/// volume of the folder `BACKUP_BENCHMARK` names, for a package holding
/// `BACKUP_BENCHMARK_MB` megabytes of media (1,024 by default): the first
/// backup, a second with nothing changed, and a save asked for while a
/// backup runs, which waits behind it in the `PackageCoordinator`. On
/// APFS each file after the first backup is a clone; elsewhere every
/// backup copies the media again (code-review-notes.md, F73). Prints the
/// times and asserts nothing, since they depend on the disk.
///
///     hdiutil create -size 8g -fs HFS+ -volname AMVBackups -type SPARSE /tmp/amv.sparseimage
///     hdiutil attach /tmp/amv.sparseimage
///     BACKUP_BENCHMARK=/Volumes/AMVBackups swift test --filter BackupCostBenchmark
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BACKUP_BENCHMARK"] != nil))
struct BackupCostBenchmark {
    private static let environment = ProcessInfo.processInfo.environment
    private static let megabytes = max(1, Int(environment["BACKUP_BENCHMARK_MB"] ?? "") ?? 1024)

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test func backupsAndASaveBehindOne() async throws {
        let base = URL(filePath: try #require(Self.environment["BACKUP_BENCHMARK"]), directoryHint: .isDirectory)
        let folder = base.appending(path: "amv-backup-benchmark-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = folder.appending(path: "Cut.amv", directoryHint: .isDirectory)
        try ProjectStore.preparePackage(at: package)

        // Media of the size asked for, in 64 MB files of random bytes, so
        // nothing compresses or deduplicates them.
        var project = EditingProject.empty
        let chunk = 64
        for index in 0..<max(1, Self.megabytes / chunk) {
            let file = package.appending(path: "\(ProjectStore.mediaFolderName)/part \(index).wav")
            var bytes = Data(count: min(chunk, Self.megabytes) * 1_048_576)
            bytes.withUnsafeMutableBytes { raw in
                for offset in stride(from: 0, to: raw.count, by: 8) {
                    raw.storeBytes(of: UInt64.random(in: .min ... .max), toByteOffset: offset, as: UInt64.self)
                }
            }
            try bytes.write(to: file)
            project.addMedia(MediaClip(
                name: "part \(index)", kind: .audio, url: file, duration: CMTime(value: 1, timescale: 1),
                frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true
            ))
        }
        try await ProjectStore.save(project, to: package)
        let volume = try package.resourceValues(forKeys: [.volumeSupportsFileCloningKey, .volumeLocalizedFormatDescriptionKey])

        var start = ContinuousClock.now
        try ProjectBackups.write(project, packageURL: package, now: Date())
        let first = Self.seconds(since: start)

        start = .now
        try ProjectBackups.write(project, packageURL: package, now: Date(timeIntervalSinceNow: 60))
        let second = Self.seconds(since: start)

        // A save asked for just after a backup starts waits for it.
        project.name = "Edited"
        let snapshot = project
        start = .now
        let backup = Task {
            try await PackageCoordinator.shared.run(on: [package]) {
                try ProjectBackups.write(snapshot, packageURL: package, now: Date(timeIntervalSinceNow: 120))
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let asked = ContinuousClock.now
        try await ProjectStore.save(snapshot, to: package, previousPackageURL: package)
        let saveWaited = Self.seconds(since: asked)
        _ = try await backup.value

        print("""
        BackupCostBenchmark: \(Self.megabytes) MB of media on \(volume.volumeLocalizedFormatDescription ?? "?") \
        (clones: \(volume.volumeSupportsFileCloning == true ? "yes" : "no"))
          first backup  \(String(format: "%.2f", first)) s
          second backup \(String(format: "%.2f", second)) s (nothing changed)
          a save asked for during a backup took \(String(format: "%.2f", saveWaited)) s
        """)
    }
}
