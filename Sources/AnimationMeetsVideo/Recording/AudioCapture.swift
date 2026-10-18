import AVFoundation
import CoreAudio
import Foundation

/// Where a take's sound comes from.
enum RecordingSource: Hashable, Sendable {
    /// An input device, by UID, or the system's default input for nil.
    case input(uid: String?)
    /// What a running app plays.
    case app(AudioApp)
}

/// Sound coming in from one source, handed to a `TakeWriter`.
protocol AudioCapture: AnyObject {
    /// What its buffers hold.
    var format: AudioStreamBasicDescription { get }
    /// How long after the sound happened its buffers' host times are, in
    /// seconds.
    var latency: Double { get }
    func start(writing writer: TakeWriter) throws
    func stop()
}

extension RecordingSource {
    func makeCapture() throws -> AudioCapture {
        switch self {
        case .input(let uid): try InputCapture(uid: uid)
        case .app(let app): try AppCapture(app: app)
        }
    }
}

/// A microphone or an interface's inputs, through an audio engine's input.
final class InputCapture: AudioCapture {
    private let engine = AVAudioEngine()
    private let avFormat: AVAudioFormat
    let latency: Double

    var format: AudioStreamBasicDescription { avFormat.streamDescription.pointee }

    init(uid: String?) throws {
        let devices = AudioDevices.inputs()
        let wanted = uid ?? AudioDevices.defaultUID(input: true)
        guard let device = devices.first(where: { $0.uid == wanted }) ?? devices.first else { throw RecordingError.noInput }
        let input = engine.inputNode
        if let unit = input.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        avFormat = input.outputFormat(forBus: 0)
        guard avFormat.channelCount > 0, avFormat.sampleRate > 0 else { throw RecordingError.noInput }
        latency = AudioDevices.inputLatency(of: device.id)
    }

    func start(writing writer: TakeWriter) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: avFormat) { buffer, time in
            writer.write(buffer.audioBufferList, frames: buffer.frameLength, hostTime: time.hostTime)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// What a running app plays, through a Core Audio process tap on its
/// processes and a private aggregate device that reads the tap.
final class AppCapture: AudioCapture {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "AnimationMeetsVideo.app-capture", qos: .userInitiated)
    let format: AudioStreamBasicDescription
    let latency = 0.0

    init(app: AudioApp) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: app.processes)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "Animation Meets Video recording \(app.name)"
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw RecordingError.cantTap(status) }

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw RecordingError.cantTap(status)
        }
        self.format = format

        // The aggregate runs on the default output's clock and reads only
        // the tap.
        let output = AudioDevices.defaultUID() ?? ""
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Animation Meets Video Recording",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw RecordingError.cantTap(status)
        }
    }

    deinit {
        stop()
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
    }

    func start(writing writer: TakeWriter) throws {
        let bytesPerFrame = max(1, format.mBytesPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { _, input, inputTime, _, _ in
            guard let first = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).first else { return }
            // Interleaved, one buffer holds every channel's samples.
            let frames = first.mDataByteSize / (interleaved ? bytesPerFrame : 4)
            writer.write(input, frames: frames, hostTime: inputTime.pointee.mHostTime)
        }
        guard status == noErr, let procID else { throw RecordingError.cantTap(status) }
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { throw RecordingError.cantTap(status) }
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(aggregate, procID)
        AudioDeviceDestroyIOProcID(aggregate, procID)
        self.procID = nil
    }
}
