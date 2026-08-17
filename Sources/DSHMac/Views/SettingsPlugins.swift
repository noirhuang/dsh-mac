import SwiftUI
import AppKit

// MARK: - 插件分区（官方 PluginsSettingsSection：2 tab —— 插件配置 + 插件列表）

struct PluginsSettingsSection: View {
    @State private var tab = "configurable"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("插件", "Plugins"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DSH.labelPrimary)
                Text(L.t("配置和查看本部署已安装的插件", "Configure and review the plugins installed in this deployment"))
                    .font(.system(size: 14))
                    .foregroundStyle(DSH.labelTertiary)
            }
            .padding(28)

            // 官方 tab 形态：13px 文字 + 2px 选中蓝条
            HStack(spacing: 36) {
                tabButton("configurable", label: L.t("插件配置", "Configurable"))
                tabButton("all", label: L.t("插件列表", "All plugins"))
                Spacer()
            }
            .padding(.horizontal, 28)
            .overlay(alignment: .bottom) { Rectangle().fill(DSH.borderL2).frame(height: 1) }

            Divider().hidden()

            Group {
                switch tab {
                case "all": PluginInventoryTab()
                default: ConfigurablePluginsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tabButton(_ id: String, label: String) -> some View {
        Button {
            tab = id
        } label: {
            VStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 13, weight: tab == id ? .medium : .regular))
                    .foregroundStyle(tab == id ? DSH.businessPrimary : DSH.labelTertiary)
                Rectangle()
                    .fill(tab == id ? DSH.businessPrimary : Color.clear)
                    .frame(height: 2)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private var spacing: CGFloat { 4 }
}

// MARK: Tab 1：插件配置（官方 3 张 staged 编辑卡）

struct ConfigurablePluginsTab: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PluginConfigCard(ns: "shell", title: L.t("Bash", "Bash"), fields: [
                    .number(L.t("超时（毫秒）", "Timeout (ms)"), "timeoutMs"),
                    .number(L.t("最大输出（字节）", "Max output (bytes)"), "maxOutputBytes"),
                ])
                PluginConfigCard(ns: "agent-loop", title: L.t("Agent 循环", "Agent loop"), fields: [
                    .number(L.t("最大并行工具调用", "Max parallel tool calls"), "maxParallelToolCalls"),
                ])
                PluginConfigCard(ns: "web-search-deepseek", title: L.t("网页搜索（DeepSeek）", "Web search (DeepSeek)"), fields: [
                    .text("Base URL", "baseURL"),
                    .number(L.t("每次会话最大使用次数", "Max uses per session"), "maxUses"),
                ], secret: .init(refDefault: "DEEPSEEK_API_KEY", label: L.t("API Key", "API key")))
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PluginFieldSpec {
    enum Kind { case number, text }
    var kind: Kind
    let label: String
    let key: String
    static func number(_ label: String, _ key: String) -> PluginFieldSpec { PluginFieldSpec(kind: .number, label: label, key: key) }
    static func text(_ label: String, _ key: String) -> PluginFieldSpec { PluginFieldSpec(kind: .text, label: label, key: key) }
}

struct PluginSecretSpec {
    let refDefault: String
    let label: String
}

/// 官方 PluginCard：折叠头（名称/描述/unsaved 徽章）+ staged 表单 + 逐字段"已覆盖"徽章与恢复默认
struct PluginConfigCard: View {
    @EnvironmentObject private var app: AppState
    let ns: String
    let title: String
    let fields: [PluginFieldSpec]
    var secret: PluginSecretSpec? = nil

    @State private var expanded = false
    @State private var available = true
    @State private var readOnly = true
    @State private var revision = 0
    @State private var defaults: [String: JSONValue] = [:]
    @State private var drafts: [String: String] = [:]
    @State private var overridden: Set<String> = []
    @State private var secretDraft = ""
    @State private var secretConfigured = false
    @State private var secretRef = ""
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        if available {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(DSH.labelPrimary)
                                if !drafts.isEmpty || !secretDraft.isEmpty {
                                    Text(L.t("未保存", "Unsaved"))
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color(nsColor: .systemOrange))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(Color(nsColor: .systemOrange).opacity(0.12)))
                                }
                            }
                            Text(ns)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DSH.labelTertiary)
                        }
                        Spacer()
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(DSH.labelTertiary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 12) {
                        if let s = secret {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(s.label).font(.system(size: 12, weight: .medium)).foregroundStyle(DSH.labelSecondary)
                                    if secretConfigured {
                                        Text(L.t("已配置", "Configured"))
                                            .font(.system(size: 10)).foregroundStyle(DSH.successPrimary)
                                    }
                                }
                                SecureField(secretConfigured ? L.t("已配置——输入新值可替换", "Configured — enter new value to replace") : L.t("输入密钥", "Enter key"), text: $secretDraft)
                                    .font(.system(size: 13, design: .monospaced))
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(readOnly)
                            }
                        }
                        ForEach(fields, id: \.key) { field in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(field.label).font(.system(size: 12, weight: .medium)).foregroundStyle(DSH.labelSecondary)
                                    if overridden.contains(field.key) {
                                        Text(L.t("已覆盖", "Overridden"))
                                            .font(.system(size: 10))
                                            .foregroundStyle(DSH.labelTertiary)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(RoundedRectangle(cornerRadius: 3).strokeBorder(DSH.borderL2, lineWidth: 1))
                                        Button(L.t("恢复默认", "Reset")) {
                                            drafts[field.key] = ""
                                            overridden.remove(field.key)
                                        }
                                        .buttonStyle(.borderless)
                                        .controlSize(.mini)
                                    }
                                }
                                TextField(displayDefault(field.key), text: binding(field.key))
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(readOnly)
                            }
                        }
                        if readOnly {
                            Text(L.t("当前部署的设置为只读", "Settings are read-only for this deployment"))
                                .font(.system(size: 12)).foregroundStyle(DSH.labelTertiary)
                        }
                        if let f = failure {
                            Text(f).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
                        }
                        HStack {
                            Spacer()
                            Button(L.t("放弃修改", "Discard")) {
                                drafts.removeAll()
                                secretDraft = ""
                                failure = nil
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(DSH.labelSecondary)
                            .padding(.horizontal, 12).frame(height: 30)
                            .disabled(saving || (drafts.isEmpty && secretDraft.isEmpty))
                            Button {
                                Task { await save() }
                            } label: {
                                if saving { ProgressView().controlSize(.mini) }
                                else { Text(L.t("保存", "Save")) }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(Capsule().fill(canSave ? DSH.businessPrimary : DSH.labelCaption))
                            .disabled(!canSave || saving)
                        }
                    }
                    .padding(14)
                    .overlay(alignment: .top) { Rectangle().fill(DSH.borderL1).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(DSH.borderL2, lineWidth: 1))
            .task { await load() }
        }
    }

    private var canSave: Bool { !readOnly && (!drafts.isEmpty || !secretDraft.isEmpty) }

    private func displayDefault(_ key: String) -> String {
        if let d = defaults[key] {
            return d.stringValue ?? (d.doubleValue.map { String($0) } ?? "")
        }
        return ""
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })
    }

    private func load() async {
        guard let snap = try? await app.settingsDescribe() else { return }
        guard let view = snap.namespaces[ns] else {
            available = false // 官方：namespace 未服务 → 整卡不渲染
            return
        }
        readOnly = !snap.writable
        revision = snap.revisions[ns] ?? 0
        // 默认值（value 合成值）与 user 层覆盖
        if case .object(let value)? = view["value"] {
            for f in fields where value[f.key] != nil {
                defaults[f.key] = value[f.key]
                drafts[f.key] = value[f.key]?.stringValue ?? (value[f.key]?.doubleValue.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "")
            }
        }
        overridden = []
        if case .object(let user)? = view["user"] {
            for f in fields where user[f.key] != nil {
                overridden.insert(f.key)
            }
        }
        // secret
        if let s = secret {
            let ref = (view["value"]?["apiKeyEnv"]?.stringValue) ?? s.refDefault
            secretRef = ref
            if let states = try? await app.credentialsState(refs: [ref]), let ok = states[ref] {
                secretConfigured = ok
            }
        }
    }

    private func save() async {
        saving = true
        failure = nil
        defer { saving = false }
        do {
            // 官方：逐字段写（staged），"恢复默认" = unset；secret 单独走 credentials
            var ops: [SettingsDiff.Op] = []
            for (key, raw) in drafts {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if overridden.contains(key), trimmed.isEmpty, defaults[key] == nil || trimmed.isEmpty {
                    // 视为恢复默认：user 层 unset（除非原本默认存在但被清空——简化：空即 unset）
                    if overridden.contains(key) {
                        ops.append(SettingsDiff.Op(op: "unset", path: [key], value: nil))
                    }
                    continue
                }
                let value: JSONValue
                if fields.first(where: { $0.key == key })?.kind == .number {
                    guard let n = Double(trimmed) else { continue }
                    value = .number(n)
                } else {
                    value = .string(trimmed)
                }
                ops.append(SettingsDiff.Op(op: "set", path: [key], value: value))
            }
            if !ops.isEmpty {
                _ = try await app.settingsMutate(ns: ns, ops: ops, expectedRevision: revision)
            }
            let keyTrimmed = secretDraft.trimmingCharacters(in: .whitespaces)
            if !keyTrimmed.isEmpty, !secretRef.isEmpty {
                try await app.setCredential(ref: secretRef, value: keyTrimmed)
                secretDraft = ""
            }
            drafts.removeAll()
            await load() // 官方：保存后回读，host 校验为唯一权威
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: Tab 2：插件列表（官方 PluginInventorySettingsTab：搜索 + 折叠卡 + fiber 状态点）

struct PluginInventoryTab: View {
    @EnvironmentObject private var app: AppState
    @State private var entries: [AppState.PluginEntry] = []
    @State private var status = "loading"
    @State private var query = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField(L.t("搜索插件…", "Search plugins…"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Text("\(filtered.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(DSH.labelTertiary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(DSH.hoverBgSolid))
                }
                switch status {
                case "loading":
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L.t("加载中…", "Loading…")).font(.system(size: 13)).foregroundStyle(DSH.labelTertiary)
                    }.padding(.top, 30).frame(maxWidth: .infinity)
                case "error":
                    Button(L.t("重试", "Retry")) { Task { await load() } }
                        .buttonStyle(.borderless).padding(.top, 30)
                default:
                    if filtered.isEmpty {
                        Text(query.isEmpty ? L.t("无插件", "No plugins") : L.t("无匹配结果", "No matches"))
                            .font(.system(size: 13)).foregroundStyle(DSH.labelTertiary)
                            .padding(.top, 30).frame(maxWidth: .infinity)
                    } else {
                        ForEach(filtered) { entry in
                            pluginCard(entry)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
    }

    private var filtered: [AppState.PluginEntry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.moduleName.lowercased().contains(q) || $0.entryId.lowercased().contains(q) }
    }

    private func phaseColor(_ phase: String?) -> Color {
        switch phase {
        case "active": return DSH.successPrimary
        case "loading", "unloading", "pending": return Color(nsColor: .systemOrange)
        case "failed": return DSH.errorPrimary
        default: return DSH.labelCaption
        }
    }

    private func phaseText(_ phase: String?) -> String {
        switch phase {
        case "active": return L.t("已挂载", "Active")
        case "loading": return L.t("加载中", "Loading")
        case "pending": return L.t("等待依赖", "Pending")
        case "failed": return L.t("挂载失败", "Failed")
        case "unloading": return L.t("卸载中", "Unloading")
        default: return L.t("未挂载", "Not mounted")
        }
    }

    /// 官方短名规则：去 scope、cordis:、cordis-plugin-、dsh-(host-|client-) 前缀
    private func shortName(_ module: String) -> String {
        var name = module
        if let idx = module.firstIndex(of: "/"), module.hasPrefix("@") {
            name = String(module[module.index(after: idx)...])
        }
        for prefix in ["cordis:", "cordis-plugin-", "dsh-host-", "dsh-client-", "dsh-"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return name
    }

    private func pluginCard(_ entry: AppState.PluginEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            } label: {
                HStack(spacing: 10) {
                    Circle().fill(entry.enabled ? phaseColor(entry.fiberPhase) : DSH.labelCaption)
                        .frame(width: 7, height: 7)
                    Text(shortName(entry.moduleName))
                        .font(.system(size: 13))
                        .foregroundStyle(DSH.labelPrimary)
                        .lineLimit(1)
                    Text(entry.enabled ? L.t("已启用", "Enabled") : L.t("已停用", "Disabled"))
                        .font(.system(size: 10))
                        .foregroundStyle(entry.enabled ? DSH.labelSecondary : DSH.labelTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).strokeBorder(DSH.borderL2, lineWidth: 1))
                    Spacer()
                    Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(DSH.labelTertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.contains(entry.id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.entryId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DSH.labelTertiary)
                        .textSelection(.enabled)
                    HStack(spacing: 16) {
                        Label(L.t("配置", "Config") + "：—", systemImage: "slider.horizontal.3")
                        Label(phaseText(entry.fiberPhase), systemImage: "bolt.horizontal")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(DSH.labelSecondary)
                }
                .padding(14)
                .overlay(alignment: .top) { Rectangle().fill(DSH.borderL1).frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(DSH.borderL1, lineWidth: 1))
    }

    private func load() async {
        status = "loading"
        do {
            entries = try await app.pluginInventory()
            status = "ready"
        } catch {
            status = "error"
        }
    }
}
