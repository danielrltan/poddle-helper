// The AirPod is the paddle, so the game's sound must not come out of it.
//
// While a Poddle page is connected, if the Mac's sound output is AirPods (or Beats), it is moved to the best other output
// this Mac has: the built-in speakers first, then USB, HDMI / DisplayPort / Thunderbolt, then any other Bluetooth speaker.
// When the last page leaves (or the app quits, or the menu switch is turned off) the output goes back to the AirPods,
// unless the player has picked something else in the meantime. If there is no other output, nothing changes.
//
// Measured on a MacBook Pro with AirPods Pro: headphone motion keeps streaming at 50 Hz when the output is moved to the
// speakers, and starts normally when the speakers were already the output. Motion does not need the AirPods to be playing.

import CoreAudio
import Foundation

private let system = AudioObjectID(kAudioObjectSystemObject)
private func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

struct OutputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let model: String       // Bluetooth audio reports "<product id> <vendor id>": Apple's vendor id is 4c
    let transport: UInt32

    var isAppleHeadphones: Bool { transport == kAudioDeviceTransportTypeBluetooth && model.hasSuffix(" 4c") }

    /// Lower is better. nil = never move the sound here: virtual and aggregate devices (Zoom, BlackHole, a recorder) play
    /// to nobody, and AirPlay adds a delay a rally cannot take.
    var rank: Int? {
        if isAppleHeadphones { return nil }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return 0
        case kAudioDeviceTransportTypeUSB: return 1
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt: return 2
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 3
        default: return nil
        }
    }
}

private func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value else { return "" }
    return v.takeRetainedValue() as String
}

private func outputDevices() -> [OutputDevice] {
    var a = addr(kAudioHardwarePropertyDevices), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var s = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), n: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &s, 0, nil, &n) == noErr, n > 0 else { return nil }      // inputs only (a microphone)
        var t = addr(kAudioDevicePropertyTransportType), transport: UInt32 = 0, ts = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &t, 0, nil, &ts, &transport)
        return OutputDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID), name: string(id, kAudioObjectPropertyName),
                            model: string(id, kAudioDevicePropertyModelUID), transport: transport)
    }
}

private func defaultOutput() -> AudioDeviceID {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice), id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id)
    return id
}

@discardableResult
private func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice), dev = id
    return AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
}

final class SoundRoute {
    /// The menu's "Play sound through speakers". On unless the player turned it off.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundFromSpeakers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundFromSpeakers"); newValue ? apply() : release() }
    }
    private var active = false              // a Poddle page is connected
    private var movedFrom: String?          // the AirPods' uid, to put the sound back
    private var movedTo: String?            // where it went: only undone if the output is still there
    private(set) var playingOn: String?     // the device name the menu shows while the sound is moved
    var onChange: () -> Void = {}
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.apply() }

    init() {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &a, .main, listener)       // AirPods that reconnect mid-match take the sound back: move it again
    }

    /// A page connected (true) or the last one left (false).
    func setActive(_ on: Bool) {
        active = on
        on ? apply() : release()
    }

    private func apply() {
        guard active, enabled else { return }
        let devices = outputDevices(), current = defaultOutput()
        guard let now = devices.first(where: { $0.id == current }) else { return }
        if !now.isAppleHeadphones {
            if now.uid != movedTo, movedTo != nil { forget(); log("sound output changed by hand to \(now.name): leaving it") }
            return
        }
        guard let target = devices.filter({ $0.rank != nil }).min(by: { $0.rank! < $1.rank! }) else {
            log("sound stays on \(now.name): this Mac has no other output"); return
        }
        guard setDefaultOutput(target.id) else { log("could not move sound to \(target.name)"); return }
        if movedFrom == nil { movedFrom = now.uid }
        movedTo = target.uid; playingOn = target.name
        log("sound moved from \(now.name) to \(target.name)")
        onChange()
    }

    /// Puts the sound back on the AirPods, unless the player has chosen another output since or the AirPods are gone.
    func release() {
        defer { forget() }
        guard let from = movedFrom, let to = movedTo else { return }
        let devices = outputDevices()
        guard devices.first(where: { $0.id == defaultOutput() })?.uid == to,
              let back = devices.first(where: { $0.uid == from }) else { return }
        setDefaultOutput(back.id)
        log("sound back on \(back.name)")
    }

    private func forget() {
        let had = playingOn != nil
        movedFrom = nil; movedTo = nil; playingOn = nil
        if had { onChange() }
    }
}
