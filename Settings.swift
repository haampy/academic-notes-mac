import Security
import SwiftUI

enum Engine: String, CaseIterable {
    case standard = "qwen-1.7b", light = "qwen-0.6b"
    case fireRed = "firered-aed", r2t2 = "r2t2-8bit", cloud = "aliyun-api"

    static var selected: Engine {
        Engine(rawValue: UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "") ?? .standard
    }

    var label: String {
        switch self {
        case .standard: "本地 · Qwen3-ASR 1.7B"
        case .light: "本地 · Qwen3-ASR 0.6B（轻量）"
        case .fireRed: "本地 · FireRedASR2-AED（中文分句定稿）"
        case .r2t2: "本地 · Confucius4-R2T2（中英实时字幕）"
        case .cloud: "云端 API · 阿里云百炼"
        }
    }

    var downloadSize: String? {
        switch self {
        case .standard: "2.2 GB"
        case .light: "840 MB"
        case .fireRed: "4.57 GB"
        case .r2t2: "2.48 GB"
        case .cloud: nil
        }
    }
}

enum APIKeyStore {
    private static func item(_ region: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.academicnotes.mac.aliyun",
         kSecAttrAccount as String: region]
    }

    static func read(_ region: String) throws -> String {
        var query = item(region)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String, region: String) throws {
        var query = item(region)
        var status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
        } else {
            let update = [kSecValueData as String: Data(value.utf8)]
            status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                query[kSecValueData as String] = Data(value.utf8)
                status = SecItemAdd(query as CFDictionary, nil)
            }
        }
        if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

private struct CloudCredentials: View {
    let region: String
    let typography: CaptionTypography
    @AppStorage private var workspace: String
    @State private var draft = ""
    @State private var saved = ""
    @State private var message = ""

    init(region: String, typography: CaptionTypography) {
        self.region = region
        self.typography = typography
        _workspace = AppStorage(wrappedValue: "", "aliyunWorkspace." + region)
    }

    var body: some View {
        TextField("Workspace ID", text: $workspace, prompt: Text("可选，使用百炼专属域名"))
        LabeledContent("API Key") {
            SecureField("API Key", text: $draft, prompt: Text("所选地域的百炼密钥"))
                .labelsHidden()
                .onSubmit { save() }
                .onAppear {
                    do {
                        saved = try APIKeyStore.read(region)
                        draft = saved
                    } catch { message = "钥匙串读取失败：" + error.localizedDescription }
                }
            Button("保存") { save() }.disabled(draft == saved)
        }
        if !message.isEmpty { Text(message).font(.system(size: typography.deviceSize)).foregroundStyle(.secondary) }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = key
        guard key != saved else { return }
        do {
            try APIKeyStore.save(key, region: region)
            saved = key
            message = key.isEmpty ? "已移除密钥" : "已存入 macOS 钥匙串"
        } catch { message = "钥匙串保存失败：" + error.localizedDescription }
    }
}

struct Preferences: View {
    @AppStorage(CaptionTypography.preferenceKey) private var fontSize = CaptionTypography.defaultSize
    @AppStorage("transcriptionEngine") private var engine = Engine.standard
    @AppStorage("aliyunRegion") private var region = "beijing"
    @AppStorage("terms") private var terms = ""
    @AppStorage("feishuFolderToken") private var folder = ""

    private var typography: CaptionTypography { CaptionTypography(fontSize) }

    // A native menu keeps keyboard navigation. Its custom label also follows the chosen point size.
    private func choice<Value: Hashable, Options: View>(
        _ title: String, selection: Binding<Value>, value: String, @ViewBuilder options: () -> Options
    ) -> some View {
        LabeledContent {
            Menu {
                Picker(title, selection: selection, content: options).pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Text(value).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: typography.statusSize, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: typography.bodySize))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .help(value)
        } label: {
            Text(title).fixedSize()
        }
    }

    private func pointSizeLabel(_ size: Int) -> String {
        size == CaptionTypography.defaultSize ? "\(size) 点（默认）" : "\(size) 点"
    }

    private var transcription: some View {
        Section {
            choice("转写引擎", selection: $engine, value: engine.label) {
                ForEach(Engine.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if engine == .cloud {
                Text("音频会发往所选地域的百炼服务，由你的账号按量付费。")
                    .font(.system(size: typography.deviceSize)).foregroundStyle(.secondary)
                choice("服务地域", selection: $region, value: region == "singapore" ? "新加坡" : "北京") {
                    Text("北京").tag("beijing")
                    Text("新加坡").tag("singapore")
                }
                CloudCredentials(region: region, typography: typography).id(region)
            } else if let size = engine.downloadSize {
                Text("首次下载约 \(size)，之后可离线使用。")
                    .font(.system(size: typography.deviceSize)).foregroundStyle(.secondary)
                if engine == .fireRed {
                    Text("支持普通话、方言和中英混说。字幕逐句显示，不加标点。")
                        .font(.system(size: typography.deviceSize)).foregroundStyle(.secondary)
                } else if engine == .r2t2 {
                    Text("使用此模型即接受[《网易有道模型使用许可协议》](https://github.com/netease-youdao/Confucius4-R2T2/blob/master/MODEL_LICENSE_zh)。")
                        .font(.system(size: typography.deviceSize))
                }
            }
            if engine != .fireRed {
                TextField("课题术语", text: $terms, prompt: Text("例如 CRISPR, Cas9, off-target"))
            }
        } header: {
            Text("转写")
        } footer: {
            Text("下次开始或继续记录时生效。").font(.system(size: typography.deviceSize))
        }
    }

    var body: some View {
        Form {
            Section("显示") {
                choice("字体大小", selection: $fontSize, value: pointSizeLabel(fontSize)) {
                    ForEach(CaptionTypography.sizes, id: \.self) { size in
                        Text(pointSizeLabel(size)).tag(size)
                    }
                }
            }
            transcription
            Section("飞书同步") {
                TextField("文件夹 token", text: $folder, prompt: Text("留空使用「Purrk」文件夹"))
            }
        }
        .font(.system(size: typography.bodySize))
        .controlSize(fontSize >= 18 ? .large : .regular)
        .formStyle(.grouped)
        .frame(minWidth: 450, idealWidth: 480, minHeight: 360, idealHeight: 430)
    }
}
