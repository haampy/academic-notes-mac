import SwiftUI

struct Captions: View {
    @ObservedObject var session: Session
    @Binding var pinned: Bool
    @Environment(\.colorScheme) private var appearance
    @Environment(\.openURL) private var openURL
    @AppStorage(CaptionTypography.preferenceKey) private var fontSize = CaptionTypography.defaultSize
    @State private var renamingTitle = false

    private var typography: CaptionTypography { CaptionTypography(fontSize) }

    private var paper: Color {
        appearance == .dark ? Color(red: 0.145, green: 0.137, blue: 0.125)
                            : Color(red: 1, green: 0.992, blue: 0.976)
    }

    private var footer: Color {
        appearance == .dark ? Color(red: 0.180, green: 0.169, blue: 0.153)
                            : Color(red: 0.969, green: 0.961, blue: 0.941)
    }

    private var isTransitioning: Bool { session.phase == .starting || session.phase == .stopping }

    private var emptyMessage: String {
        if let detail = session.statusDetail { return detail }
        switch session.phase {
        case .live: return "等待第一句话…"
        case .paused: return "继续记录即可查看字幕"
        case .idle: return session.status == "记录已结束" ? "本次未识别到文字" : "开始记录即可查看字幕"
        case .starting, .stopping: return session.status
        }
    }

    @ViewBuilder private func message(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: typography.bodySize))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !session.titleError.isEmpty { message(session.titleError, symbol: "exclamationmark.triangle") }
            if let error = session.saveError { message(error, symbol: "exclamationmark.triangle") }
            if let detail = session.statusDetail, session.hasCaptions {
                message(detail, symbol: isTransitioning ? "hourglass" : "exclamationmark.triangle")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var noteTitle: some View {
        let label = Text(session.displayTitle)
            .font(.system(size: typography.titleSize, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 190, alignment: .leading)
        return Group {
            if session.canRename {
                Button { renamingTitle = true } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel("修改笔记标题，" + session.displayTitle)
            } else {
                label
            }
        }
        .help(session.displayTitle + (session.canRename ? " · 点按修改标题" : ""))
        .popover(isPresented: $renamingTitle, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("笔记标题").font(.system(size: typography.statusSize)).foregroundStyle(.secondary)
                TextField("笔记标题", text: $session.title)
                    .labelsHidden()
                    .font(.system(size: typography.bodySize))
                    .onSubmit { renamingTitle = false }
            }
            .padding(12)
            .frame(width: 260)
            .onDisappear { session.commitTitle() }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("重命名笔记…", systemImage: "pencil") { renamingTitle = true }
                .disabled(!session.canRename)
            Divider()
            Button("打开笔记文件夹", systemImage: "folder") { NSWorkspace.shared.open(Notes.directory) }
            Button("打开最近的飞书笔记", systemImage: "arrow.up.right.square") {
                if let url = session.cloudURL { openURL(url) }
            }
            .disabled(session.cloudURL == nil)
            if session.syncFailed {
                Button("重试飞书同步", systemImage: "arrow.clockwise.icloud") { session.sync() }
                    .disabled(session.syncing)
            }
        } label: {
            Label("更多操作", systemImage: session.syncFailed ? "exclamationmark.icloud" : "ellipsis")
        }
        .menuIndicator(.hidden)
        .help(session.syncFailed ? "飞书同步失败，点按可重试" : "更多操作")
    }

    private var controls: some View {
        let live = session.phase == .live
        let action = live ? "暂停" : (session.phase == .paused ? "继续" : "开始")
        return HStack(spacing: 5) {
            Button { session.mark() } label: {
                Image(systemName: "star").frame(width: 28, height: 28)
            }
            .disabled(!live)
            .keyboardShortcut("b")
            .accessibilityLabel("标重点")
            .help("标重点（⌘B）")
            Button {
                if live { session.stop(pause: true) } else { session.start() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: live ? "pause.fill" : "play.fill").font(.system(size: typography.statusSize))
                    Text(action).font(.system(size: typography.actionSize, weight: .medium))
                }
                .padding(.horizontal, 13)
                .frame(minHeight: max(28, typography.actionSize + 10))
                .foregroundStyle(appearance == .dark ? Color.black : Color.white)
                .background(appearance == .dark ? Color(white: 0.88) : Color(white: 0.22),
                            in: RoundedRectangle(cornerRadius: 7))
            }
            .disabled(isTransitioning)
            .help(action + "记录")
            Button { session.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 28, height: 28)
            }
            .disabled(session.phase == .idle || !session.canEnd)
            .accessibilityLabel("结束记录")
            .help("结束并保存笔记")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.hasCaptions {
                TranscriptView(session: session, typography: typography)
            } else {
                let symbol = isTransitioning ? "hourglass" : (session.statusDetail == nil ? "waveform" : "exclamationmark.triangle")
                ScrollView {
                    message(emptyMessage, symbol: symbol)
                        .padding(.horizontal, 18).padding(.vertical, 16)
                }
                .defaultScrollAnchor(.center, for: .alignment)
            }
            if !session.titleError.isEmpty || session.saveError != nil || (session.hasCaptions && session.statusDetail != nil) {
                ViewThatFits(in: .vertical) {
                    notices
                    ScrollView { notices }
                }
                .frame(maxHeight: 64)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 8) {
                InputMonitor(session: session, typography: typography)
                Spacer(minLength: 4)
                controls
            }
            .padding(.leading, 15).padding(.trailing, 10).padding(.vertical, 8)
            .background(footer)
        }
        .frame(minWidth: 420, minHeight: 145)
        .background(paper)
        .toolbarBackground(paper, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) { noteTitle }.unframedTitle()
            ToolbarItem { Spacer() }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("字幕窗口置顶", systemImage: pinned ? "pin.fill" : "pin") { pinned.toggle() }
                    .accessibilityValue(pinned ? "已置顶" : "未置顶")
                    .accessibilityAddTraits(pinned ? .isSelected : [])
                    .help(pinned ? "取消置顶" : "置顶字幕窗口")
                moreMenu
                SettingsLink { Label("设置", systemImage: "gearshape") }
                    .help("设置")
            }
        }
        .onChange(of: session.canRename) { _, canRename in
            if !canRename { renamingTitle = false }
        }
        .onAppear { session.open() }
        .onDisappear { session.stop() }
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder func unframedTitle() -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}
