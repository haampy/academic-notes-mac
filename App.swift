import AVFoundation
import Combine
import SwiftUI
import Network

@MainActor
final class Session: ObservableObject {
    static let shared = Session()
    enum Phase { case idle, starting, live, stopping, paused }
    @Published var phase = Phase.idle
    // A save appends closed sentences in place, then publishes the refreshed caption tail.
    private(set) var transcript: [TranscriptLine] = []
    @Published private(set) var captionTail: [CaptionLine] = []
    private(set) var transcriptID = UUID()
    var hasCaptions: Bool { !transcript.isEmpty || !captionTail.isEmpty }
    private var tail = TranscriptTail()
    private var hypothesis = ""
    private var savedTail = ""
    private var unsavedLines = ""
    @Published var title = ""
    @Published private(set) var displayTitle = "Purrk"
    @Published var titleError = ""
    @Published var status = "准备开始"
    @Published private(set) var statusDetail: String?
    @Published private(set) var saveError: String?
    @Published var syncFailed = false
    @Published var cloudURL: URL?
    @Published var syncing = false
    let devices = InputDevices()
    let levelMeter = InputLevelMeter()
    @Published private(set) var selectedInputUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? ""
    @Published private(set) var activeInputName: String?
    var selectedInputName: String? {
        guard !selectedInputUID.isEmpty else { return nil }
        return selectedDevice(in: devices.snapshot)?.name ?? UserDefaults.standard.string(forKey: "inputDeviceName")
    }
    private var deviceObservation: AnyCancellable?
    private var captureDevice: InputDevice?
    private var waitingForInput = false
    private var input: FileHandle?
    private var note: URL?
    var canRename: Bool { note != nil && phase != .stopping }
    var canEnd: Bool { phase != .stopping || stopAction == .switchInput }
    private var started = Date()
    private enum StopAction { case finish, pause, switchInput }
    private var stopAction = StopAction.finish
    private var quitting = false
    private var opened = false
    private var requestID = UUID()
    private var syncAgain = false
    private let network = NWPathMonitor()

