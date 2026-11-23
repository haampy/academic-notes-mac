import Security
import SwiftUI

enum Engine: String {
    case standard = "qwen-1.7b", light = "qwen-0.6b", cloud = "aliyun-api"

    static var selected: Engine {
        Engine(rawValue: UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "") ?? .standard
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
    @AppStorage private var workspace: String
    @State private var draft = ""
    @State private var saved = ""
    @State private var message = ""

    init(region: String) {
        self.region = region
        _workspace = AppStorage(wrappedValue: "", "aliyunWorkspace." + region)
    }

    var body: some View {
        TextField("Workspace ID", text: $workspace, prompt: Text("可选，使用百炼专属域名"))
        LabeledContent("API Key") {
            SecureField("API Key", text: $draft, prompt: Text("输入本地域的百炼密钥"))
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
        if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
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
    @AppStorage("transcriptionEngine") private var engine = Engine.standard
    @AppStorage("aliyunRegion") private var region = "beijing"
    @AppStorage("terms") private var terms = ""
    @AppStorage("feishuFolderToken") private var folder = ""

    var body: some View {
        Form {
            Picker("转写引擎", selection: $engine) {
                Text("本地 · Qwen3-ASR 1.7B").tag(Engine.standard)
                Text("本地 · Qwen3-ASR 0.6B（轻量）").tag(Engine.light)
                Text("云端 API · 阿里云百炼").tag(Engine.cloud)
            }
            if engine == .cloud {
                Text("麦克风音频会发送到所选地域的百炼实时转写服务，费用按你的账号用量结算。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("服务地域", selection: $region) {
                    Text("北京").tag("beijing")
                    Text("新加坡").tag("singapore")
                }
                CloudCredentials(region: region).id(region)
            } else {
                Text("首次使用会下载所选模型，之后可离线转写。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("课题术语", text: $terms, prompt: Text("例如 CRISPR, Cas9, off-target"))
            TextField("飞书文件夹 token", text: $folder, prompt: Text("留空保存到个人云盘"))
            Text("引擎和术语在下次开始或继续记录时生效。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 450)
    }
}
