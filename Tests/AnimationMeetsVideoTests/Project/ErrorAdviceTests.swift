import AVFoundation
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ErrorAdviceTests {
    @Test func systemErrorsAreSortedIntoCausesAPersonCanActOn() {
        #expect(ErrorAdvice.cause(of: CocoaError(.fileWriteOutOfSpace)) == .noSpace)
        #expect(ErrorAdvice.cause(of: CocoaError(.fileWriteNoPermission)) == .noPermission)
        #expect(ErrorAdvice.cause(of: CocoaError(.fileWriteVolumeReadOnly)) == .readOnly)
        #expect(ErrorAdvice.cause(of: POSIXError(.ENOSPC)) == .noSpace)
        #expect(ErrorAdvice.cause(of: POSIXError(.EROFS)) == .readOnly)
        #expect(ErrorAdvice.cause(of: POSIXError(.ETIMEDOUT)) == .unreachable)
        #expect(ErrorAdvice.cause(of: AVError(.diskFull)) == .noSpace)
        #expect(ErrorAdvice.cause(of: AVError(.fileFormatNotRecognized)) == .unsupportedFormat)
    }

    @Test func aCauseUnderAGeneralErrorIsFound() {
        let underlying = POSIXError(.ENOSPC) as NSError
        let general = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(ErrorAdvice.cause(of: general) == .noSpace)
        #expect(ErrorAdvice.sentence(for: general) == ErrorAdvice.Cause.noSpace.sentence)
    }

    @Test func theAppsOwnErrorsKeepTheirWording() {
        let error = ProjectStoreError.locked("another window")
        #expect(ErrorAdvice.cause(of: error) == nil)
        #expect(ErrorAdvice.sentence(for: error) == error.localizedDescription)
    }
}
