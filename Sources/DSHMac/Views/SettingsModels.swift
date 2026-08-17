import SwiftUI
import AppKit

// MARK: - 模型分区（官方 ModelsSection 完整复刻）
// 行卡 join / ProviderEditor（deepseek·pi-ai·unknown 三布局）/ 模型目录编辑 /
// discoverModels 拉取候选 / 添加已有 + 自定义 provider / 删除（凭据连带）/ setup 首跑姿态

struct ModelsSettingsSection: View {
    @EnvironmentObject private var app: AppState

    @State private var status: Status = .idle
    @State private var rows: [SettingsProviderRow] = []
    @State private var snapshot = AppState.SettingsSnapshot()
    @State private var errorText: String?
    @State private var editing: SettingsProviderRow?
    @State private var declaring = false
    @State private var deleteTarget: SettingsProviderRow?
    @State private var savedTarget: String?
    @State private var dismissedSetup: Set<String> = []

    enum Status { case idle, loading, ready, error }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                switch status {
                case .idle, .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L.t("加载中…", "Loading…")).font(.system(size: 13)).foregroundStyle(DSH.labelTertiary)
                    }
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity)
                case .error:
                    VStack(spacing: 10) {
                        Text(errorText ?? L.t("加载失败", "Failed to load"))
                            .font(.system(size: 13)).foregroundStyle(DSH.errorPrimary)
                        retryButton
                    }
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity)
                case .ready:
                    content
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if status == .idle { await load() } }
        .onChange(of: app.settingsVersion) { _, _ in
            Task { if status == .ready { await load() } } // 官方：事件失效已加载才刷
        }
        .sheet(item: $deleteTarget) { target in
            deleteDialog(target).frame(width: 480)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(L.t("模型", "Models"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DSH.labelPrimary)
                if status == .ready, let saved = savedTarget {
                    Label(L.t("已保存 \(saved)", "Saved \(saved)"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DSH.successPrimary)
                        .transition(.opacity)
                }
                Spacer()
            }
            Text(L.t("配置可用的模型服务与 API 密钥", "Configure model providers and API keys"))
                .font(.system(size: 14))
                .foregroundStyle(DSH.labelTertiary)
            if status == .ready && !snapshot.writable {
                Label(L.t("当前部署的设置为只读", "Settings are read-only for this deployment"), systemImage: "lock")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .systemOrange).opacity(0.1)))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let anyUsable = rows.contains(where: \.usable)
        VStack(alignment: .leading, spacing: 8) {
            // 已配置行（官方：configured 才渲染；首跑 setup 姿态替换整段型行）
            ForEach(rows.filter(\.configured)) { row in
                if !anyUsable, row.settingsPath.isEmpty, row.credentialConfigured != true, !dismissedSetup.contains(row.id) {
                    // setup 卡（首跑：直接展开编辑）
                    ProviderEditorCard(
                        row: row,
                        namespace: snapshot.namespaces[row.settingsNs],
                        setupMode: true,
                        onClose: { changed in
                            dismissedSetup.insert(row.id)
                            if changed { Task { await load() } }
                        }
                    )
                } else {
                    providerRowCard(row)
                }
            }

            // 行内编辑卡
            if let editing {
                ProviderEditorCard(
                    row: editing,
                    namespace: snapshot.namespaces[editing.settingsNs],
                    onClose: { changed in
                        self.editing = nil
                        if changed { Task { await load() } }
                    }
                )
            }

            // 自定义 provider 创建卡
            if declaring {
                CustomProviderCard(protocols: protocolChoices) {
                    declaring = false
                    Task { await load() }
                }
            }

            // 两个等宽添加入口（官方 44px 虚线卡）
            if !snapshot.writable || status == .ready {
                HStack(spacing: 10) {
                    let addable = rows.filter { !$0.configured && !$0.settingsNs.isEmpty }
                    addButton(title: L.t("添加提供方", "Add provider"), enabled: !addable.isEmpty && snapshot.writable) {
                        if let first = addable.first { editing = first }
                    }
                    addButton(title: L.t("添加自定义提供方", "Add a custom provider"), enabled: !protocolChoices.isEmpty && snapshot.writable) {
                        declaring = true
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var protocolChoices: [String] {
        guard let nsView = snapshot.namespaces["llm-pi-ai"], let schema = nsView["schema"] else { return [] }
        return SchemaMiner.protocolChoices(piAISchema: schema)
    }

    // ---- 行卡（官方 rowCard：描边 12px 圆角、状态点、Custom 徽标、行内按钮）----

    private func providerRowCard(_ row: SettingsProviderRow) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(row.usable ? DSH.successPrimary : DSH.errorPrimary)
                .frame(width: 8, height: 8)
                .help(row.usable ? L.t("可用", "Usable") : L.t("不可用", "Not usable"))
            Text(row.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSH.labelPrimary)
            if row.removable {
                Text(L.t("自定义", "Custom"))
                    .font(.system(size: 11))
                    .foregroundStyle(DSH.labelSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(DSH.borderL2, lineWidth: 1))
            }
            if row.active && row.usable {
                Text(L.t("使用中", "Active"))
                    .font(.system(size: 11))
                    .foregroundStyle(DSH.businessPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DSH.businessPrimary.opacity(0.12)))
            }
            Text(row.id)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DSH.labelTertiary)
            Spacer()
            HStack(spacing: 4) {
                Button(L.t("编辑", "Edit")) { editing = row }
                    .disabled(!snapshot.writable)
                if row.removable && snapshot.writable {
                    Button(L.t("删除", "Delete"), role: .destructive) { deleteTarget = row }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DSH.borderL2, lineWidth: 1)
        )
    }

    private func addButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 13))
                Text(title).font(.system(size: 13))
            }
            .foregroundStyle(enabled ? DSH.labelPrimary : DSH.labelTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(DSH.borderL2, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    // ---- 删除确认（官方：区分是否连带删除受管凭据）----

    private func deleteDialog(_ target: SettingsProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            @State var deleting = false
            @State var failure: String?
            Group {
                Text(L.t("删除 \(target.name)？", "Delete \(target.name)?"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DSH.labelPrimary)
                Text(target.managedCredentialRef != nil
                     ? L.t("配置和已存 API key 将一并删除。", "The configuration and stored API key will be deleted together.")
                     : L.t("配置将被删除；凭据在别处管理、保留。", "The configuration will be deleted; credentials are managed elsewhere and kept."))
                    .font(.system(size: 13))
                    .foregroundStyle(DSH.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let f = failure {
                    Text(f).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
                }
                HStack {
                    Spacer()
                    Button(L.t("取消", "Cancel")) { deleteTarget = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(DSH.labelSecondary)
                        .padding(.horizontal, 14).frame(height: 32)
                    Button {
                        deleting = true
                        Task {
                            do {
                                // 官方顺序：先删凭据（如有受管），再 unset profile；两步幂等
                                if let ref = target.managedCredentialRef {
                                    try await app.unsetCredential(ref: ref)
                                }
                                try await app.settingsMutate(
                                    ns: target.settingsNs,
                                    ops: [SettingsDiff.Op(op: "unset", path: target.settingsPath, value: nil)],
                                    expectedRevision: nil
                                )
                                deleteTarget = nil
                                await load()
                            } catch {
                                deleting = false
                                failure = error.localizedDescription
                            }
                        }
                    } label: {
                        Text(deleting ? L.t("删除中…", "Deleting…") : L.t("删除", "Delete"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DSH.errorPrimary)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(Capsule().strokeBorder(DSH.errorPrimary, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(deleting)
                }
            }
        }
        .padding(20)
        .interactiveDismissDisabled()
    }

    private var retryButton: some View {
        Button(L.t("重试", "Retry")) {
            Task { await load() }
        }
        .buttonStyle(.borderless)
    }

    // ---- 数据 ----

    private func load() async {
        status = .loading
        defer { status = .ready }
        do {
            let (r, s) = try await app.loadProviderRows()
            rows = r
            snapshot = s
            errorText = nil
        } catch {
            status = .error
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Provider 编辑卡（官方 ProviderEditor：deepseek / pi-ai / unknown 三布局）

struct ProviderEditorCard: View {
    @EnvironmentObject private var app: AppState
    let row: SettingsProviderRow
    let namespace: JSONValue?      // 完整 ns view（schema/value/base/user/revision）
    var setupMode = false
    let onClose: (Bool) -> Void    // changed

    // 布局
    private var layout: String {
        switch row.settingsNs {
        case "llm-deepseek": return "deepseek"
        case "llm-pi-ai": return "pi-ai"
        default: return "unknown"
        }
    }

    // 草稿
    @State private var keyValue = ""
    @State private var baseURL = ""
    @State private var displayNameDraft = ""
    @State private var apiChoice = ""
    @State private var models: [[String: String]] = []   // 每行 id/name/contextWindow/maxTokens（字符串缓冲）
    @State private var modelsOverridden = false
    @State private var expandedCustom = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var initialized = false

    // 提交基线（官方 committedOriginal：user 层 profile；settings 成功后推进）
    @State private var revision = 0
    @State private var committed: [String: JSONValue] = [:]
    @State private var inheritedModels: [JSONValue] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(setupMode
                     ? L.t("配置 \(row.name)", "Set up \(row.name)")
                     : L.t("编辑 \(row.name)", "Edit \(row.name)"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSH.labelPrimary)
                Spacer()
            }

            if layout == "unknown" {
                Text(L.t("其余字段在 settings.yaml 中，请直接编辑对应段（\(row.settingsNs)）。", "Remaining fields live in settings.yaml; edit the \(row.settingsNs) section directly."))
                    .font(.system(size: 13))
                    .foregroundStyle(DSH.labelTertiary)
                footer(disabledApply: true)
            } else {
                editorBody
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(DSH.hoverBgSolid.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DSH.borderL2, lineWidth: 1))
        .task { initialize() }
    }

    @ViewBuilder
    private var editorBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            // API key（write-only；三态 placeholder）
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("API Key", "API Key"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(DSH.labelSecondary)
                SecureField(keyPlaceholder, text: $keyValue)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .disabled(keyDisabled)
                if let failure = keyFailure {
                    Text(failure).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
                }
            }

            // 折叠自定义设置
            DisclosureGroup(isExpanded: $expandedCustom) {
                VStack(alignment: .leading, spacing: 12) {
                    if layout == "pi-ai" && row.declared {
                        field(L.t("显示名称", "Display name")) {
                            TextField(displayNamePlaceholder, text: $displayNameDraft)
                                .textFieldStyle(.roundedBorder)
                        }
                        field(L.t("API 协议", "API protocol")) {
                            Picker("", selection: $apiChoice) {
                                Text(L.t("未选择", "Not selected")).tag("")
                                ForEach(protocolChoices, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 240)
                        }
                    }
                    field("Base URL") {
                        TextField(baseURLPlaceholder, text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }
                .padding(.top, 10)
            } label: {
                Text(L.t("自定义设置", "Custom settings"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(DSH.labelSecondary)
            }

            // 模型目录
            ModelCatalogEditor(
                models: $models,
                overridden: $modelsOverridden,
                inherited: inheritedModels,
                allowFetch: layout == "pi-ai",
                fetchAction: fetchCandidates
            )

            if let e = errorText {
                Text(e).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
            }

            footer(disabledApply: !canApply)
        }
        .sheet(isPresented: $showCandidates) { candidatesSheet }
    }

    private func footer(disabledApply: Bool) -> some View {
        HStack {
            Spacer()
            Button(L.t("取消", "Cancel")) { onClose(false) }
                .buttonStyle(.plain)
                .foregroundStyle(DSH.labelSecondary)
                .padding(.horizontal, 14).frame(height: 32)
                .disabled(busy)
            Button {
                Task { await apply() }
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini) }
                    Text(busy ? L.t("保存中…", "Applying…") : L.t("保存", "Apply"))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 32)
                .background(Capsule().fill(disabledApply || busy ? DSH.labelCaption : DSH.businessPrimary))
            }
            .buttonStyle(.plain)
            .disabled(disabledApply || busy)
        }
    }

    // ---- 初始化（对齐官方：draft 来自 value 显示层，基线来自 user 层）----

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        revision = namespace?["revision"]?.intValue ?? 0
        let value = JSONPath.get(namespace?["value"], path: row.settingsPath) ?? .object([:])
        let user = JSONPath.get(namespace?["user"], path: row.settingsPath) ?? .object([:])
        var committedDict: [String: JSONValue] = [:]
        if case .object(let o) = user { committedDict = o }
        committed = committedDict

        baseURL = value["baseURL"]?.stringValue ?? ""
        displayNameDraft = value["displayName"]?.stringValue ?? ""
        apiChoice = value["api"]?.stringValue ?? ""
        // 模型：优先 user 覆盖，否则继承 base/schema 默认
        if case .object(let vo) = value, let m = vo["models"], m.isArray {
            modelsOverridden = JSONPath.has(user, path: row.settingsPath + ["models"])
            if modelsOverridden, case .array(let arr) = m {
                models = arr.map { entry in
                    [
                        "id": entry["id"]?.stringValue ?? "",
                        "name": entry["name"]?.stringValue ?? "",
                        "contextWindow": formatCapacity(entry["contextWindow"]?.doubleValue),
                        "maxTokens": formatCapacity(entry["maxTokens"]?.doubleValue),
                    ]
                }
            } else {
                loadInherited(models: m)
            }
        }
    }

    @State private var inheritedLoaded: [[String: JSONValue]] = []
    private func loadInherited(models json: JSONValue) {
        inheritedModels = json.arrayElements
    }

    // ---- 保存（官方顺序：settings.mutate（diff ops）→ credentials.set）----

    private func apply() async {
        busy = true
        defer { busy = false }
        do {
            var after: [String: JSONValue] = committed
            // baseURL / displayName / api
            let trimmedBase = baseURL.trimmingCharacters(in: .whitespaces)
            if trimmedBase.isEmpty {
                after["baseURL"] = nil
            } else {
                after["baseURL"] = .string(trimmedBase)
            }
            if layout == "pi-ai" && row.declared {
                let name = displayNameDraft.trimmingCharacters(in: .whitespaces)
                if name.isEmpty { after["displayName"] = nil } else { after["displayName"] = .string(name) }
                let api = apiChoice
                if api.isEmpty { after["api"] = nil } else { after["api"] = .string(api) }
            }
            // 模型目录
            if modelsOverridden {
                var list: [JSONValue] = []
                for m in models where !(m["id"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    var entry: [String: JSONValue] = ["id": .string(m["id"]!.trimmingCharacters(in: .whitespaces))]
                    if let n = m["name"], !n.isEmpty { entry["name"] = .string(n) }
                    if let c = m["contextWindow"], let v = parseCapacity(c) { entry["contextWindow"] = .number(v) }
                    if let x = m["maxTokens"], let v = parseCapacity(x) { entry["maxTokens"] = .number(v) }
                    list.append(.object(entry))
                }
                after["models"] = .array(list)
            } else {
                after["models"] = nil
            }

            let ops = SettingsDiff.pathOps(base: [:], before: committed, after: after, prefix: row.settingsPath)
            // pi-ai 特例：即将存 key 且 profile 未命名 apiKeyEnv → 派生 ref 写入
            var finalOps = ops
            let keyTrimmed = keyValue.trimmingCharacters(in: .whitespaces)
            let keyRef = row.apiKeyEnv ?? (layout == "pi-ai" ? deriveKeyRef(row.id) : nil)
            if keyTrimmed.count > 0, layout == "pi-ai", row.apiKeyEnv == nil,
               after["apiKeyEnv"] == nil, committed["apiKeyEnv"] == nil, let ref = keyRef {
                finalOps.append(SettingsDiff.Op(op: "set", path: row.settingsPath + ["apiKeyEnv"], value: .string(ref)))
            }
            // 整段型且完全空（官方 materializesNativeProfile 特例）
            if finalOps.isEmpty && row.settingsPath.isEmpty {
                finalOps = [SettingsDiff.Op(op: "set", path: row.settingsPath, value: .object([:]))]
            }

            if !finalOps.isEmpty {
                let newView = try await app.settingsMutate(ns: row.settingsNs, ops: finalOps, expectedRevision: revision)
                revision = newView["revision"]?.intValue ?? revision
                if case .object(let newUser)? = JSONPath.get(newView["user"], path: row.settingsPath) {
                    committed = newUser
                }
            }
            if keyTrimmed.count > 0, let ref = keyRef {
                try await app.setCredential(ref: ref, value: keyTrimmed)
                keyValue = ""
            }
            onClose(true)
        } catch {
            errorText = error.localizedDescription.contains("settings-conflict")
                ? L.t("设置已被其他窗口修改，请关闭后重试", "Settings were changed elsewhere; close and retry")
                : error.localizedDescription
        }
    }

    // ---- fetch 候选（官方 discoverModels：以表单当前值探测）----

    @State private var candidates: [String] = []
    @State private var showCandidates = false
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var selectedCandidates: Set<String> = []

    private func fetchCandidates() async {
        fetching = true
        fetchError = nil
        defer { fetching = false }
        let keyTrimmed = keyValue.trimmingCharacters(in: .whitespaces)
        do {
            let ids = try await app.discoverModels(
                settingsNs: row.settingsNs,
                provider: row.id,
                baseURL: baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? nil : baseURL.trimmingCharacters(in: .whitespaces),
                api: apiChoice.isEmpty ? nil : apiChoice,
                apiKey: keyTrimmed.isEmpty ? nil : keyTrimmed
            )
            if ids.isEmpty {
                fetchError = L.t("未返回可用模型", "No models returned")
                return
            }
            candidates = ids
            let existing = Set(models.compactMap { $0["id"] })
            selectedCandidates = Set(ids.filter { !existing.contains($0) }) // 已存在不默认勾选
            showCandidates = true
        } catch {
            fetchError = error.localizedDescription
        }
    }

    // ---- 校验 ----

    private var keyPlaceholder: String {
        if row.credentialWritable == false && row.apiKeyEnv != nil && row.credentialConfigured {
            return L.t("由启动环境提供（只读）", "Provided by launch environment (read-only)")
        }
        if row.credentialConfigured {
            return L.t("已配置——输入新值可替换", "Configured — enter a new value to replace")
        }
        return layout == "pi-ai"
            ? L.t("输入 API 密钥，或留空使用环境认证", "Enter an API key, or leave empty to use environment auth")
            : L.t("输入 API 密钥", "Enter an API key")
    }

    private var keyDisabled: Bool { !snapshotWritable || (row.apiKeyEnv != nil && row.credentialWritable == false && row.credentialConfigured) }
    private var snapshotWritable: Bool { app.settingsWritableCache }

    private var keyFailure: String? {
        let trimmed = keyValue.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty && !keyValue.isEmpty { return L.t("密钥不能仅含空白", "Key cannot be whitespace-only") }
        if keyValue.contains("=") && keyValue.range(of: #"^[A-Z][A-Z0-9_]*="#, options: .regularExpression) != nil {
            return L.t("检测到 NAME=value 形式，请只粘贴密钥本身", "Detected NAME=value; paste the key itself")
        }
        return nil
    }

    private var canApply: Bool {
        keyFailure == nil && modelFailure == nil
    }

    private var modelFailure: String? {
        var seen = Set<String>()
        for (i, m) in models.enumerated() {
            let id = (m["id"] ?? "").trimmingCharacters(in: .whitespaces)
            if !modelsOverridden && models.isEmpty { return nil }
            if id.isEmpty { return L.t("模型 \(i + 1)：缺少 ID", "Model \(i + 1): missing ID") }
            if seen.contains(id) { return L.t("模型 \(i + 1)：ID 重复", "Model \(i + 1): duplicate ID") }
            seen.insert(id)
            if let c = m["contextWindow"], !c.isEmpty, parseCapacity(c) == nil {
                return L.t("模型 \(i + 1)：上下文窗口无效", "Model \(i + 1): invalid context window")
            }
            if let x = m["maxTokens"], !x.isEmpty, parseCapacity(x) == nil {
                return L.t("模型 \(i + 1)：maxTokens 无效", "Model \(i + 1): invalid maxTokens")
            }
        }
        return nil
    }

    private var protocolChoices: [String] {
        guard let piSchema = namespace?["schema"], row.settingsNs == "llm-pi-ai" else {
            // pi-ai 编辑卡的协议选项也要从 llm-pi-ai ns 拿：经 app 缓存
            return app.piAIProtocolChoices
        }
        return SchemaMiner.protocolChoices(piAISchema: piSchema)
    }

    private var displayNamePlaceholder: String {
        row.name.isEmpty ? row.id : row.name
    }

    private var baseURLPlaceholder: String {
        layout == "deepseek" ? "https://api.deepseek.com" : L.t("提供方默认", "Provider default")
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(DSH.labelSecondary)
            content()
        }
    }

    // 候选模态（在编辑卡内层弹）
    private var candidatesSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("选择要添加的模型", "Choose models to add"))
                .font(.system(size: 14, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates, id: \.self) { id in
                        Toggle(isOn: Binding(
                            get: { selectedCandidates.contains(id) },
                            set: { on in
                                if on { selectedCandidates.insert(id) } else { selectedCandidates.remove(id) }
                            }
                        )) {
                            Text(id).font(.system(size: 13, design: .monospaced))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button(L.t("添加所选", "Add selected")) {
                    let existing = Set(models.compactMap { $0["id"] })
                    for id in candidates where selectedCandidates.contains(id) && !existing.contains(id) {
                        models.append(["id": id])
                    }
                    modelsOverridden = true
                    showCandidates = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 30)
                .background(Capsule().fill(DSH.businessPrimary))
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - 模型目录编辑器（官方 ModelListEditor / DeepSeekModelsEditor）

struct ModelCatalogEditor: View {
    @Binding var models: [[String: String]]
    @Binding var overridden: Bool
    let inherited: [JSONValue]
    var allowFetch = false
    var fetchAction: (() async -> Void)? = nil

    @State private var expandedRows: Set<Int> = []
    @State private var fetching = false
    @State private var fetchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.t("模型目录", "Models"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DSH.labelPrimary)
                Text(overridden ? L.t("已自定义模型目录", "Customized") : L.t("正在使用适配器默认模型", "Using adapter defaults"))
                    .font(.system(size: 11))
                    .foregroundStyle(DSH.labelTertiary)
                Spacer()
                if allowFetch, let fetchAction {
                    Button {
                        Task {
                            fetching = true
                            await fetchAction()
                            fetching = false
                        }
                    } label: {
                        if fetching {
                            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(L.t("正在询问提供方…", "Asking the provider…")) }
                        } else {
                            Text(L.t("获取可用模型", "Fetch available models"))
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(fetching)
                }
                if overridden {
                    Button(L.t("恢复默认值", "Restore defaults")) {
                        models = []
                        overridden = false
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            if let e = fetchError {
                Text(e).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
            }

            if overridden {
                VStack(spacing: 8) {
                    ForEach(Array(models.enumerated()), id: \.offset) { index, _ in
                        modelRow(index)
                    }
                }
                Button {
                    models.append(["id": ""])
                } label: {
                    Label(L.t("添加模型", "Add model"), systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                if models.isEmpty {
                    Text(L.t("模型选择器中将不显示任何模型；目录外 ID 仍可直接发送。", "No models will appear in the picker; IDs outside the list can still be sent."))
                        .font(.system(size: 12))
                        .foregroundStyle(DSH.labelTertiary)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(DSH.borderL2, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                }
            } else {
                // 继承展示（只读）
                VStack(spacing: 6) {
                    ForEach(Array(inherited.prefix(12).enumerated()), id: \.offset) { _, m in
                        HStack {
                            Text(m["name"]?.stringValue ?? m["id"]?.stringValue ?? "?")
                                .font(.system(size: 13))
                                .foregroundStyle(DSH.labelSecondary)
                            Spacer()
                            Text(m["id"]?.stringValue ?? "")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DSH.labelTertiary)
                        }
                    }
                    if inherited.count > 12 {
                        Text(L.t("… 共 \(inherited.count) 个", "… \(inherited.count) total"))
                            .font(.system(size: 11)).foregroundStyle(DSH.labelTertiary)
                    }
                    if inherited.isEmpty {
                        Text(L.t("（适配器默认目录未披露）", "(Adapter defaults not disclosed)"))
                            .font(.system(size: 12)).foregroundStyle(DSH.labelTertiary)
                    }
                }
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(DSH.borderL1).frame(height: 1) }
    }

    private func modelRow(_ index: Int) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField(L.t("模型 ID", "Model ID"), text: binding(index, "id"))
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                TextField(L.t("显示名称", "Display name"), text: binding(index, "name"))
                    .textFieldStyle(.roundedBorder)
                Button {
                    if expandedRows.contains(index) { expandedRows.remove(index) } else { expandedRows.insert(index) }
                } label: {
                    Image(systemName: expandedRows.contains(index) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                Button {
                    models.remove(at: index)
                    expandedRows.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(DSH.errorPrimary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            if expandedRows.contains(index) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.t("上下文窗口", "Context window")).font(.system(size: 11)).foregroundStyle(DSH.labelTertiary)
                        TextField("256K", text: binding(index, "contextWindow")).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Max tokens").font(.system(size: 11)).foregroundStyle(DSH.labelTertiary)
                        TextField("32K", text: binding(index, "maxTokens")).textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(DSH.borderL2, lineWidth: 1))
    }

    private func binding(_ index: Int, _ key: String) -> Binding<String> {
        Binding(
            get: { models.indices.contains(index) ? (models[index][key] ?? "") : "" },
            set: { if models.indices.contains(index) { models[index][key] = $0 } }
        )
    }
}

// MARK: - 自定义 provider 创建卡（官方 CustomProviderCard）

struct CustomProviderCard: View {
    @EnvironmentObject private var app: AppState
    let protocols: [String]
    let onClose: () -> Void

    @State private var route = ""
    @State private var displayName = ""
    @State private var baseURLText = ""
    @State private var protocolChoice = ""
    @State private var keyValue = ""
    @State private var models: [[String: String]] = []
    @State private var busy = false
    @State private var errorText: String?
    @State private var committed = false
    @State private var routeError: String?
    @State private var taken: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("添加自定义提供方", "Add a custom provider"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSH.labelPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("Provider ID", "Provider ID")).font(.system(size: 12, weight: .medium)).foregroundStyle(DSH.labelSecondary)
                TextField("acme-gateway", text: $route)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                if let e = routeError {
                    Text(e).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
                } else {
                    Text(L.t("小写字母开头，可用小写字母、数字与连字符", "Starts with a letter; lowercase letters, digits, hyphens"))
                        .font(.system(size: 11)).foregroundStyle(DSH.labelTertiary)
                }
            }

            HStack(spacing: 12) {
                fieldColumn(L.t("显示名称", "Display name")) {
                    TextField(route.isEmpty ? "acme-gateway" : route, text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
                fieldColumn("Base URL") {
                    TextField("https://gateway.example/v1", text: $baseURLText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                }
                fieldColumn(L.t("API 协议", "API protocol")) {
                    Picker("", selection: $protocolChoice) {
                        ForEach(protocols, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("API Key", "API Key")).font(.system(size: 12, weight: .medium)).foregroundStyle(DSH.labelSecondary)
                SecureField(L.t("留空若该提供方以其他方式鉴权", "Leave empty if the provider authenticates otherwise"), text: $keyValue)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }

            ModelCatalogEditor(
                models: $models,
                overridden: .constant(true),
                inherited: [],
                allowFetch: true,
                fetchAction: fetchCandidates
            )

            if let e = errorText {
                Text(e).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
            }

            HStack {
                Spacer()
                Button(committed ? L.t("关闭", "Close") : L.t("取消", "Cancel")) { onClose() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DSH.labelSecondary)
                    .padding(.horizontal, 14).frame(height: 32)
                Button {
                    Task { await create() }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text(busy ? L.t("创建中…", "Creating…") : L.t("创建", "Create"))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(Capsule().fill(ready ? DSH.businessPrimary : DSH.labelCaption))
                }
                .buttonStyle(.plain)
                .disabled(!ready || (busy && committed))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(DSH.hoverBgSolid.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DSH.borderL2, lineWidth: 1))
        .onAppear {
            if protocols.isEmpty {
                protocolChoice = ""
            } else if protocolChoice.isEmpty {
                protocolChoice = protocols[0]
            }
            Task {
                if let (rows, _) = try? await app.loadProviderRows() {
                    taken = Set(rows.map(\.id))
                }
            }
        }
        .sheet(isPresented: $showCandidates) { candidatesSheet }
    }

    private func fieldColumn<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(DSH.labelSecondary)
            content()
        }
    }

    private var routeFailure: String? {
        if route.isEmpty { return nil }
        if route.range(of: #"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
            return L.t("格式无效", "Invalid format")
        }
        if taken.contains(route) { return L.t("已被占用", "Already taken") }
        return nil
    }

    private var ready: Bool {
        routeFailure == nil
            && !route.isEmpty
            && !baseURLText.trimmingCharacters(in: .whitespaces).isEmpty
            && !protocolChoice.isEmpty
            && models.contains { !($0["id"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // ---- 创建（官方：一次 mutate set 整个 profile；成功后锁死 profile 字段，重试只走 credentials）----

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let keyTrimmed = keyValue.trimmingCharacters(in: .whitespaces)
            let keyRef = deriveKeyRef(route)
            if !committed {
                var profile: [String: JSONValue] = [:]
                let name = displayName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { profile["displayName"] = .string(name) }
                if !keyTrimmed.isEmpty { profile["apiKeyEnv"] = .string(keyRef) }
                profile["api"] = .string(protocolChoice)
                profile["baseURL"] = .string(baseURLText.trimmingCharacters(in: .whitespaces))
                profile["models"] = .array(models.compactMap { m in
                    let id = (m["id"] ?? "").trimmingCharacters(in: .whitespaces)
                    guard !id.isEmpty else { return nil }
                    var entry: [String: JSONValue] = ["id": .string(id)]
                    if let n = m["name"], !n.isEmpty { entry["name"] = .string(n) }
                    return .object(entry)
                })
                let snap = try await app.settingsDescribe()
                _ = try await app.settingsMutate(
                    ns: "llm-pi-ai",
                    ops: [SettingsDiff.Op(op: "set", path: ["providers", route], value: .object(profile))],
                    expectedRevision: snap.revisions["llm-pi-ai"]
                )
                committed = true // profile 已存在；重试只走 credentials.set
            }
            if !keyTrimmed.isEmpty {
                try await app.setCredential(ref: keyRef, value: keyTrimmed)
            }
            onClose()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // ---- fetch ----

    @State private var candidates: [String] = []
    @State private var showCandidates = false
    @State private var selectedCandidates: Set<String> = []

    private func fetchCandidates() async {
        do {
            let ids = try await app.discoverModels(
                settingsNs: "llm-pi-ai",
                provider: nil,
                baseURL: baseURLText.isEmpty ? nil : baseURLText,
                api: protocolChoice.isEmpty ? nil : protocolChoice,
                apiKey: keyValue.isEmpty ? nil : keyValue
            )
            guard !ids.isEmpty else {
                errorText = L.t("未返回可用模型", "No models returned")
                return
            }
            candidates = ids
            let existing = Set(models.compactMap { $0["id"] })
            selectedCandidates = Set(ids.filter { !existing.contains($0) })
            showCandidates = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var candidatesSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("选择要添加的模型", "Choose models to add"))
                .font(.system(size: 14, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates, id: \.self) { id in
                        Toggle(isOn: Binding(
                            get: { selectedCandidates.contains(id) },
                            set: { on in
                                if on { selectedCandidates.insert(id) } else { selectedCandidates.remove(id) }
                            }
                        )) {
                            Text(id).font(.system(size: 13, design: .monospaced))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button(L.t("添加所选", "Add selected")) {
                    let existing = Set(models.compactMap { $0["id"] })
                    for id in candidates where selectedCandidates.contains(id) && !existing.contains(id) {
                        models.append(["id": id])
                    }
                    showCandidates = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 30)
                .background(Capsule().fill(DSH.businessPrimary))
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - 容量 K/M 解析（官方 parseCapacity/formatCapacity）

func parseCapacity(_ text: String) -> Double? {
    guard let match = text.range(of: #"^(\d+(?:\.\d+)?)([km])?$"#, options: .regularExpression) else {
        return text.isEmpty ? nil : Double(text)
    }
    let s = String(text[match])
    let numPart = s.dropLast(s.hasSuffix("k") || s.hasSuffix("m") ? 1 : 0)
    guard let n = Double(numPart) else { return nil }
    if s.hasSuffix("k") { return n * 1000 }
    if s.hasSuffix("m") { return n * 1_000_000 }
    return n
}

func formatCapacity(_ n: Double?) -> String {
    guard let n, n > 0 else { return "" }
    if n >= 1_000_000 && n.truncatingRemainder(dividingBy: 1_000_000) == 0 { return "\(Int(n / 1_000_000))M" }
    if n >= 1000 && n.truncatingRemainder(dividingBy: 1000) == 0 { return "\(Int(n / 1000))K" }
    return n == n.rounded() ? String(Int(n)) : String(n)
}
