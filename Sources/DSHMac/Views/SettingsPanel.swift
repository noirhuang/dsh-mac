import SwiftUI
import AppKit

// MARK: - 官方设置面板（SettingsRoot 复刻）：1080×700 居中模态 + 左导航 + 4 分区
// 分区（order）：通用设置(0) / 模型(10) / 插件(15) / Agent 预设(20)；侧栏底部"设置"触发。

struct SettingsPanel: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var updater: SourceUpdater
    @Environment(\.dismiss) private var dismiss
    @State private var section = "general"

    var body: some View {
        let _ = onChange(of: app.screenshotSettingsSection) { _, target in
            if let target { section = target }
        }
        HStack(spacing: 0) {
            // 左导航（官方 188px 导航轨）
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("设置", "Settings"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DSH.labelPrimary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                navRow("general", label: L.t("通用设置", "General"), symbol: "gearshape")
                navRow("models", label: L.t("模型", "Models"), symbol: "externaldrive.connected.to.line.below")
                navRow("plugins", label: L.t("插件", "Plugins"), symbol: "puzzlepiece")
                navRow("agent-presets", label: L.t("Agent 预设", "Agent presets"), symbol: "person.crop.rectangle.stack")
                Spacer()
            }
            .padding(12)
            .frame(width: 188)
            .background(DSH.sidebarFill)
            .overlay(alignment: .trailing) {
                Rectangle().fill(DSH.borderL1).frame(width: 1)
            }

            // 右内容列
            ZStack {
                DSH.bgBase
                switch section {
                case "models": ModelsSettingsSection()
                case "plugins": PluginsSettingsSection()
                case "agent-presets": AgentPresetsSection()
                default: GeneralSettingsSection()
                }
            }
        }
        .frame(width: 1080, height: 700)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DSH.labelSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.clear))
                    .contentShape(Circle())
            }
            .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBg, shape: AnyShape(Circle())))
            .padding(10)
            .keyboardShortcut(.escape)
        }
    }

    private func navRow(_ id: String, label: String, symbol: String) -> some View {
        Button {
            section = id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(section == id ? DSH.labelPrimary : DSH.labelSecondary)
                Text(label)
                    .font(.system(size: 14, weight: section == id ? .medium : .regular))
                    .foregroundStyle(section == id ? DSH.labelPrimary : DSH.labelSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(section == id ? DSH.hoverBg : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 通用分区（官方 5 行：Agent 预设(-25) → 权限(-20) → 语言(0) → 外观(10) → Enter 行为(20)）

struct GeneralSettingsSection: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var updater: SourceUpdater

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AgentPresetPreferenceRow()
                PermissionPreferenceRow()
                LanguagePreferenceRow()
                AppearancePreferenceRow()
                EnterBehaviorPreferenceRow()
                Rectangle().fill(Color.clear).frame(height: 8)
                updateGroup
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // 软件更新（原生分发特有，官方无此入口）
    private var updateGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(DSH.borderL1).frame(height: 1)
                .padding(.bottom, 10)
            Text(L.t("软件更新", "Software Update"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSH.labelPrimary)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("从源码更新", "Update from source"))
                        .font(.system(size: 14))
                        .foregroundStyle(DSH.labelPrimary)
                    Text(L.t("本地版本 \(updater.localSHA) · 拉取 GitHub master 并重新构建", "Local \(updater.localSHA) · pull GitHub master and rebuild"))
                        .font(.system(size: 12))
                        .foregroundStyle(DSH.labelTertiary)
                }
                Spacer()
                switch updater.phase {
                case .checking, .downloading, .installingDependencies, .building, .restarting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(updater.phaseDescription).font(.system(size: 13)).foregroundStyle(DSH.labelSecondary)
                    }
                case .upToDate:
                    Label(L.t("已是最新", "Up to date"), systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13)).foregroundStyle(DSH.successPrimary)
                case .done(let sha):
                    Label(L.t("已更新到 \(sha)", "Updated to \(sha)"), systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13)).foregroundStyle(DSH.successPrimary)
                case .failed(let reason):
                    VStack(alignment: .trailing) {
                        Label(L.t("更新失败", "Update failed"), systemImage: "xmark.octagon.fill")
                            .font(.system(size: 13)).foregroundStyle(DSH.errorPrimary)
                        Text(reason).font(.system(size: 12)).foregroundStyle(DSH.labelTertiary).lineLimit(2)
                    }
                case .idle:
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Text(L.t("检查更新", "Check for Updates"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 30)
                            .background(Capsule().fill(DSH.businessPrimary))
                    }
                    .buttonStyle(.plain)
                }
            }
            if !updater.logLines.isEmpty {
                ScrollView {
                    Text(updater.logLines.suffix(40).joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DSH.labelTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 120)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(DSH.codeBlockBg))
            }
        }
    }
}

// MARK: 官方设置行骨架（title + description + 右侧控件；16px 垂直 padding + hairline）

