import CoreAudio
import Foundation

/// Read-mostly wrapper over the CoreAudio HAL — "what is the Mac's audio doing
/// right now, and can I turn it down?".
///
/// Everything here is a synchronous HAL round-trip to `coreaudiod` (~1ms each).
/// Cheap, but never call it from the main thread on the dictation hot path;
/// `MediaController` funnels all of it onto a serial background queue.
///
/// The per-process properties (`kAudioHardwarePropertyProcessObjectList` and
/// friends) landed in macOS 14.2. They are plain four-char selectors with no
/// availability annotation, so on 14.0/14.1 the calls simply return an error
/// and `processes()` yields an empty list — callers must treat "empty" as
/// "unknown", not as "silence".
enum SystemAudio {

    // MARK: - Address helper

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func uint32(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> UInt32? {
        var addr = addr
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var addr = addr
        var out: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &out) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let out else { return nil }
        return out.takeRetainedValue() as String
    }

    // MARK: - Default output device

    static var defaultOutputDevice: AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device
        )
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    /// Stable identifier for a device across disconnect/reconnect — used to make
    /// sure a volume restore lands on the device we actually turned down, and
    /// not on whatever became "default" after AirPods dropped mid-dictation.
    static func uid(of device: AudioObjectID) -> String? {
        string(device, address(kAudioDevicePropertyDeviceUID))
    }

    static func device(withUID uid: String) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices
        ) == noErr else { return nil }

        return devices.first { self.uid(of: $0) == uid }
    }

    // MARK: - Output volume

    /// Elements that actually carry a settable scalar volume on this device.
    ///
    /// Most devices expose a main (element 0) control. Plenty of USB DACs and
    /// HDMI outputs do not, and only expose per-channel controls — those are the
    /// devices where naive implementations get stuck muted, so handle both.
    private static func volumeElements(of device: AudioObjectID) -> [AudioObjectPropertyElement] {
        func settable(_ element: AudioObjectPropertyElement) -> Bool {
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
            guard AudioObjectHasProperty(device, &addr) else { return false }
            var isSettable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &addr, &isSettable) == noErr else { return false }
            return isSettable.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(settable)
    }

    /// Current output volume, 0…1. `nil` when the device has no volume control
    /// we can drive (HDMI, some pro interfaces) — the caller must then leave the
    /// device alone rather than guess.
    static func outputVolume(of device: AudioObjectID) -> Float? {
        for element in volumeElements(of: device) {
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    /// Writes the volume, then reads it back and reports whether it stuck.
    ///
    /// The read-back is the point: some USB DAC drivers acknowledge a write they
    /// never applied. Trusting the OSStatus alone is how you end up believing you
    /// turned the volume down — and, worse, believing you can put it back.
    @discardableResult
    static func setOutputVolume(_ value: Float, on device: AudioObjectID) -> Bool {
        let clamped = min(max(value, 0), 1)
        let elements = volumeElements(of: device)
        guard !elements.isEmpty else { return false }

        for element in elements {
            var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
            var v = Float32(clamped)
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }

        guard let readback = outputVolume(of: device) else { return false }
        return abs(readback - clamped) < 0.02
    }

    // MARK: - Who is making noise

    /// One audio client of the HAL. `identity` collapses helper processes onto
    /// their host app (`com.google.Chrome.helper` → `com.google.Chrome`) so a
    /// browser that plays through one helper and records through another is
    /// still recognised as a single participant.
    struct AudioProcess {
        let pid: pid_t
        let bundleID: String?
        let isPlaying: Bool
        let isCapturing: Bool

        var identity: String {
            guard let bundleID, !bundleID.isEmpty else { return "pid:\(pid)" }
            // Strip the ".helper"/".helper.Renderer"… tail Chromium apps append.
            if let range = bundleID.range(of: ".helper", options: [.caseInsensitive]) {
                return String(bundleID[bundleID.startIndex..<range.lowerBound])
            }
            return bundleID
        }
    }

    /// Every process CoreAudio knows about, with its live input/output state.
    /// Empty on macOS < 14.2 (property unsupported) — treat as "unknown".
    static func processes() -> [AudioProcess] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects
        ) == noErr else { return [] }

        return objects.map { object in
            AudioProcess(
                pid: uint32(object, address(kAudioProcessPropertyPID)).map { pid_t(bitPattern: $0) } ?? -1,
                bundleID: string(object, address(kAudioProcessPropertyBundleID)),
                isPlaying: uint32(object, address(kAudioProcessPropertyIsRunningOutput)) == 1,
                isCapturing: uint32(object, address(kAudioProcessPropertyIsRunningInput)) == 1
            )
        }
    }

    /// Fallback for macOS < 14.2: is *anything at all* driving the output device?
    /// Coarse — it cannot exclude Haynoi's own start tone — so it is only used
    /// when the per-process list is unavailable.
    static func isOutputActive(on device: AudioObjectID) -> Bool {
        uint32(device, address(kAudioDevicePropertyDeviceIsRunningSomewhere)) == 1
    }
}
