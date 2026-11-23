// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import CoreAudio
import Foundation

public struct InputDevice: Sendable, Identifiable, Hashable {
    public var id: String { uid }
    public let uid: String
    public let name: String
    public let channels: Int
    public init(uid: String, name: String, channels: Int) { self.uid = uid; self.name = name; self.channels = channels }
}

public enum DeviceDiscovery {
    private static func addr(_ s: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = addr(selector), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    /// Number of input *streams* (Core Audio buffers) a device contributes to an aggregate.
    public static func inputStreamCount(deviceID: AudioObjectID) -> Int {
        var a = addr(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput), size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &a, 0, nil, &size) == noErr ? Int(size) / MemoryLayout<AudioObjectID>.size : 0
    }

    public static func inputChannelCount(deviceID: AudioObjectID) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        var a = addr(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf: Unmanaged<CFString>? = Unmanaged.passRetained(uid as CFString)
        defer { cf?.release() }
        var dev = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), $0, &size, &dev)
        }
        return st == noErr && dev != kAudioObjectUnknown ? dev : nil
    }

    /// Physical and third-party input devices (microphones, interfaces). Conduit's own device and
    /// private aggregates are excluded so a mic can never feed back through the loopback.
    public static func inputDevices() -> [InputDevice] {
        var a = addr(kAudioHardwarePropertyDevices), size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("com.conduit."),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            var tt = addr(kAudioDevicePropertyTransportType), transport: UInt32 = 0, tsize = UInt32(4)
            if AudioObjectGetPropertyData(id, &tt, 0, nil, &tsize, &transport) == noErr, transport == kAudioDeviceTransportTypeAggregate { return nil }
            let ch = inputChannelCount(deviceID: id)
            return ch > 0 ? InputDevice(uid: uid, name: name, channels: ch) : nil
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
