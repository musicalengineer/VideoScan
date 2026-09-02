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

    /// Experiment knob (Rick 8/25, stutter persisted at 512): override the
    /// minimum without a rebuild —
    ///   defaults write Rick-Breen.VideoScan hallie.outputBufferFrames 2048
    /// Accepts 64...4096; anything else falls back to the default.
    static let framesKey = "hallie.outputBufferFrames"
    static func configuredMinimum(_ defaults: UserDefaults = .standard) -> UInt32 {
        let stored = defaults.integer(forKey: framesKey)
        return (64...4096).contains(stored) ? UInt32(stored) : minimumFrames
    }

    /// Returns a one-line description of what happened, for the log —
    /// including the device's nominal sample rate, because a 24 kHz WAV on
    /// a 48/96 kHz interface is resampled by the HAL, which is the next
    /// suspect once the buffer is ruled out.
    @discardableResult
    static func ensureMinimum(_ minimum: UInt32 = configuredMinimum()) -> String {
        guard let device = defaultOutputDevice() else {
            return "output buffer: no default output device"
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames)
        guard status == noErr else {
            return "output buffer: could not read frame size (status \(status))"
        }
        let rate = nominalSampleRate(device).map { " @ \(Int($0)) Hz" } ?? ""
        let shape = outputShape(device)
        guard frames < minimum else {
            return "output buffer: \(frames) frames on \(deviceName(device))\(rate)\(shape) (left alone; min \(minimum))"
        }
        var wanted = minimum
        status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &wanted)
        guard status == noErr else {
            return "output buffer: \(frames) frames on \(deviceName(device))\(rate)\(shape); raise to \(minimum) refused (status \(status))"
        }
        return "output buffer: raised \(frames) → \(minimum) frames on \(deviceName(device))\(rate)\(shape)"
    }

    /// The system's current default output device, or nil when there is none.
    static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// ", 14 ch, latency 32+64" — output channel count plus the device's
    /// own latency and safety offset in frames (2026-09-02: the Babyface
    /// stuttered at the same 512-frame buffer the BenQ played cleanly; the
    /// channel count and the safety margin are what differ between them).
    static func outputShape(_ device: AudioDeviceID) -> String {
        var parts: [String] = []
        if let channels = outputChannelCount(device) { parts.append("\(channels) ch") }
        let latency = outputFrames(device, kAudioDevicePropertyLatency)
        let safety = outputFrames(device, kAudioDevicePropertySafetyOffset)
        if latency != nil || safety != nil {
            parts.append("latency \(latency ?? 0)+\(safety ?? 0)")
        }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    /// Counts CoreAudio processor overloads (missed I/O deadlines) on one
    /// device for as long as it lives. A stutter with zero overloads is not
    /// the audio thread starving; a stutter with dozens is.
    final class OverloadCounter {
        let device: AudioDeviceID
        private static let queueKey = DispatchSpecificKey<Void>()
        private let queue: DispatchQueue
        private var counted = 0
        /// True while the HAL listener is registered. Exposed for tests.
        private(set) var installed = false
        /// Result of the last remove call — surfaced, not swallowed
        /// (codex #961). A failed removal leaves a listener that only ever
        /// touches `self` weakly, so it is harmless but worth seeing.
        private(set) var removalStatus: OSStatus = noErr
        private var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.counted += 1     // already on `queue`
        }

        init(device: AudioDeviceID) {
            self.device = device
            let queue = DispatchQueue(label: "Rick-Breen.VideoScan.hallie-overloads")
            queue.setSpecific(key: Self.queueKey, value: ())
            self.queue = queue
            installed = AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr
        }

        /// Safe from any thread — including the listener queue itself, so a
        /// final release inside the block cannot deadlock `deinit → stop`.
        var count: Int {
            if DispatchQueue.getSpecific(key: Self.queueKey) != nil { return counted }
            return queue.sync { counted }
        }

        /// Removes the listener (idempotent); returns the final count.
        @discardableResult
        func stop() -> Int {
            if installed {
                let status = AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
                removalStatus = status
                if status == noErr {
                    installed = false
                } else {
                    // Still registered as far as we know — say so and let
                    // the next stop (or deinit) try again (codex #967).
                    NSLog("VideoScan: overload listener removal failed (status %d); will retry", status)
                }
            }
            return count
        }

        deinit { stop() }
    }

    private static func outputChannelCount(_ device: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func outputFrames(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : nil
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
