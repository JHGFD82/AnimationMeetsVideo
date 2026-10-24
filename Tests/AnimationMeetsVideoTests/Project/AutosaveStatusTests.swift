import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite struct AutosaveStatusTests {
    @Test func repeatedFailuresKeepWhenTheyStartedAndTheLatestReason() {
        let status = AutosaveStatus()
        let first = Date(timeIntervalSince1970: 1_000)
        status.failed("The disk is full.", at: first)
        status.failed("The volume is read-only.", at: first.addingTimeInterval(60))
        #expect(status.failure == "The volume is read-only.")
        #expect(status.failingSince == first)
    }

    @Test func aBackupOrSaveClearsTheFailure() {
        let status = AutosaveStatus()
        status.failed("The disk is full.")
        status.succeeded()
        #expect(status.failure == nil)
        #expect(status.failingSince == nil)
    }
}
