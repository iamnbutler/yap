import AVFoundation
import CoreAudio

/// Whether the system says the mic is muted, and why, in a few words for
/// the overlay.
///
/// Read from the default input device, which is the one AVAudioEngine's
/// input node records from. Cheap (a handful of property reads), so it is
/// read again a few times a second while recording rather than kept current
/// with listeners: a mute or a volume change midway is seen on the next read,
/// and nothing needs adding or removing as devices come and go.
///
/// Not every device publishes these properties. Most USB and Bluetooth mics
/// have no mute and no input volume; then this returns nil and the level
/// based warning in `SilenceWatch` is the only one.
enum InputMute {
    static func reason() -> String? {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            // Without access, macOS hands the app silence rather than an error.
            return "Yap has no microphone access — allow it in Privacy & Security"
        }
        guard let device = defaultInput() else { return nil }
        let name = self.name(of: device).map { " (\($0))" } ?? ""
        if isMuted(device) { return "Mic is muted\(name)" }
        if let volume = volume(of: device), volume <= 0.001 {
            return "Input volume is 0\(name)"
        }
        return nil
    }

    private static func defaultInput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// Muted on the whole input (element main) or on its first channel, which
    /// is where some drivers put it instead.
    private static func isMuted(_ device: AudioObjectID) -> Bool {
        [kAudioObjectPropertyElementMain, 1].contains { element in
            let muted: UInt32? = read(device, kAudioDevicePropertyMute, element: element)
            return muted.map { $0 != 0 } ?? false
        }
    }

    /// The input volume, 0 to 1: the device's own, else the first channel's,
    /// else the virtual main volume the Sound settings slider drives on
    /// devices that only have per-channel controls.
    private static func volume(of device: AudioObjectID) -> Float32? {
        let candidates: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
            (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain),
        ]
        for (selector, element) in candidates {
            if let volume: Float32 = read(device, selector, element: element) { return volume }
        }
        return nil
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// An input-scope property, or nil when the device doesn't have it.
    private static func read<Value: BitwiseCopyable & Numeric>(
        _ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Value = 0
        var size = UInt32(MemoryLayout<Value>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && size == MemoryLayout<Value>.size ? value : nil
    }
}
