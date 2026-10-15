import AudioToolbox
import CoreAudio
import Foundation

enum TapError: LocalizedError {
    case os(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .os(step, status): return "\(step) failed (\(status))"
        }
    }
}

/// Captures everything the Mac is playing (every app) using a Core Audio process tap,
/// mixed down to mono floats. Requires macOS 14.2+ and the "System Audio Recording" permission.
final class SystemAudioTap {
    typealias Handler = (_ samples: UnsafePointer<Float>, _ frameCount: Int, _ sampleRate: Double) -> Void

    var onSamples: Handler?
    private(set) var sampleRate: Double = 48_000
    private(set) var isRunning = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "visualizer.audio", qos: .userInteractive)
    private var mono = [Float](repeating: 0, count: 4096)

    func start() throws {
        stop()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Visualizer"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.os("Creating the audio tap", status) }

        let outputUID = try AudioDevices.uid(of: AudioDevices.defaultOutput())
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Visualizer Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw TapError.os("Creating the capture device", status) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { stop(); throw TapError.os("Reading the audio format", status) }
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let nonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let rate = sampleRate

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.process(input, nonInterleaved: nonInterleaved, sampleRate: rate)
        }
        guard status == noErr else { stop(); throw TapError.os("Starting audio capture", status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw TapError.os("Starting audio capture", status) }
        isRunning = true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isRunning = false
    }

    private func process(_ input: UnsafePointer<AudioBufferList>, nonInterleaved: Bool, sampleRate: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mData != nil else { return }

        let frames: Int
        if nonInterleaved {
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            ensureCapacity(frames)
            for i in 0..<frames { mono[i] = 0 }
            var channelCount = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                for i in 0..<count { mono[i] += data[i] }
                channelCount += 1
            }
            if channelCount > 1 {
                let scale = 1 / Float(channelCount)
                for i in 0..<frames { mono[i] *= scale }
            }
        } else {
            let channels = max(1, Int(first.mNumberChannels))
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            ensureCapacity(frames)
            let data = first.mData!.assumingMemoryBound(to: Float.self)
            let scale = 1 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[i * channels + c] }
                mono[i] = sum * scale
            }
        }
        guard frames > 0 else { return }
        mono.withUnsafeBufferPointer { onSamples?($0.baseAddress!, frames, sampleRate) }
    }

    private func ensureCapacity(_ frames: Int) {
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
    }

    deinit { stop() }
}

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let transport: UInt32

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        default: return "hifispeaker"
        }
    }
}

/// Helpers for listing and switching the Mac's sound output (speakers, Bluetooth, AirPlay).
enum AudioDevices {
    static func defaultOutput() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    static func setDefaultOutput(_ device: AudioObjectID) {
        var value = device
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &value)
        }
    }

    static func uid(of device: AudioObjectID) throws -> String {
        guard let value = string(device, kAudioDevicePropertyDeviceUID) else {
            throw TapError.os("Finding the sound output", -1)
        }
        return value
    }

    static func outputs() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputStreams(id), let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
            if name.contains("Visualizer") { return nil }
            return OutputDevice(id: id, name: name, transport: transport)
        }
    }

    /// Calls `handler` on the main queue whenever devices or the default output change.
    static func observeChanges(_ handler: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { _, _ in
                handler()
            }
        }
    }

    private static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
