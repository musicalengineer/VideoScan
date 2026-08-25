// HallieOutputBuffer.swift
// Raise the output device's I/O buffer before Hallie speaks (2026-08-25).
//
// Rick runs the RME Babyface at a tiny buffer (48–64 frames) for playing
// keyboards. That is perfect for a synth and hopeless for speech playback
// while a build is pinning every core: CoreAudio underruns and Bella
// stammers. The BenQ's display audio did not stammer — its buffer is
// large. So before Bella's WAV plays, the default output device's
// `kAudioDevicePropertyBufferFrameSize` is raised to at least 256 frames.
//
// Deliberately blunt (Rick: "a hard number for now"): raise only, never
// lower, no preference, one log line either way. The property is
// DEVICE-wide, not per-process — it stays at 256 for other apps until
// they or the RME panel change it. If that ever bites, this is the file.

import CoreAudio
import Foundation

enum HallieOutputBuffer {
    static let minimumFrames: UInt32 = 256

    /// Returns a one-line description of what happened, for the log.
    @discardableResult
    static func ensureMinimum(_ minimum: UInt32 = minimumFrames) -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else {
            return "output buffer: no default output device (status \(status))"
        }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var frames = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames)
        guard status == noErr else {
            return "output buffer: could not read frame size (status \(status))"
        }
        guard frames < minimum else {
            return "output buffer: \(frames) frames on \(deviceName(device)) (left alone)"
        }
        var wanted = minimum
        status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &wanted)
        guard status == noErr else {
            return "output buffer: \(frames) frames on \(deviceName(device)); raise to \(minimum) refused (status \(status))"
        }
        return "output buffer: raised \(frames) → \(minimum) frames on \(deviceName(device))"
    }

    private static func deviceName(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (name as String) : "device \(device)"
    }
}