struct SettingsRow<Control: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14))
                        .foregroundStyle(DSH.labelPrimary)
                    if let d = description {
                        Text(d)
                            .font(.system(size: 12))
                            .foregroundStyle(DSH.labelTertiary)
                    }
                }
                Spacer(minLength: 16)
                control()
            }
            .padding(.vertical, 16)
            Rectangle().fill(DSH.borderL1).frame(height: 1)
        }
    }
}

/// 官方胶囊选择器（36px 高、radius 18、chevron 下拉）
struct PillMenu<Content: View>: View {
    let label: String
    @ViewBuilder var menu: () -> Content

    var body: some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: 12) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(DSH.labelPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DSH.labelTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(DSH.hoverBgSolid))
            .overlay(Capsule().strokeBorder(DSH.borderL2, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: 1) Agent 预设行（agentPreset.list + settings.update agent-presets.default）

struct AgentPresetPreferenceRow: View {
    @EnvironmentObject private var app: AppState
    @State private var presets: [AppState.AgentPresetEntry] = []
    @State private var current = ""
    @State private var writable = true
    @State private var errorText: String?

    var body: some View {
        if !presets.isEmpty {
            SettingsRow(
                title: L.t("Agent 预设", "Agent preset"),
                description: L.t("对此后新建的会话生效。运行中的会话保持它开始时的预设。",
                                 "Applies to sessions you start from now on. Running sessions keep the preset they began with.")
            ) {
                if let e = errorText {
                    Text(e).font(.system(size: 12)).foregroundStyle(DSH.errorPrimary)
                } else {
                    PillMenu(label: displayName(current)) {
                        ForEach(presets.filter { $0.broken == nil }) { p in
                            Button(displayName(p.id, trust: p.trust)) {
                                Task { await select(p.id) }
                            }
                        }
                    }
                    .disabled(!writable)
                }
            }
            .task { await load() }
        }
    }

    private func displayName(_ id: String, trust: String? = nil) -> String {
        let base: String
        switch id {
        case "standard": base = L.t("标准", "Standard")
        case "code": base = L.t("代码", "Code")
        case "minimal": base = L.t("极简", "Minimal")
        case "cordis": base = L.t("创造模式", "Cordis")
        default: base = presets.first(where: { $0.id == id })?.name ?? id
        }
        if trust == "user" || presets.first(where: { $0.id == id })?.trust == "user" {
            return base + " · " + L.t("自定义", "Custom")
        }
        return base
    }

    private func load() async {
        guard let (list, _) = try? await app.agentPresetList() else {
            errorText = L.t("预设加载失败", "Failed to load presets")
            return
        }
        presets = list
        current = list.first(where: \.isDefault)?.id ?? list.first?.id ?? ""
        if let snap = try? await app.settingsDescribe() { writable = snap.writable }
    }

    private func select(_ id: String) async {
        let old = current
        current = id
        do {
            let snap = try await app.settingsDescribe()
            _ = try await app.settingsUpdate(ns: "agent-presets", patch: ["default": .string(id)], expectedRevision: snap.revisions["agent-presets"])
            await load() // 官方：成功后重读 roster，以 host 解析为准
        } catch {
            current = old
            errorText = error.localizedDescription
        }
    }
}

// MARK: 2) 权限行（permission.defaultPreset + Full access 风险确认）

struct PermissionPreferenceRow: View {
    @EnvironmentObject private var app: AppState
    @State private var current = ""
    @State private var options: [(value: String, name: String)] = []
    @State private var writable = true
    @State private var revision = 0
    @State private var confirmFullAccess = false

    var body: some View {
        if !options.isEmpty {
            SettingsRow(
                title: L.t("权限", "Permission"),
                description: L.t("选择新会话的默认权限模式", "Choose the default permission mode for new sessions")
            ) {
                PillMenu(label: optionName(current)) {
                    ForEach(options, id: \.value) { opt in
                        Button(optionName(opt.value)) {
                            if opt.value == "danger-full-access" && opt.value != current {
                                confirmFullAccess = true
                            } else {
                                Task { await select(opt.value) }
                            }
                        }
                    }
                }
                .disabled(!writable)
            }
            .task { await load() }
            .sheet(isPresented: $confirmFullAccess) { fullAccessConfirm }
        }
    }

    private func optionName(_ v: String) -> String {
        if v == "danger-full-access" { return "Full access" }
        if let o = options.first(where: { $0.value == v }) { return o.name }
        return v.prefix(1).uppercased() + v.dropFirst().replacingOccurrences(of: "-", with: " ")
    }

    private var fullAccessConfirm: some View {
        FullAccessConfirmDialog {
            Task { await select("danger-full-access") }
        }
        .frame(width: 420)
    }

    private func load() async {
        guard let snap = try? await app.settingsDescribe(),
              let view = snap.namespaces["permission"] else { return }
        writable = snap.writable
        revision = snap.revisions["permission"] ?? 0
        current = view["value"]?["defaultPreset"]?.stringValue ?? "workspace-write"
        // 选项：schema 的 defaultPreset union consts（schemastery 挖掘）
        if let schema = view["schema"] {
            let (refs, root) = SchemaMiner.refsRoot(schema)
            if let root, let field = SchemaMiner.dictNode(root, key: "defaultPreset", refs: refs) {
                var opts: [(String, String)] = []
                for choice in SchemaMiner.unionStrings(field, refs: refs) {
                    let name = choice == "danger-full-access" ? "Full access"
                        : choice.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
                    opts.append((choice, name))
                }
                if !opts.isEmpty { options = opts }
            }
        }
        // 兜底官方预置枚举
        if options.isEmpty {
            options = [("read-only", "Read Only"), ("workspace-write", "Workspace Write"), ("danger-full-access", "Full access")]
        }
    }

    private func select(_ preset: String) async {
        let old = current
        current = preset
        do {
            _ = try await app.settingsMutate(
                ns: "permission",
                ops: [SettingsDiff.Op(op: "set", path: ["defaultPreset"], value: .string(preset))],
                expectedRevision: revision
            )
            await load()
        } catch {
            current = old
        }
    }
}

/// Full access 风险确认（官方 RiskConfirmation：勾选承认框才可确认）
struct FullAccessConfirmDialog: View {
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("确认启用 Full access？", "Enable Full access?"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DSH.labelPrimary)
            Text(L.t("Full access 会让新会话减少确认步骤并直接执行更多操作，包括敏感操作、文件修改或外部命令。仅在信任后续任务时使用。",
                     "Full access lets new sessions reduce confirmation steps and perform more actions directly, including sensitive operations, file changes, or external commands. Only use it when you trust subsequent tasks."))
                .font(.system(size: 13))
                .foregroundStyle(DSH.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L.t("我已了解风险，并愿意继续", "I understand the risks and want to continue"), isOn: $acknowledged)
                .font(.system(size: 13))
            HStack {
                Spacer()
                Button(L.t("取消", "Cancel")) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DSH.labelSecondary)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                Button {
                    dismiss()
                    onConfirm()
                } label: {
                    Text(L.t("启用 Full access", "Enable Full access"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(acknowledged ? DSH.errorPrimary : DSH.labelCaption))
                }
                .buttonStyle(.plain)
                .disabled(!acknowledged)
            }
        }
        .padding(20)
    }
}

