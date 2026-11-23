import Combine
import CoreAudio
import Foundation

struct InputDevice: Identifiable, Equatable {
    let id: String
    let audioID: AudioDeviceID
    let name: String
}

@MainActor
final class InputDevices: ObservableObject {
    struct Snapshot: Equatable {
        var devices: [InputDevice] = []
        var defaultID: String?
    }

    @Published private(set) var snapshot = Snapshot()
    var devices: [InputDevice] { snapshot.devices }
    var defaultID: String? { snapshot.defaultID }

    private var observations: [AudioObjectID: Observation] = [:]

    init() {
        let system = AudioHardwareSystem.shared
        observe(system.id, properties: [
            address(kAudioHardwarePropertyDevices),
            address(kAudioHardwarePropertyDefaultInputDevice)
        ])
        refresh()
    }

    func refresh() {
        let system = AudioHardwareSystem.shared
        guard let hardware = try? system.devices else { return }
        let ids = Set(hardware.map(\.id))
        observations = observations.filter { $0.key == system.id || ids.contains($0.key) }
        for device in hardware where observations[device.id] == nil {
            observe(device.id, properties: [
                address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput),
                address(kAudioDevicePropertyDeviceIsAlive),
                address(kAudioObjectPropertyName)
            ])
        }

        let inputs = hardware.compactMap { device -> InputDevice? in
            guard (try? device.isAlive) == true,
                  let buffers = try? device.inputStreamConfiguration,
                  buffers.contains(where: { $0.mNumberChannels > 0 }),
                  let uid = try? device.uid, let name = try? device.name else { return nil }
            return InputDevice(id: uid, audioID: device.id, name: name)
        }.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        let defaultDevice = try? system.defaultInputDevice
        let updated = Snapshot(devices: inputs, defaultID: inputs.first { $0.audioID == defaultDevice?.id }?.id)
        if snapshot != updated { snapshot = updated }
    }

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func observe(_ id: AudioObjectID, properties: [AudioObjectPropertyAddress]) {
        observations[id] = Observation(id: id, properties: properties) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private final class Observation {
        let id: AudioObjectID
        let properties: [AudioObjectPropertyAddress]
        let listener: AudioObjectPropertyListenerBlock

        init(id: AudioObjectID, properties: [AudioObjectPropertyAddress], listener: @escaping AudioObjectPropertyListenerBlock) {
            self.id = id
            self.listener = listener
            self.properties = properties.filter {
                var address = $0
                return AudioObjectAddPropertyListenerBlock(id, &address, .main, listener) == noErr
            }
        }

        deinit {
            for var address in properties {
                AudioObjectRemovePropertyListenerBlock(id, &address, .main, listener)
            }
        }
    }
}
