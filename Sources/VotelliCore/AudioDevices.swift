import CoreAudio
import Foundation

/// A selectable microphone input device.
struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Enumerates Core Audio input devices and resolves a saved device UID back to a
/// live device ID. Used to pin recording to a specific microphone so it doesn't
/// follow macOS when the system default input changes.
enum AudioDevices {
    /// All currently-connected devices that have at least one input channel.
    static func inputDevices() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// The live device ID for a saved UID, or nil if that device isn't connected.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        device(matchingUID: uid)?.id
    }

    /// The connected device a saved UID refers to. Exact match first; failing
    /// that, the same device under a different UID. macOS bakes the USB port
    /// location (or serial) into a USB device's UID, so the same mic plugged into
    /// another port or dock comes back with a new UID and an exact match fails.
    static func device(matchingUID uid: String) -> AudioInputDevice? {
        let devices = inputDevices()
        if let exact = devices.first(where: { $0.uid == uid }) { return exact }
        let key = stableKey(forUID: uid)
        return devices.first { stableKey(forUID: $0.uid) == key }
    }

    /// A USB audio UID is `AppleUSBAudioEngine:<vendor>:<product>:<location or
    /// serial>:<interface>`. Drop the location/serial so the key survives a port
    /// change. Any other UID is its own key.
    static func stableKey(forUID uid: String) -> String {
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.first == "AppleUSBAudioEngine", parts.count >= 5, let last = parts.last else {
            return uid
        }
        return (parts.dropLast(2) + [last]).joined(separator: ":")
    }

    /// The system's current default input device, or nil if there is none.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown
        else { return nil }
        return id
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let string = value else { return nil }
        return string as String
    }
}