    func open() {
        guard !opened else { return }
        opened = true
        deviceObservation = devices.$snapshot.sink { [weak self] snapshot in
            self?.updateInputRoute(snapshot)
        }
        network.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { @MainActor in self?.sync() } }
        }
        network.start(queue: DispatchQueue(label: "academicnotes.network"))
        start()
        sync()
    }

    private func selectedDevice(in snapshot: InputDevices.Snapshot) -> InputDevice? {
        let uid = selectedInputUID.isEmpty ? snapshot.defaultID : selectedInputUID
        return snapshot.devices.first { $0.id == uid }
    }

    func selectInput(_ uid: String) {
        guard uid != selectedInputUID else { return }
        let snapshot = devices.snapshot
        let device = snapshot.devices.first { $0.id == uid }
        guard uid.isEmpty || device != nil else { return }
        let defaults = UserDefaults.standard
        defaults.set(uid, forKey: "inputDeviceUID")
        selectedInputUID = uid
        updateInputRoute(snapshot)
    }

    private func updateInputRoute(_ snapshot: InputDevices.Snapshot) {
        let target = selectedDevice(in: snapshot)
        if !selectedInputUID.isEmpty, let target {
            let defaults = UserDefaults.standard
            if defaults.string(forKey: "inputDeviceName") != target.name {
                defaults.set(target.name, forKey: "inputDeviceName")
            }
        }
        if waitingForInput, target != nil {
            waitingForInput = false
            status = phase == .paused ? "已暂停" : "准备开始"
            statusDetail = nil
        }
        guard let captureDevice, phase == .starting || phase == .live else { return }
        if target?.id != captureDevice.id || target?.audioID != captureDevice.audioID ||
            (phase == .starting && target?.name != captureDevice.name) {
            // Let the old worker deliver its final sentence before starting the new input.
            stopWorker(for: .switchInput)
        } else if phase == .live, let target, target.name != captureDevice.name {
            self.captureDevice = target
            activeInputName = target.name
        }
    }

    private var unavailableInputMessage: String {
        if let selectedInputName { return "请连接「\(selectedInputName)」或选择其他输入设备。" }
        return "请连接麦克风或选择其他输入设备。"
    }

    func start() { start(using: nil) }

    private func start(using settings: WorkerSettings?) {
        guard phase == .idle || phase == .paused else { return }
        waitingForInput = false
        let id = UUID()
        requestID = id
        phase = .starting
        status = "准备中"
        statusDetail = "正在准备麦克风和模型…"
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard phase == .starting, requestID == id else { return }
            guard allowed else {
                ended(error: "请在系统设置 → 隐私与安全性 → 麦克风中允许 Purrk。")
                return
            }
            do {
                devices.refresh()
                guard let device = selectedDevice(in: devices.snapshot) else {
                    waitingForInput = true
                    ended(error: unavailableInputMessage)
                    return
                }
                if note == nil {
                    let file = try Notes.start()
                    note = file
                    try loadTitle(for: file)
                    started = Date()
                    transcriptID = UUID()
                    transcript = []
                    tail = TranscriptTail()
                    hypothesis = ""
                    captionTail = []
                    savedTail = ""
                    unsavedLines = ""
                }
                try launchWorker(device: device, settings: settings ?? WorkerSettings())
            } catch { ended(error: error.localizedDescription) }
        }
    }

    private struct WorkerSettings {
        let engine: Engine
        let environment: [String: String]

        init() throws {
            engine = Engine.selected
            var env = ProcessInfo.processInfo.environment
            let defaults = UserDefaults.standard
            env["ACADEMIC_NOTES_ENGINE"] = engine.rawValue
            env.removeValue(forKey: "ACADEMIC_NOTES_API_KEY")
            if engine == .cloud {
                let region = defaults.string(forKey: "aliyunRegion") ?? "beijing"
                let key = try APIKeyStore.read(region)
                guard !key.isEmpty else {
                    throw NSError(domain: "Purrk", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "请在设置中保存所选地域的百炼 API Key。"
                    ])
                }
                env["ACADEMIC_NOTES_API_KEY"] = key
                env["ACADEMIC_NOTES_API_REGION"] = region
                env["ACADEMIC_NOTES_API_WORKSPACE"] = defaults.string(forKey: "aliyunWorkspace." + region)
            }
            env["ACADEMIC_NOTES_TERMS"] = defaults.string(forKey: "terms")
            env.removeValue(forKey: "PYTHONHOME")
            env.removeValue(forKey: "PYTHONPATH")
            env["PYTHONNOUSERSITE"] = "1"
            env["PYTHONUTF8"] = "1"
            environment = env
        }
    }

    private func launchWorker(device: InputDevice, settings: WorkerSettings) throws {
        let process = Process()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundledPython = Bundle.main.url(forResource: "python3.11", withExtension: nil,
                                            subdirectory: "runtime/bin")
        process.executableURL = bundledPython ?? support.appendingPathComponent("AcademicNotes/runtime/bin/python")
        guard let script = Bundle.main.url(forResource: "Transcribe", withExtension: "py") else {
            throw CocoaError(.fileNoSuchFile)
        }
        process.arguments = ["-B", script.path]
        var env = settings.environment
        env["ACADEMIC_NOTES_INPUT_ID"] = String(device.audioID)
        env["ACADEMIC_NOTES_INPUT_NAME"] = device.name
        process.environment = env
        let command = Pipe(), events = Pipe()
        process.standardInput = command
        process.standardOutput = events
        try process.run()
        input = command.fileHandleForWriting
        captureDevice = device
        Task {
            var failure: String?
            var disconnected = false
            do {
                for try await line in events.fileHandleForReading.bytes.lines {
                    guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if let message = event["status"] as? String, phase == .starting { statusDetail = message }
                    if event["ready"] as? Bool == true, let name = event["inputName"] as? String, phase == .starting {
                        activeInputName = name
                        phase = .live
                        status = settings.engine == .cloud ? "正在记录 · 云端" : "正在记录"
                        statusDetail = nil
                    }
                    if phase == .live, let level = event["level"] as? Double {
                        levelMeter.level = min(1, max(0, level))
                    }
                    updateTranscript(event, engine: settings.engine)
                    if let text = event["error"] as? String {
                        failure = text
                        disconnected = event["inputDisconnected"] as? Bool == true
                    }
                }
            } catch { failure = error.localizedDescription }
            process.waitUntilExit()
            if failure == nil && process.terminationStatus != 0 { failure = "转写进程意外退出。" }
            ended(error: failure, disconnected: disconnected, settings: settings)
        }
    }

    private var elapsed: Int { max(0, Int(Date().timeIntervalSince(started))) }

    private func updateTranscript(_ event: [String: Any], engine: Engine) {
        let pause = event["pauseBoundary"] as? Bool == true
        if let text = event["final"] as? String {
            hypothesis = ""
            var closed = tail.accept(text, at: elapsed, continues: event["continues"] as? Bool == true)
            if pause { closed += tail.pause(forUnpunctuatedSpeech: engine == .fireRed) }
            save(closed)
        } else if pause {
            save(tail.pause(forUnpunctuatedSpeech: engine == .fireRed))
        } else if let text = event["partial"] as? String {
            hypothesis = text
            refreshCaption()
        }
    }

    private func refreshCaption() {
        // Partial results replace the live hypothesis. Never feed them back into the note.
        let confirmed = tail.lines
        guard !hypothesis.isEmpty else { captionTail = confirmed.map(CaptionLine.init); return }
        var preview = tail
        let closed = preview.accept(hypothesis, at: elapsed)
        captionTail = (closed + preview.lines).enumerated().map { index, line in
            CaptionLine(line: line, confirmedText: confirmed.indices.contains(index) ? confirmed[index].text : nil)
        }
    }

    @discardableResult
    private func save(_ closed: [TranscriptLine]) -> Bool {
        if !closed.isEmpty {
            transcript.append(contentsOf: closed)
            unsavedLines += closed.map(\.noteLine).joined()
        }
        refreshCaption()
        guard let note else { return true }
        let newTail = tail.lines.map(\.noteLine).joined()
        let replacement = unsavedLines + newTail
        do {
            if replacement.hasPrefix(savedTail) {
                // The previous sentence is unchanged, so only append newly confirmed lines.
                try Notes.replaceTail("", with: String(replacement.dropFirst(savedTail.count)), in: note)
            } else {
                try Notes.replaceTail(savedTail, with: replacement, in: note)
            }
            savedTail = newTail
            unsavedLines = ""
            if saveError != nil { saveError = nil }
            return true
        } catch {
            saveError = "本地保存失败：" + error.localizedDescription
            return false
        }
    }

    func mark() { if phase == .live { save(tail.mark(at: elapsed)) } }

    private func loadTitle(for file: URL) throws {
        let name = try Notes.title(for: file)
        displayTitle = Notes.displayTitle(name, for: file)
        title = displayTitle
        titleError = ""
    }

    func commitTitle() {
        guard let note else { return }
        guard title != displayTitle else { titleError = ""; return }
        do {
            let file = try Notes.rename(title, for: note)
            self.note = file
            try loadTitle(for: file)
        } catch {
            titleError = "标题保存失败：" + error.localizedDescription
        }
    }

    func stop(pause: Bool = false) {
        guard phase != .idle else { return }
        stopWorker(for: pause ? .pause : .finish)
    }

    private func stopWorker(for action: StopAction) {
        waitingForInput = false
        stopAction = action
        status = action == .switchInput ? "切换输入中" : "正在保存"
        statusDetail = action == .switchInput ? "正在切换声音输入…" : "正在保存最后一句…"
        guard phase != .stopping else { return }
        commitTitle()
        phase = .stopping
        activeInputName = nil
        levelMeter.level = 0
        if let input { try? input.close() }
        else { ended(error: nil) }
    }

    private func ended(error: String?, disconnected: Bool = false, settings: WorkerSettings? = nil) {
        let oldDevice = captureDevice
        captureDevice = nil
        input = nil
        hypothesis = ""
        refreshCaption()
        activeInputName = nil
        levelMeter.level = 0
        commitTitle()
        let interrupted = error != nil && phase != .stopping
        let action = stopAction
        stopAction = .finish
        if note != nil && (action != .finish || interrupted) && !quitting {
            phase = .paused
            if disconnected { devices.refresh() }
            let nextDevice = selectedDevice(in: devices.snapshot)
            let replaceLostDevice = interrupted && disconnected && nextDevice != oldDevice
            if (action == .switchInput || replaceLostDevice) && (error == nil || disconnected), nextDevice != nil {
                start(using: settings)
                return
            }
            if nextDevice == nil && (disconnected || (action == .switchInput && error == nil)) {
                waitingForInput = true
            }
            status = waitingForInput ? "输入未连接" : "已暂停"
            statusDetail = waitingForInput ? unavailableInputMessage : error
            guard save(tail.finish()) else { return }
        } else {
            guard save(tail.finish()) else {
                phase = .paused
                status = "已暂停"
                statusDetail = error
                if quitting {
                    quitting = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
                return
            }
            if let note { Notes.finish(note) }
            note = nil
            phase = .idle
            status = waitingForInput ? "输入未连接" : (interrupted ? "无法开始记录" : "记录已结束")
            statusDetail = error
            sync()
        }
        if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    func terminate() -> NSApplication.TerminateReply {
        commitTitle()
        guard input != nil else {
            guard save(tail.finish()) else { return .terminateCancel }
            if let note { Notes.finish(note) }
            return .terminateNow
        }
        quitting = true
        stop()
        return .terminateLater
    }

    func sync() {
        guard !syncing else { syncAgain = true; return }
        syncing = true
        Task {
            let (url, failed) = await Notes.syncPending()
            if let url { cloudURL = url }
            syncFailed = failed
            syncing = false
            if syncAgain { syncAgain = false; sync() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Session.shared.terminate()
    }
}

@main
struct Purrk: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var session = Session.shared
    @AppStorage("captionsPinned") private var pinned = true
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Purrk", id: "captions") { Captions(session: session, pinned: $pinned) }
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .windowToolbarLabelStyle(fixed: .iconOnly)
            .defaultSize(width: 420, height: 240)
            .windowLevel(pinned ? .floating : .normal)
        MenuBarExtra {
            Button("显示字幕窗口", systemImage: "macwindow") { openWindow(id: "captions"); NSApp.activate(ignoringOtherApps: true) }
            if session.phase != .idle {
                Button("结束记录", systemImage: "stop") { session.stop() }.disabled(!session.canEnd)
            }
            Divider()
            Button("退出 Purrk") { NSApp.terminate(nil) }
        } label: {
            MenuBarIcon(recording: session.phase == .live)
        }
        Settings { Preferences() }
            .defaultSize(width: 480, height: 430)
            .windowLevel(.floating)
    }
}