// MARK: 3) 语言行（locale.preference）

struct LanguagePreferenceRow: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        SettingsRow(title: L.t("语言", "Language")) {
            PillMenu(label: app.appLanguage == "en" ? "English" : "中文") {
                Button("中文") { Task { await select("zh") } }
                Button("English") { Task { await select("en") } }
            }
        }
    }

    private func select(_ id: String) async {
        app.appLanguage = id // 官方：先本地生效再落盘
        try? await app.writePreference(ns: "locale", field: "preference", value: id)
    }
}

// MARK: 4) 外观行（ui-theme.preference；官方三张选择卡片）

struct AppearancePreferenceRow: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        SettingsRow(title: L.t("外观", "Appearance")) {
            HStack(spacing: 8) {
                appearanceCard("light", label: L.t("浅色", "Light"), symbol: "sun.max")
                appearanceCard("dark", label: L.t("深色", "Dark"), symbol: "moon")
                appearanceCard("system", label: L.t("跟随系统", "System"), symbol: "circle.lefthalf.filled")
            }
        }
    }

    private func appearanceCard(_ id: String, label: String, symbol: String) -> some View {
        let selected = app.preferredColorScheme == id
        return Button {
            app.preferredColorScheme = id // 官方：先本地 publish 再写远端
            Task { try? await app.writePreference(ns: "ui-theme", field: "preference", value: id) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                Text(label)
                    .font(.system(size: 12))
            }
            .foregroundStyle(DSH.labelPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(selected ? DSH.hoverBgSolid : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(selected ? DSH.labelCaption : DSH.borderL1, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBg, shape: AnyShape(RoundedRectangle(cornerRadius: 16))))
    }
}

// MARK: 5) Enter 行为行（ui-conversation.busyEnter：queue/steer，⌘Enter 用另一行为）

struct EnterBehaviorPreferenceRow: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        SettingsRow(
            title: L.t("繁忙时 Enter 键行为", "Enter behavior while busy"),
            description: L.t("仅智能体运行时生效；⌘Enter 使用另一行为", "Busy only; ⌘Enter uses the other behavior")
        ) {
            PillMenu(label: app.busyEnter == "steer" ? L.t("插话发送", "Steer") : L.t("排队发送", "Queue")) {
                Button(L.t("排队发送", "Queue")) { Task { await select("queue") } }
                Button(L.t("插话发送", "Steer")) { Task { await select("steer") } }
            }
        }
    }

    private func select(_ id: String) async {
        app.busyEnter = id
        try? await app.writePreference(ns: "ui-conversation", field: "busyEnter", value: id)
    }
}
