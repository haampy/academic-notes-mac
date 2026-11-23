import AVFoundation
import SwiftUI
import Network

@MainActor
final class Session: ObservableObject {
    static let shared = Session()
    enum Phase { case idle, starting, live, stopping, paused }
    @Published var phase = Phase.idle
    @Published var transcript = ""
    @Published var partial = ""
    @Published var title = ""
    @Published var titleError = ""
    @Published var status = "准备开始"
    @Published var syncFailed = false
    @Published var cloudURL: URL?
    @Published var syncing = false
    private var input: FileHandle?
    private var note: URL?
    private var savedTitle = ""
    var canRename: Bool { note != nil && phase != .stopping }
    private var started = Date()
    private var pauseRequested = false
    private var quitting = false
    private var opened = false
    private var requestID = UUID()
    private var syncAgain = false
    private let network = NWPathMonitor()

    func open() {
        guard !opened else { return }
        opened = true
        network.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { Task { @MainActor in self?.sync() } }
        }
        network.start(queue: DispatchQueue(label: "academicnotes.network"))
        start()
        sync()
    }

    func start() {
        guard phase == .idle || phase == .paused else { return }
        let id = UUID()
        requestID = id
        phase = .starting
        status = "正在准备麦克风和模型…"
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard phase == .starting, requestID == id else { return }
            guard allowed else {
                ended(error: "请在系统设置 → 隐私与安全性 → 麦克风中允许 Purrk。")
                return
            }
            do {
                if note == nil {
                    let file = try Notes.start()
                    note = file
                    savedTitle = try Notes.title(for: file)
                    title = savedTitle
                    titleError = ""
                    started = Date()
                    transcript = ""
                    partial = ""
                }
                try launchWorker()
            } catch { ended(error: error.localizedDescription) }
        }
    }

    private func launchWorker() throws {
        let process = Process()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundledPython = Bundle.main.url(forResource: "python3.11", withExtension: nil,
                                            subdirectory: "runtime/bin")
        process.executableURL = bundledPython ?? support.appendingPathComponent("AcademicNotes/runtime/bin/python")
        guard let script = Bundle.main.url(forResource: "Transcribe", withExtension: "py") else {
            throw CocoaError(.fileNoSuchFile)
        }
        process.arguments = ["-B", script.path]
        var env = ProcessInfo.processInfo.environment
        let engine = Engine.selected
        env["ACADEMIC_NOTES_ENGINE"] = engine.rawValue
        env.removeValue(forKey: "ACADEMIC_NOTES_API_KEY")
        if engine == .cloud {
            let defaults = UserDefaults.standard
            let region = defaults.string(forKey: "aliyunRegion") ?? "beijing"
            let key = try APIKeyStore.read(region)
            guard !key.isEmpty else {
                throw NSError(domain: "Purrk", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "请在设置中保存当前地域的百炼 API Key，再继续记录。"
                ])
            }
            env["ACADEMIC_NOTES_API_KEY"] = key
            env["ACADEMIC_NOTES_API_REGION"] = region
            env["ACADEMIC_NOTES_API_WORKSPACE"] = defaults.string(forKey: "aliyunWorkspace." + region)
        }
        env["ACADEMIC_NOTES_TERMS"] = UserDefaults.standard.string(forKey: "terms")
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONUTF8"] = "1"
        process.environment = env
        let command = Pipe(), events = Pipe()
        process.standardInput = command
        process.standardOutput = events
        try process.run()
        input = command.fileHandleForWriting
        Task {
            var failure: String?
            do {
                for try await line in events.fileHandleForReading.bytes.lines {
                    guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if let message = event["status"] as? String, phase == .starting { status = message }
                    if event["ready"] != nil, phase == .starting {
                        phase = .live
                        status = engine == .cloud ? "正在记录 · 云端" : "正在记录"
                    }
                    if let text = event["partial"] as? String { partial = text }
                    if let text = event["final"] as? String { save(text); partial = "" }
                    if let text = event["error"] as? String { failure = text }
                }
            } catch { failure = error.localizedDescription }
            process.waitUntilExit()
            if failure == nil && process.terminationStatus != 0 { failure = "转写进程意外退出。" }
            ended(error: failure)
        }
    }

    private func save(_ text: String) {
        guard let note else { return }
        let seconds = max(0, Int(Date().timeIntervalSince(started)))
        let line = String(format: "[%02d:%02d] ", seconds / 60, seconds % 60) + text
        transcript += (transcript.isEmpty ? "" : "\n\n") + line
        do { try Notes.append(line, to: note) }
        catch { status = "本地保存失败：" + error.localizedDescription }
    }

    func mark() { if phase == .live { save("★ 重点") } }

    func commitTitle() {
        guard let note, title != savedTitle else { return }
        do {
            let file = try Notes.rename(title, for: note)
            self.note = file
            savedTitle = try Notes.title(for: file)
            title = savedTitle
            titleError = ""
        } catch {
            titleError = "标题保存失败：" + error.localizedDescription
        }
    }

    func stop(pause: Bool = false) {
        guard phase != .idle && phase != .stopping else { return }
        commitTitle()
        pauseRequested = pause
        phase = .stopping
        status = "正在保存最后一句…"
        if let input { try? input.close() }
        else { ended(error: nil) }
    }

    private func ended(error: String?) {
        input = nil
        partial = ""
        commitTitle()
        let interrupted = error != nil && phase != .stopping
        if note != nil && (pauseRequested || interrupted) && !quitting {
            phase = .paused
            status = error ?? "已暂停"
        } else {
            if let note { Notes.finish(note) }
            note = nil
            phase = .idle
            status = error ?? "记录已结束"
            sync()
        }
        pauseRequested = false
        if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    func terminate() -> NSApplication.TerminateReply {
        commitTitle()
        guard input != nil else {
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

struct Captions: View {
    @ObservedObject var session: Session
    @Binding var pinned: Bool
    @Environment(\.openURL) private var openURL
    @FocusState private var editingTitle: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("笔记标题", text: $session.title)
                    .accessibilityLabel("笔记标题")
                    .help("修改当前笔记标题，按回车保存")
                    .focused($editingTitle)
                    .disabled(!session.canRename)
                    .onSubmit { session.commitTitle(); editingTitle = false }
                    .onChange(of: editingTitle) { _, focused in
                        if !focused { session.commitTitle() }
                    }
                Button("本地笔记") { NSWorkspace.shared.open(Notes.directory) }
                Toggle(isOn: $pinned) {
                    Label("字幕窗口置顶", systemImage: pinned ? "pin.fill" : "pin.slash")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(pinned ? "取消字幕窗口置顶" : "将字幕窗口置顶")
                .accessibilityValue(pinned ? "已置顶" : "未置顶")
            }
            HStack {
                Circle().fill(session.phase == .live ? Color.red : .secondary).frame(width: 8, height: 8)
                Text(session.status).font(.subheadline).textSelection(.enabled)
            }
            if !session.titleError.isEmpty { Text(session.titleError).font(.caption).foregroundStyle(.red) }
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !session.transcript.isEmpty { Text(session.transcript).textSelection(.enabled) }
                        Text(session.partial).foregroundStyle(.secondary)
                        Color.clear.frame(height: 1).id("end")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.title3)
                .onChange(of: session.partial) { _, _ in scroll.scrollTo("end") }
                .onChange(of: session.transcript) { _, _ in scroll.scrollTo("end") }
            }
            Divider()
            HStack {
                if session.phase == .live {
                    Button("标重点") { session.mark() }.keyboardShortcut("b")
                    Button("暂停") { session.stop(pause: true) }
                }
                if session.phase == .idle || session.phase == .paused {
                    Button(session.phase == .idle ? "开始记录" : "继续") { session.start() }
                }
                if session.phase != .idle {
                    Button("结束") { session.stop() }.disabled(session.phase == .stopping)
                }
                Spacer()
                Button("打开最近的飞书笔记") {
                    if let url = session.cloudURL { openURL(url) }
                }.disabled(session.cloudURL == nil)
                if session.syncFailed {
                    Button("重试同步") { session.sync() }
                        .disabled(session.syncing)
                        .help("同步失败。请检查网络、飞书授权和文件夹权限后重试。")
                }
                SettingsLink { Image(systemName: "gearshape") }.help("转写引擎、术语和飞书设置")
            }
        }
        .padding(16).frame(minWidth: 450, minHeight: 225)
        .onAppear { session.open() }
        .onDisappear { session.stop() }
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
            .defaultSize(width: 570, height: 315)
            .windowLevel(pinned ? .floating : .normal)
        MenuBarExtra("Purrk", systemImage: session.phase == .live ? "mic.fill" : "mic") {
            Button("显示字幕") { openWindow(id: "captions"); NSApp.activate(ignoringOtherApps: true) }
            if session.phase != .idle { Button("结束记录") { session.stop() } }
            Button("退出") { NSApp.terminate(nil) }
        }
        Settings { Preferences() }.windowLevel(.floating)
    }
}
