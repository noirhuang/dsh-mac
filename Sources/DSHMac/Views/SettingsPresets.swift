import SwiftUI
import AppKit

// MARK: - Agent 预设分区（官方 AgentPresetSection：内置/自定义两组卡片网格）

struct AgentPresetsSection: View {
    @EnvironmentObject private var app: AppState

    @State private var presets: [AppState.AgentPresetEntry] = []
    @State private var authorable = false
    @State private var status = "loading"
    @State private var writable = true
    @State private var viewer: ViewerState?
    @State private var copying: AppState.AgentPresetEntry?
    @State private var deleting: AppState.AgentPresetEntry?
    @State private var pathHint: String?

    struct ViewerState: Identifiable {
        let id = UUID()
        let title: String
        let content: String
    }

    var body: some View {
        Group {
            switch status {
            case "loading":
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.t("加载中…", "Loading…")).font(.system(size: 13)).foregroundStyle(DSH.labelTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case "error":
                Button(L.t("重试", "Retry")) { Task { await load() } }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                // 官方：空 roster → 整分区隐藏（unavailable）
                if presets.isEmpty {
                    EmptyView()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            header
                            group(title: L.t("内置", "Built-in"), entries: presets.filter { $0.trust == "system" })
                            group(title: L.t("自定义", "Custom"), entries: presets.filter { $0.trust == "user" })
                            if let p = pathHint {
                                Text(L.t("预设文件：\(p)", "Preset files: \(p)"))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DSH.labelTertiary)
                            }
                        }
                        .padding(28)
                    }
                }
            }
        }
        .task { await load() }
        .sheet(item: $viewer) { v in
            viewerSheet(v).frame(width: 640, height: 520)
        }
        .sheet(item: $copying) { preset in
            copyDialog(preset).frame(width: 440)
        }
        .sheet(item: $deleting) { preset in
            deleteDialog(preset).frame(width: 440)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t("Agent 预设", "Agent presets"))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DSH.labelPrimary)
            Text(L.t("点选卡片设为新会话的默认预设；运行中的会话不受影响。", "Click a card to set the default for new sessions; running sessions are unaffected."))
                .font(.system(size: 14))
                .foregroundStyle(DSH.labelTertiary)
        }
    }

    private func group(title: String, entries: [AppState.AgentPresetEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DSH.labelTertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 268), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(entries) { preset in
                    presetCard(preset)
                }
            }
        }
    }

    // ---- 卡片（官方：主体即"设为默认"按钮；选中态 aria）----

    private func presetCard(_ preset: AppState.AgentPresetEntry) -> some View {
        let broken = preset.broken != nil
        let disabled = preset.isDefault || broken || !writable
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await makeDefault(preset.id) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(displayName(preset))
                            .font(.system(size: 14, weight: preset.isDefault ? .medium : .regular))
                            .foregroundStyle(DSH.labelPrimary)
                        if preset.trust == "user" {
                            Text(L.t("自定义", "Custom"))
                                .font(.system(size: 10))
                                .foregroundStyle(DSH.labelSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).strokeBorder(DSH.borderL2, lineWidth: 1))
                        }
                        if preset.isDefault {
                            Text(L.t("当前使用", "In use"))
                                .font(.system(size: 10))
                                .foregroundStyle(DSH.businessPrimary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(DSH.businessPrimary.opacity(0.12)))
                        }
                        if broken {
                            Text(L.t("加载失败", "Broken"))
                                .font(.system(size: 10))
                                .foregroundStyle(DSH.errorPrimary)
                        }
                    }
                    if let desc = preset.description {
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundStyle(DSH.labelTertiary)
                            .lineLimit(4)
                    }
                    if let reason = preset.broken {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(DSH.errorPrimary)
                            .lineLimit(2)
                    }
                    Text(preset.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DSH.labelCaption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(preset.isDefault ? DSH.hoverBg : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(preset.isDefault ? DSH.labelCaption : DSH.borderL2, lineWidth: 1))
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(disabled)

            // foot 操作行
            HStack(spacing: 2) {
                if preset.trust == "system" {
                    cardAction(L.t("查看", "View"), symbol: "doc.text") {
                        Task { await view(preset) }
                    }
                } else {
                    cardAction(L.t("打开目录", "Open location"), symbol: "folder") {
                        Task { await openLocation(preset.id) }
                    }
                }
                cardAction(L.t("复制", "Copy"), symbol: "doc.on.doc") {
                    copying = preset
                }
                .disabled(!authorable || broken)
                if preset.trust == "user" {
                    cardAction(L.t("删除", "Delete"), symbol: "trash", tint: DSH.errorPrimary) {
                        deleting = preset
                    }
                }
                Spacer()
            }
        }
    }

    private func cardAction(_ title: String, symbol: String, tint: Color = DSH.labelTertiary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBg, shape: AnyShape(RoundedRectangle(cornerRadius: 6))))
        .help(title)
    }

    private func displayName(_ preset: AppState.AgentPresetEntry) -> String {
        switch preset.id {
        case "standard": return L.t("标准", "Standard")
        case "code": return L.t("代码", "Code")
        case "minimal": return L.t("极简", "Minimal")
        case "cordis": return L.t("创造模式", "Cordis")
        default: return preset.name ?? preset.id
        }
    }

    // ---- 操作 ----

    private func load() async {
        status = "loading"
        do {
            let (list, canAuthor) = try await app.agentPresetList()
            presets = list
            authorable = canAuthor
            if let snap = try? await app.settingsDescribe() { writable = snap.writable }
            status = "ready"
        } catch {
            status = "error"
        }
    }

    private func makeDefault(_ id: String) async {
        do {
            let snap = try await app.settingsDescribe()
            _ = try await app.settingsUpdate(
                ns: "agent-presets",
                patch: ["default": .string(id)],
                expectedRevision: snap.revisions["agent-presets"]
            )
            await load()
        } catch {
            app.toast = error.localizedDescription
        }
    }

    private func view(_ preset: AppState.AgentPresetEntry) async {
        if let content = try? await app.agentPresetRead(id: preset.id) {
            viewer = ViewerState(title: displayName(preset), content: content)
        }
    }

    /// 原生替换官方 openDocument：返回 path 时 NSWorkspace reveal
    private func openLocation(_ id: String) async {
        if let path = try? await app.agentPresetOpenDocument(id: id) {
            pathHint = path
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    // ---- 查看器 ----

    private func viewerSheet(_ v: ViewerState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("查看 · \(v.title)", "View · \(v.title)"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L.t("组装（agent.cordis.yml）", "Composition (agent.cordis.yml)"))
                        .font(.system(size: 12)).foregroundStyle(DSH.labelTertiary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            ScrollView {
                Text(v.content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DSH.labelPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(DSH.bgBase)
    }

    // ---- 复制对话框（官方唯一创建方式）----

    private func copyDialog(_ preset: AppState.AgentPresetEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("复制 \(displayName(preset))", "Copy \(displayName(preset))"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DSH.labelPrimary)
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("新预设 ID", "New preset ID")).font(.system(size: 12, weight: .medium)).foregroundStyle(DSH.labelSecondary)
                TextField("my-agent", text: $copyId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                if let e = copyError {
                    Text(e).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("显示名称（可选）", "Display name (optional)")).font(.system(size: 12, weight: .medium)).foregroundStyle(DSH.labelSecondary)
                TextField(displayName(preset), text: $copyName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(L.t("取消", "Cancel")) { copying = nil; copyId = ""; copyName = ""; copyError = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(DSH.labelSecondary)
                    .padding(.horizontal, 14).frame(height: 32)
                Button {
                    Task { await doCopy(from: preset.id) }
                } label: {
                    Text(L.t("复制", "Copy"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(Capsule().fill(copyReady ? DSH.businessPrimary : DSH.labelCaption))
                }
                .buttonStyle(.plain)
                .disabled(!copyReady)
            }
        }
        .padding(20)
        .onAppear {
            copyError = nil
            copyId = ""
            copyName = ""
        }
    }

    @State private var copyId = ""
    @State private var copyName = ""
    @State private var copyError: String?

    private var copyReady: Bool {
        !copyId.isEmpty && copyIdFailure == nil
    }

    private var copyIdFailure: String? {
        if copyId.isEmpty { return nil }
        if copyId.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) == nil {
            return L.t("格式无效（小写字母、数字、连字符）", "Invalid format (lowercase, digits, hyphens)")
        }
        if presets.contains(where: { $0.id == copyId }) { return L.t("ID 已存在", "ID already exists") }
        return nil
    }

    private func doCopy(from: String) async {
        do {
            try await app.agentPresetCopy(from: from, newId: copyId, name: copyName.isEmpty ? nil : copyName)
            copying = nil
            copyId = ""
            copyName = ""
            await load()
            await openLocation(copyIdForReveal)
        } catch {
            copyError = error.localizedDescription
        }
    }

    // copy 成功后 openLocation 使用新 id（先记录）
    @State private var copyIdForReveal = ""
    private func revealSetup(_ id: String) { copyIdForReveal = id }

    // ---- 删除确认 ----

    private func deleteDialog(_ preset: AppState.AgentPresetEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("删除 \(displayName(preset))？", "Delete \(displayName(preset))?"))
                .font(.system(size: 15, weight: .semibold))
            Text(L.t("自定义预设将被删除，此操作不可撤销。", "The custom preset will be deleted. This cannot be undone."))
                .font(.system(size: 13))
                .foregroundStyle(DSH.labelSecondary)
            HStack {
                Spacer()
                Button(L.t("取消", "Cancel")) { deleting = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(DSH.labelSecondary)
                    .padding(.horizontal, 14).frame(height: 32)
                Button {
                    Task {
                        try? await app.agentPresetRemove(id: preset.id)
                        deleting = nil
                        await load()
                    }
                } label: {
                    Text(L.t("删除", "Delete"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DSH.errorPrimary)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(Capsule().strokeBorder(DSH.errorPrimary, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
    }
}
