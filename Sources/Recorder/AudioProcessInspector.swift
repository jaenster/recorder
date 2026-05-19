import Foundation
import CoreAudio

/// Lists running processes that CoreAudio sees as actively using audio,
/// so the picker can surface only apps that are likely in a call.
enum AudioProcessInspector {
    /// PIDs of processes currently *reading* the microphone (in a call).
    static func pidsUsingMicrophone() -> Set<pid_t> {
        let objects = audioProcessObjects()
        var result: Set<pid_t> = []
        for obj in objects {
            if boolProperty(obj, kAudioProcessPropertyIsRunningInput) {
                if let pid = pidProperty(obj) {
                    result.insert(pid)
                }
            }
        }
        return result
    }

    /// PIDs of processes currently *playing* audio. Useful as a fallback
    /// when nothing is using the mic — at least lets us list apps producing sound.
    static func pidsProducingAudio() -> Set<pid_t> {
        let objects = audioProcessObjects()
        var result: Set<pid_t> = []
        for obj in objects {
            if boolProperty(obj, kAudioProcessPropertyIsRunningOutput) {
                if let pid = pidProperty(obj) {
                    result.insert(pid)
                }
            }
        }
        return result
    }

    // MARK: - CoreAudio plumbing

    private static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        status = objects.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &dataSize, buf.baseAddress!)
        }
        guard status == noErr else { return [] }
        return objects
    }

    private static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr else { return false }
        return value != 0
    }

    private static func pidProperty(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        guard status == noErr, pid > 0 else { return nil }
        return pid
    }
}
