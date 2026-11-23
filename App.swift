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
    @Published var status = "准备开始"
    @Published var syncMessage = ""
    @Published var cloudURL: URL?
    @Published var syncing = false
    private var input: FileHandle?
    private var note: URL?
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
                ended(error: "请在系统设置 → 隐私与安全性 → 麦克风中允许 Academic Notes。")
                return
            }
            do {
                if note == nil {
                    note = try Notes.start()
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
        process.executableURL = support.appendingPathComponent("AcademicNotes/runtime/bin/python")
        guard let script = Bundle.main.url(forResource: "Transcribe", withExtension: "py") else {
            throw CocoaError(.fileNoSuchFile)
        }
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["ACADEMIC_NOTES_TERMS"] = UserDefaults.standard.string(forKey: "terms")
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
                    guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if event["ready"] != nil, phase == .starting { phase = .live; status = "正在记录" }
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

    func stop(pause: Bool = false) {
        guard phase != .idle && phase != .stopping else { return }
        pauseRequested = pause
        phase = .stopping
        status = "正在保存最后一句…"
        if let input { try? input.close() }
        else { ended(error: nil) }
    }

    private func ended(error: String?) {
        input = nil
        partial = ""
        if pauseRequested && error == nil && !quitting {
            phase = .paused
            status = "已暂停"
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
            let (url, message) = await Notes.syncPending()
            if let url { cloudURL = url }
            syncMessage = message
            syncing = false
            if syncAgain { syncAgain = false; sync() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Session.shared.terminate()
    }
}

struct Captions: View {
    @ObservedObject var session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(session.phase == .live ? Color.red : .secondary).frame(width: 8, height: 8)
                Text(session.status).font(.subheadline)
                Spacer()
                Button("本地笔记") { NSWorkspace.shared.open(Notes.directory) }
            }
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
                if let url = session.cloudURL { Link("最近同步的笔记", destination: url) }
                Button("同步") { session.sync() }.disabled(session.syncing)
                SettingsLink { Image(systemName: "gearshape") }.help("术语和飞书文件夹")
            }
            if !session.syncMessage.isEmpty {
                Text(session.syncMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(16).frame(minWidth: 450, minHeight: 225)
        .onAppear { session.open() }
        .onDisappear { session.stop() }
    }
}

@main
struct AcademicNotes: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var session = Session.shared
    @AppStorage("terms") private var terms = ""
    @AppStorage("feishuFolderToken") private var folder = ""
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Academic Notes", id: "captions") { Captions(session: session) }
            .defaultSize(width: 570, height: 315)
            .windowLevel(.floating)
        MenuBarExtra("Academic Notes", systemImage: session.phase == .live ? "mic.fill" : "mic") {
            Button("显示字幕") { openWindow(id: "captions"); NSApp.activate(ignoringOtherApps: true) }
            if session.phase != .idle { Button("结束记录") { session.stop() } }
            Button("退出") { NSApp.terminate(nil) }
        }
        Settings {
            Form {
                TextField("课题术语", text: $terms, prompt: Text("例如 CRISPR, Cas9, off-target"))
                TextField("飞书文件夹 token", text: $folder, prompt: Text("留空保存到个人云盘"))
                Text("术语在下次开始或继续记录时生效。").font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(width: 420)
        }
    }
}
