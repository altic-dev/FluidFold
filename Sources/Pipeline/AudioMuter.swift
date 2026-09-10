import CoreAudio
import AudioToolbox
import Foundation

/// Mutes the default output while the desktop is folded, and restores it on reopen.
/// Only unmutes if it was the one that muted, so a user's own mute is left alone.
@MainActor
final class AudioMuter {
    /// The device we muted. Unmute targets it explicitly, so a default-device change (headphones dropping on
    /// sleep) never leaves the wrong device muted.
    private var mutedDevice: AudioDeviceID?

    func mute() {
        guard mutedDevice == nil, let device = defaultOutputDevice() else { return }
        if isMuted(device) { return }        // already muted by the user; don't take ownership
        setMuted(device, true)
        mutedDevice = device
        dlog("audio muted")
    }

    func unmute() {
        guard let device = mutedDevice else { return }
        setMuted(device, false)
        mutedDevice = nil
        dlog("audio unmuted")
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func isMuted(_ device: AudioDeviceID) -> Bool {
        var addr = muteAddress()
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private func setMuted(_ device: AudioDeviceID, _ muted: Bool) {
        var addr = muteAddress()
        guard AudioObjectHasProperty(device, &addr) else { return }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr { dlog("set mute failed: \(status)") }
    }
}
