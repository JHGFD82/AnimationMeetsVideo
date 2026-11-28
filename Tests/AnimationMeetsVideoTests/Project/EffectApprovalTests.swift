import AppKit
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Effect packages from outside the app are approved, for their exact
/// content, before any kernel of theirs is compiled (decision D8;
/// docs/effect-packages.md, "Safety").
@Suite struct EffectApprovalTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "amv-approval-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let file = FileManager.default.temporaryDirectory.appending(path: "amv-approved-\(UUID().uuidString).json")

    /// A package of its own content, so no other test's approval covers it.
    private func package(body: String = "return s;", approved: Bool = false, named name: String = "Tint.amveffect") throws -> EffectPackage {
        let function = "exTint" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let kernel = "extern \"C\" [[stitchable]] float4 \(function)(coreimage::sample_t s, float space) { \(body) }"
        return try EffectPackageStore.read(try writeEffectPackage(
            effectManifest("com.example.tint", function: function), kernel: kernel, in: folder, named: name, approved: approved
        ))
    }

    @Test func builtInPackagesNeedNoApproval() throws {
        let builtIn = try #require(EffectRegistry.builtInPackages.packages.first)
        #expect(builtIn.isBuiltIn)
        #expect(EffectApproval(file: nil).allows(builtIn))
    }

    @Test func anExternalPackageWaitsUntilApprovedAsItIs() throws {
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: file)
        }
        let tint = try package()
        #expect(!tint.isBuiltIn)
        let approval = EffectApproval(file: file)
        #expect(!approval.allows(tint))
        approval.approve(tint)
        #expect(approval.allows(tint))
        // Kept on this Mac between launches, in its own file.
        #expect(EffectApproval(file: file).allows(tint))
        // The same package with its kernel changed by one character asks
        // again, though its ID and place are the same.
        let changed = try package(body: "return s ;")
        #expect(changed.id == tint.id && changed.url == tint.url)
        #expect(!EffectApproval(file: file).allows(changed))

        approval.forgetAll()
        #expect(approval.isEmpty && !EffectApproval(file: file).allows(tint))
    }

    /// Nothing of an unapproved package is compiled: a kernel that doesn't
    /// compile reports nothing, as it was never handed to the compiler,
    /// and draws nothing; approved, it is compiled and its mistake found.
    @Test func nothingIsCompiledUntilItIsApproved() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = try package(body: "return s")
        #expect(PackageKernels.problem(for: broken) == nil)
        #expect(PackageKernels.knownProblem(for: broken) == nil)
        #expect(PackageKernels.kernel(for: broken) == nil)
        EffectApproval.shared.approveInSession(hash: broken.approvalHash)
        #expect(PackageKernels.problem(for: broken) != nil)
    }

    /// A render made while it waited (the picture left as it was) is kept
    /// under another key than one made once it is approved.
    @Test func approvingChangesWhatItsRendersAreKeptUnder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let tint = try package()
        let waiting = tint.renderIdentity
        EffectApproval.shared.approveInSession(hash: tint.approvalHash)
        #expect(tint.renderIdentity != waiting)
        #expect(tint.renderIdentity == tint.contentHash)
    }

    @Test func theApprovalHashIsTheContentsSHA256() {
        let a = EffectPackage.approvalHash(Data("{}".utf8), "kernel")
        #expect(a.count == 64)
        #expect(a != EffectPackage.approvalHash(Data("{} ".utf8), "kernel"))
        // The manifest and kernel are kept apart: moving a byte between
        // them is another package.
        #expect(EffectPackage.approvalHash(Data("ab".utf8), "c") != EffectPackage.approvalHash(Data("a".utf8), "bc"))
    }

    @Test func theQuestionSaysWhatThePackageIsAndWhatItCanDo() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let tint = try package()
        let message = NewEffectPackagePrompt.approvalMessage(for: tint)
        #expect(message.contains("com.example.tint") && message.contains("from outside the app"))
        #expect(message.contains("graphics processor") && message.contains("can't always stop it"))
        #expect(message.contains("asked again") && message.contains("hold Shift"))
        #expect(message.contains(EffectPackageOrigin.describe(tint.url)))
    }

    /// Where it came from, as the Mac recorded a download.
    @Test func itsOriginIsWhereItWasDownloadedFrom() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let tint = try package()
        #expect(EffectPackageOrigin.describe(tint.url) == "in \(folder.standardizedFileURL.path)")
        try setAttribute("com.apple.quarantine", Data("0083;00000000;Safari;".utf8), on: tint.url)
        #expect(EffectPackageOrigin.describe(tint.url) == "downloaded from the internet")
        let whereFroms = try PropertyListSerialization.data(
            fromPropertyList: ["https://effects.example.com/tint.zip", "https://example.com/"], format: .binary, options: 0
        )
        try setAttribute("com.apple.metadata:kMDItemWhereFroms", whereFroms, on: tint.url)
        #expect(EffectPackageOrigin.describe(tint.url) == "downloaded from effects.example.com")
    }

    private func setAttribute(_ name: String, _ data: Data, on url: URL) throws {
        let result = data.withUnsafeBytes { bytes in
            url.withUnsafeFileSystemRepresentation { setxattr($0, name, bytes.baseAddress, data.count, 0, 0) }
        }
        try #require(result == 0)
    }

    @Test func aRecoveryLaunchIsAskedForWithShiftOrTheSetting() throws {
        let defaults = try #require(UserDefaults(suiteName: "amv-recovery-\(UUID().uuidString)"))
        #expect(!RecoveryLaunch.externalEffectsOff(modifiers: [], defaults: defaults))
        #expect(RecoveryLaunch.externalEffectsOff(modifiers: [.shift], defaults: defaults))
        #expect(!RecoveryLaunch.externalEffectsOff(modifiers: [.option], defaults: defaults))
        defaults.set(true, forKey: Preferences.disableExternalEffects)
        #expect(RecoveryLaunch.externalEffectsOff(modifiers: [], defaults: defaults))
    }
}
