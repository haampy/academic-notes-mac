import SwiftUI

@MainActor
final class InputLevelMeter: ObservableObject {
    @Published var level: Double = 0
}

struct InputMonitor: View {
    @ObservedObject var session: Session
    @ObservedObject private var devices: InputDevices
    let typography: CaptionTypography

    init(session: Session, typography: CaptionTypography) {
        self.session = session
        self.devices = session.devices
        self.typography = typography
    }

    private var defaultDevice: InputDevice? {
        devices.devices.first { $0.id == devices.defaultID }
    }

    private var followsDefault: Bool { session.selectedInputUID.isEmpty }
    private var capturing: Bool { session.phase == .live && session.activeInputName != nil }
    private var selectedDevice: InputDevice? {
        followsDefault ? defaultDevice : devices.devices.first { $0.id == session.selectedInputUID }
    }

    private func displayName(_ device: InputDevice) -> String {
        let matches = devices.devices.filter { $0.name == device.name }
        guard matches.count > 1, let index = matches.firstIndex(where: { $0.id == device.id }) else {
            return device.name
        }
        return "\(device.name)（\(index + 1)）"
    }

    private var deviceName: String {
        if capturing, let name = session.activeInputName {
            if let device = selectedDevice, device.name == name { return displayName(device) }
            return name
        }
        if let device = selectedDevice { return displayName(device) }
        if followsDefault {
            return devices.devices.isEmpty ? "没有可用输入设备" : "未设置默认输入"
        }
        return session.selectedInputName ?? "所选设备未连接"
    }

    private var sourceLabel: String {
        let state = capturing ? "当前输入" : "所选输入"
        if followsDefault { return state + " · 系统默认" }
        if !capturing && selectedDevice == nil { return state + " · 未连接" }
        return state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * typography.scale) {
            Menu {
                Picker("声音输入", selection: Binding(get: { session.selectedInputUID }, set: session.selectInput)) {
                    Text(defaultDevice.map { "跟随系统默认 · \(displayName($0))" } ?? "跟随系统默认").tag("")
                    Divider()
                    ForEach(devices.devices) { device in
                        Text(displayName(device)).tag(device.id)
                    }
                    if !followsDefault && selectedDevice == nil {
                        Text(session.selectedInputName.map { "\($0)（未连接）" } ?? "所选设备未连接")
                            .tag(session.selectedInputUID).disabled(true)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: selectedDevice == nil && !capturing ? "mic.slash" : "mic")
                        .frame(width: typography.deviceSize)
                    Text(deviceName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: typography.deviceSize * 0.7, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: typography.deviceSize))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("选择声音输入设备")
            .accessibilityValue(sourceLabel + "，" + deviceName)
            .help(sourceLabel + "：" + deviceName + "。点按选择设备。")
            HStack(spacing: 5) {
                LevelIndicator(meter: session.levelMeter, active: capturing, size: typography.deviceSize)
                Text(session.status)
                    .font(.system(size: typography.statusSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(session.statusDetail ?? session.status)
            }
        }
    }
}

private struct LevelIndicator: View {
    @ObservedObject var meter: InputLevelMeter
    let active: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var level: Double { active ? min(max(meter.level, 0), 1) : 0 }
    private var reading: String {
        guard active else { return "未采集" }
        if level == 0 { return "≤−60 dBFS" }
        return "\(Int((level * 60 - 60).rounded())) dBFS"
    }

    var body: some View {
        let liveColor = colorScheme == .dark ? Color(red: 0.93, green: 0.58, blue: 0.46)
                                             : Color(red: 0.74, green: 0.33, blue: 0.22)
        HStack(alignment: .bottom, spacing: size / 12) {
            ForEach(0..<4) { index in
                Capsule()
                    .fill(.secondary.opacity(0.55))
                    .overlay {
                        Capsule()
                            .fill(liveColor)
                            .opacity(min(1, max(0, level * 4 - Double(index))))
                    }
                    .frame(width: size / 6, height: size * (active ? 4 + 2 * CGFloat(index) : 3) / 12)
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion || !active ? nil : .easeOut(duration: 0.10), value: level)
        .accessibilityRepresentation {
            ProgressView(value: level)
                .accessibilityLabel("输入电平")
                .accessibilityValue(reading)
        }
        .help("输入电平：" + reading)
    }
}
