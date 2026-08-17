import Foundation
import SwiftUI

// MARK: - 应用总状态：进程 → 连接 → 会话/事件路由

@MainActor
public final class AppState: ObservableObject {
    @Published public var connectionState: DSHConnectionState = .stopped
    @Published public var sessions: [DSHSessionSummary] = []
    @Published public var currentSessionId: String?
    @Published public var hostDescription: DSHHostDescription?
    @Published public var pendingApproval: DSHApprovalRequest?
    @Published public var pendingQuestion: DSHQuestionRequest?
    @Published public var toast: String?
    @Published public var busy = false
    // 设置面板与外观
    @Published public var showSettings = false
    /// 设置数据失效版本（settings/document-updated、credentials/updated、llm/adapters-updated 递增）
    @Published public var settingsVersion = 0
    @Published public var preferredColorScheme: String {   // "system" / "light" / "dark"（服务端 ui-theme.preference 为准）
        didSet { UserDefaults.standard.set(preferredColorScheme, forKey: "dsh.appearance") }
    }
    /// 语言（服务端 locale.preference 为准；驱动 L10n）
    @Published public var appLanguage: String = "zh" {
        didSet {
            L.language = appLanguage
            UserDefaults.standard.set(appLanguage, forKey: "dsh.language")
        }
    }
    /// 运行中 Enter 行为（服务端 ui-conversation.busyEnter：queue / steer；⌘Enter 用另一行为）
    @Published public var busyEnter = "queue"
    /// 截图调试：设置面板目标分区
    @Published public var screenshotSettingsSection: String?

    /// settings 全局 writable 缓存（ProviderEditor 等子组件数据源）
    @Published public var settingsWritableCache = true
    /// llm-pi-ai 协议选项缓存（schema union 挖掘）
    @Published public var piAIProtocolChoices: [String] = []

    public func refreshSettingsCaches() async {
        guard let snap = try? await settingsDescribe() else { return }
        settingsWritableCache = snap.writable
        if let schema = snap.namespaces["llm-pi-ai"]?["schema"] {
            let choices = SchemaMiner.protocolChoices(piAISchema: schema)
            if !choices.isEmpty { piAIProtocolChoices = choices }
        }
    }

    public private(set) var storesStorage: [String: SessionStore] = [:]
    public weak var updaterBridge: SourceUpdater?
    public private(set) var processManager: DSHProcessManager?
    var transport: DSHTransport?
    private var frameTask: Task<Void, Never>?
    private var resumedOnce = false

    public init() {
        preferredColorScheme = UserDefaults.standard.string(forKey: "dsh.appearance") ?? "system"
        appLanguage = UserDefaults.standard.string(forKey: "dsh.language") ?? "zh"
    }

    public func store(for sessionId: String) -> SessionStore {
        if let s = storesStorage[sessionId] { return s }
        let s = SessionStore(sessionId: sessionId)
        storesStorage[sessionId] = s
        return s
    }

    /// 设置面板等 UI 直接调用 transport 的只读快照
    public func transportSnapshot() async -> DSHTransport? {
        transport
    }

    public var currentStore: SessionStore? {
        currentSessionId.map { store(for: $0) }
    }

    // MARK: 启动

    public func bootstrap() async {
        guard !resumedOnce else { return }
        resumedOnce = true

        // 资源路径：打包后 .app/Contents/Resources；开发时仓库与系统 node
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let bundledRepo = resources.appendingPathComponent("repo").path
        let bundledNode = resources.appendingPathComponent("node/bin/node").path
        let bundledShim = resources.appendingPathComponent("uds-shim.mjs").path
        let devRepo = "/Users/richardhuang/ZCodeProject/deepseek-harness"
        let devShim = "/Users/richardhuang/ZCodeProject/DSHMac/resources-node/uds-shim.mjs"
        let fm = FileManager.default

        let repoPath = fm.fileExists(atPath: bundledRepo + "/apps/cli/lib/bin.js") ? bundledRepo : devRepo
        let nodeBin = fm.fileExists(atPath: bundledNode) ? bundledNode : (Self.whichNode() ?? "/usr/bin/env")
        let shimPath = fm.fileExists(atPath: bundledShim) ? bundledShim : devShim

        let pm = DSHProcessManager.makeConfig(repoPath: repoPath, nodeBin: nodeBin, shimPath: shimPath)
        let manager = DSHProcessManager(config: pm)
        manager.onReady = { [weak self] in
            Task { await self?.attachTransport(socketPath: pm.socketPath) }
        }
        processManager = manager

        // socket 上已有活服务（上一实例未退净）则直接附加，否则冷启动
        if await DSHTransport.probe(socketPath: pm.socketPath) {
            await attachTransport(socketPath: pm.socketPath)
        } else {
            manager.start()
        }
    }

    public func shutdown() {
        frameTask?.cancel()
        let t = transport
        Task { await t?.stop() }
        processManager?.stop()
    }

    /// 解析满足 dsh 要求（^22.19 || >=24）的本机 Node：nvm 最高版本优先，其次常见路径，逐个校验版本
    private nonisolated static func whichNode() -> String? {
        var candidates: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // nvm：版本号倒序取第一个
        let nvmDir = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            let sorted = versions.sorted { lhs, rhs in
                let l = lhs.split(separator: ".").compactMap { Int($0.dropFirst()) }
                let r = rhs.split(separator: ".").compactMap { Int($0.dropFirst()) }
                return lex(l, r)
            }
            for v in sorted {
                let p = nvmDir + "/" + v + "/bin/node"
                if FileManager.default.isExecutableFile(atPath: p) { candidates.append(p) }
            }
        }

        for p in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: p) { candidates.append(p) }
        }

        // PATH 上的 which node
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "node"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        if (try? which.run()) != nil {
            which.waitUntilExit()
            let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let s, !s.isEmpty, !candidates.contains(s) { candidates.append(s) }
        }

        // 逐个校验版本（dsh engines: ^22.19.0 || >=24.0.0）
        for candidate in candidates {
            if nodeSatisfies(candidate) { return candidate }
        }
        return candidates.first
    }

    private nonisolated static func lex(_ l: [Int], _ r: [Int]) -> Bool {
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private nonisolated static func nodeSatisfies(_ bin: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "v24.14.1" → [24,14,1]
        let parts = out.dropFirst(out.hasPrefix("v") ? 1 : 0).split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        let (major, minor) = (parts[0], parts[1])
        return major > 22 || (major == 22 && minor >= 19)
    }

    // MARK: 连接

    public func attachTransport(socketPath: String) async {
        guard transport == nil else { return }
        let t = DSHTransport(socketPath: socketPath)
        transport = t
        await t.onStateChange { [weak self] state in
            print("[dsh-conn] \(state)") // 诊断：连接状态流转
            Task { @MainActor in self?.connectionState = state }
        }
        await t.onConnected { [weak self] in
            Task { await self?.onConnected() }
        }
        Task { await t.start() }

        // 订阅事件帧
        let stream = await t.frames()
        frameTask = Task { [weak self] in
            for await event in stream {
                await self?.route(method: event.method, payload: event.payload, rpcId: event.rpcId)
            }
        }
    }

    private func onConnected() async {
        await refreshSessions()
        _ = try? await describeHost()
        await adoptServerPreferences()
        await refreshSettingsCaches()
        await maybeStartOnboarding()
        // 恢复当前会话；全空时挂一个 blank 会话承载欢迎页（官方语义，模型/权限 chip 随输入卡可用）
        if currentSessionId == nil {
            if let first = sessions.first(where: { !$0.blank }) {
                await select(session: first.sessionId)
            } else if let blank = sessions.first(where: { $0.blank }) {
                await select(session: blank.sessionId)
            } else {
                await newSession(cwd: nil)
            }
        }
    }

    /// 连接建立后采纳服务端偏好（官方存储：ui-theme / locale / ui-conversation）
    private func adoptServerPreferences() async {
        if let theme = await readPreference(ns: "ui-theme", field: "preference"),
           ["light", "dark", "system"].contains(theme) {
            preferredColorScheme = theme
        }
        if let locale = await readPreference(ns: "locale", field: "preference"),
           ["zh", "en"].contains(locale) {
            appLanguage = locale
        }
        if let enter = await readPreference(ns: "ui-conversation", field: "busyEnter"),
           ["queue", "steer"].contains(enter) {
            busyEnter = enter
        }
    }

    /// 首跑引导（官方两步：welcome 声明 → DeepSeek key 引导）
    private func maybeStartOnboarding() async {
        let current = await readPreference(ns: "ui-onboarding", field: "welcomeNoticeVersion")
        if current != Self.welcomeNoticeVersion {
            showOnboardingWelcome = true
        } else {
            await evaluateKeyOnboarding()
        }
    }

    static let welcomeNoticeVersion = "2026-08-13.1"

    /// welcome 完成后评估 key 引导（readiness 纯派生：无任何 usable provider 且官方路由活且可写 → 弹）
    public func evaluateKeyOnboarding() async {
        guard !showOnboardingWelcome, !onboardingCompletedThisRun else { return }
        guard let (rows, snap) = try? await loadProviderRows() else { return }
        guard snap.writable else { onboardingCompletedThisRun = true; return }
        if rows.contains(where: \.usable) { onboardingCompletedThisRun = true; return }
        guard let official = rows.first(where: { $0.id == "deepseek-official" && $0.settingsPath.isEmpty && $0.active }) else {
            onboardingCompletedThisRun = true; return
        }
        _ = official
        showOnboardingKey = true
    }

    @Published public var showOnboardingWelcome = false
    @Published public var showOnboardingKey = false
    /// 本运行周期内已完成（官方语义：无持久化 skip，"稍后配置"仅完成本步）
    public var onboardingCompletedThisRun = false

    public func describeHost() async throws -> DSHHostDescription {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        let v = try await t.call("host.describe")
        let d = DSHHostDescription(v)
        hostDescription = d
        return d
    }

    // MARK: 会话操作

    public func refreshSessions() async {
        guard let t = transport else { return }
        do {
            let v = try await t.call("session.list")
            let items = (v["items"]?.arrayElements ?? []).map(DSHSessionSummary.init)
            sessions = items.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            toast = "会话列表刷新失败：\(error.localizedDescription)"
        }
    }

    public func select(session id: String) async {
        currentSessionId = id
        let s = store(for: id)
        if s.items.isEmpty {
            await loadHistory(session: id)
        }
        _ = await refreshModels(session: id)
    }

    public func loadHistory(session id: String) async {
        guard let t = transport else { return }
        do {
            let v = try await t.call("session.history", payload: ["sessionId": .string(id)])
            let events = (v["events"]?.arrayElements ?? []).compactMap { entry -> DSHSessionEvent? in
                guard let ev = entry["event"] else { return nil }
                return try? JSONDecoder().decode(DSHSessionEvent.self, from: JSONEncoder().encode(ev))
            }
            store(for: id).loadHistory(events, hasMore: v["hasMore"]?.boolValue ?? false)
        } catch {
            toast = "历史加载失败：\(error.localizedDescription)"
        }
    }

    /// 加载更早的历史（beforeSeq = 当前最早事件 seq）
    public func loadOlder(session id: String) async {
        guard let t = transport else { return }
        let store = store(for: id)
        guard !store.loadingOlder, store.hasMoreHistory else { return }
        store.loadingOlder = true
        defer { store.loadingOlder = false }
        guard let firstSeq = earliestSeq(store: store) else { store.hasMoreHistory = false; return }
        do {
            let v = try await t.call("session.history", payload: [
                "sessionId": .string(id), "beforeSeq": .number(Double(firstSeq)),
            ])
            let events = (v["events"]?.arrayElements ?? []).compactMap { entry -> DSHSessionEvent? in
                guard let ev = entry["event"] else { return nil }
                return try? JSONDecoder().decode(DSHSessionEvent.self, from: JSONEncoder().encode(ev))
            }
            store.prependHistory(events, hasMore: v["hasMore"]?.boolValue ?? false)
        } catch {
            toast = "加载更早失败：\(error.localizedDescription)"
        }
    }

    /// 从系统行以外的条目推导当前最早事件 seq（工具/消息条目 id 不含 seq，这里用 hasMore 兜底）
    private func earliestSeq(store: SessionStore) -> Int? {
        // ChatItem id 形如 a-<seq>/u-.../draft-...；取条目里可解析的最小 seq
        var minSeq: Int?
        for item in store.items {
            let id = item.id
            if id.hasPrefix("a-"), let s = Int(id.dropFirst(2)) {
                minSeq = minSeq.map { Swift.min($0, s) } ?? s
            }
        }
        return minSeq ?? 1
    }

    /// fork 会话（消息操作行 branch 按钮）
    public func forkSession(atSeq: Int?) async {
        guard let sid = currentSessionId, let t = transport else { return }
        var payload: [String: JSONValue] = ["sessionId": .string(sid)]
        if let atSeq { payload["atSeq"] = .number(Double(atSeq)) }
        do {
            let v = try await t.call("session.fork", payload: payload)
            if let newId = v["sessionId"]?.stringValue {
                await refreshSessions()
                await select(session: newId)
            }
        } catch {
            toast = "fork 失败：\(error.localizedDescription)"
        }
    }

    public func newSession(cwd: String?) async {
        guard let t = transport else { return }
        busy = true
        defer { busy = false }
        do {
            // 默认工作目录：hero 选择的 workspace（记忆值），避免落到 .app 内
            let effective = cwd ?? UserDefaults.standard.string(forKey: "dsh.lastWorkspace") ?? NSHomeDirectory()
            // 官方语义：复用同工作区的 blank 会话（列表隐藏 blank，不累积）
            if let reuse = sessions.first(where: { $0.blank && $0.cwd == effective }) {
                await select(session: reuse.sessionId)
                return
            }
            let v = try await t.call("session.create", payload: ["cwd": .string(effective)])
            if let sid = v["sessionId"]?.stringValue {
                await refreshSessions()
                await select(session: sid)
            }
        } catch {
            toast = "新建会话失败：\(error.localizedDescription)"
        }
    }

    /// 移除一条排队消息（QueueDock 行操作）
    public func removeQueued(sessionId: String, itemId: String) async {
        guard let t = transport else { return }
        _ = try? await t.call("session.updateQueue", payload: [
            "sessionId": .string(sessionId),
            "itemId": .string(itemId),
            "action": .object(["kind": .string("remove")]),
        ])
    }

    public func sendPrompt(_ text: String, mode: String = "queue") async {
        guard let sid = currentSessionId, let t = transport, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 乐观插入用户气泡（事件回流时会去重：同 id 覆盖）
        let s = store(for: sid)
        if case .some = s.items.first(where: { if case .user(let id, _, _) = $0 { return id == "optimistic" } else { return false } }) {
            // 已有乐观条目则跳过
        } else {
            s.items.append(.user(id: "optimistic-\(UUID().uuidString.prefix(8))", text: text, time: Date().timeIntervalSince1970 * 1000))
        }
        do {
            _ = try await t.call("session.prompt", payload: [
                "sessionId": .string(sid),
                "mode": .string(mode == "steer" ? "steer" : "queue"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "clientTimeZone": .string(TimeZone.current.identifier),
            ])
        } catch {
            toast = "发送失败：\(error.localizedDescription)"
        }
    }

    public func cancelTurn() async {
        guard let sid = currentSessionId, let t = transport else { return }
        _ = try? await t.call("session.cancel", payload: ["sessionId": .string(sid)])
    }

    public func refreshModels(session id: String) async -> DSHModelCatalog? {
        guard let t = transport else { return nil }
        guard let v = try? await t.call("session.models", payload: ["sessionId": .string(id)]) else { return nil }
        let catalog = DSHModelCatalog(v)
        store(for: id).models = catalog
        return catalog
    }

    public func selectModel(provider: String, model: String, effort: String?) async {
        guard let sid = currentSessionId else { return }
        try? await selectModelRaw(sessionId: sid, provider: provider, model: model, reasoningEffort: effort)
    }

    /// ModelSeat 直连版：错误上抛（菜单内 toast），成功后刷新目录
    public func selectModelRaw(sessionId: String, provider: String, model: String, reasoningEffort: String?) async throws {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        var payload: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "provider": .string(provider),
            "model": .string(model),
        ]
        if let effort = reasoningEffort { payload["reasoningEffort"] = .string(effort) }
        _ = try await t.call("session.selectModel", payload: payload)
        _ = await refreshModels(session: sessionId)
    }

    public func rename(session id: String, title: String) async {
        guard let t = transport else { return }
        _ = try? await t.call("session.rename", payload: ["sessionId": .string(id), "title": .string(title)])
        await refreshSessions()
    }

    // MARK: 审批/问题应答

    public func resolveApproval(_ request: DSHApprovalRequest, allow: Bool) async {
        guard let t = transport else { return }
        let value: JSONValue = .object([
            "sessionId": .string(request.sessionId),
            "approvalId": .string(request.approvalId),
            "outcome": .string(allow ? "allowed-once" : "rejected"),
        ])
        try? await t.respond(rpcId: request.rpcId, value: value)
        pendingApproval = nil
    }

    public func resolveQuestion(_ request: DSHQuestionRequest, answers: [Int]) async {
        guard let t = transport else { return }
        // AskUserQuestionAnswer：一批答案，每题 { selected: [index] }（宽松构造）
        let answerArray: [JSONValue] = answers.enumerated().map { _, selected in
            .object(["selected": .array([.number(Double(selected))])])
        }
        let value: JSONValue = .object([
            "sessionId": .string(request.sessionId),
            "answer": .object(["answers": .array(answerArray)]),
        ])
        try? await t.respond(rpcId: request.rpcId, value: value)
        pendingQuestion = nil
    }

    // MARK: 权限预设（官方路径：/permission <preset> 斜杠命令）

    public func selectPermission(_ preset: String) async {
        guard let sid = currentSessionId else { return }
        _ = try? await sendRawPrompt(sessionId: sid, text: "/permission \(preset)")
    }

    /// 原样 content 发送（图片附件路径：content 已含 text/image 块）
    public func sendPromptContent(sessionId: String, mode: String, content: [JSONValue]) async {
        guard let t = transport else { return }
        let store = store(for: sessionId)
        if case .some(.user(let id, _, _)) = store.items.last, id.hasPrefix("optimistic") {
            // 已有乐观条目则跳过
        } else if content.contains(where: { if case .object(let o) = $0, o["type"]?.stringValue == "text" { return true } else { return false } }),
                  let textBlock = content.first(where: { if case .object(let o) = $0, o["type"]?.stringValue == "text" { return true } else { return false } }),
                  case .object(let o) = textBlock, let text = o["text"]?.stringValue {
            store.items.append(.user(id: "optimistic-\(UUID().uuidString.prefix(8))", text: text, time: Date().timeIntervalSince1970 * 1000))
        }
        _ = try? await t.call("session.prompt", payload: [
            "sessionId": .string(sessionId),
            "mode": .string(mode == "steer" ? "steer" : "queue"),
            "content": .array(content),
            "clientTimeZone": .string(TimeZone.current.identifier),
        ])
    }

    /// 直接以文本提交 prompt（供斜杠命令复用；不插入乐观气泡）
    private func sendRawPrompt(sessionId: String, text: String) async throws {
        guard let t = transport else { return }
        _ = try await t.call("session.prompt", payload: [
            "sessionId": .string(sessionId),
            "mode": .string("queue"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "clientTimeZone": .string(TimeZone.current.identifier),
        ])
    }

    // MARK: 设置：provider / 凭据

    public struct ProviderInfo: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let settingsNs: String
        /// 设置 value 内的定位路径（llm-pi-ai 系为 ["providers","<id>"]；llm-deepseek 为 []）
        public let settingsPath: [String]
        /// 当前已激活（完成配置并注册路由）
        public let active: Bool
    }

    /// llm.providers：可配置 provider 目录（实测结构 {providers:[...]}；活跃的排前面）
    public func llmProviders() async -> [ProviderInfo] {
        guard let t = transport, let v = try? await t.call("llm.providers") else { return [] }
        let list = v["providers"]?.arrayElements ?? v.arrayElements // 主结构 + 顶层数组兜底
        let items = list.compactMap { p -> ProviderInfo? in
            guard let id = p["provider"]?.stringValue else { return nil }
            return ProviderInfo(
                id: id,
                name: p["displayName"]?.stringValue ?? id,
                settingsNs: p["settingsNs"]?.stringValue ?? "",
                settingsPath: (p["settingsPath"]?.arrayElements ?? []).compactMap(\.stringValue),
                active: p["active"]?.boolValue ?? false
            )
        }
        return items.sorted { $0.active && !$1.active }
    }

    /// credentials.describe：refs 批量查询 → [ref: configured]
    public func credentialsState(refs: [String]) async -> [String: Bool] {
        guard let t = transport, !refs.isEmpty,
              let v = try? await t.call("credentials.describe", payload: ["refs": .array(refs.map { .string($0) })])
        else { return [:] }
        var out: [String: Bool] = [:]
        if let dict = v["credentials"]?.objectPairs {
            // 返回的 JSONValue object 直接展开
            for (ref, view) in dict {
                out[ref] = view["configured"]?.boolValue ?? false
            }
        } else {
            // 宽松兜底：数组形态
            for entry in v.arrayElements {
                if let ref = entry["ref"]?.stringValue {
                    out[ref] = entry["configured"]?.boolValue ?? false
                }
            }
        }
        return out
    }

    /// credentials.set：写入 API key
    public func setCredential(ref: String, value: String) async throws {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        _ = try await t.call("credentials.set", payload: ["ref": .string(ref), "value": .string(value)])
    }

    // MARK: 事件路由

    private func route(method: String, payload: JSONValue, rpcId: String) async {
        switch method {
        case "session/event":
            guard let sid = payload["sessionId"]?.stringValue else { return }
            guard let evValue = payload["event"] else { return }
            guard let ev = try? JSONDecoder().decode(DSHSessionEvent.self, from: JSONEncoder().encode(evValue)) else { return }
            let store = store(for: sid)
            store.apply(event: ev)
            // 乐观用户气泡去重（真实 user/message 已到）
            if ev.type == "user/message" {
                store.items.removeAll { item in
                    if case .user(let id, _, _) = item { return id.hasPrefix("optimistic") } else { return false }
                }
            }
        case "session/projection":
            guard let sid = payload["sessionId"]?.stringValue else { return }
            let key = payload["key"]?.stringValue ?? ""
            if let value = payload["value"] {
                let store = store(for: sid)
                store.applyProjection(key: key, value: value)
                if key == "title", let t = value.stringValue {
                    if let idx = sessions.firstIndex(where: { $0.sessionId == sid }) {
                        sessions[idx].title = t
                    }
                }
            }
        case "session/queue":
            guard let sid = payload["sessionId"]?.stringValue else { return }
            store(for: sid).applyQueue(items: payload["items"]?.arrayElements ?? [])
        case "host/remote-event":
            // 官方 allowlisted host 事件转发（设置面板失效刷新的来源）
            let event = payload["event"]?.stringValue ?? ""
            switch event {
            case "settings/document-updated", "credentials/updated", "llm/adapters-updated":
                settingsVersion += 1
            default:
                break
            }
        case "host/session-added":
            if let sid = payload["sessionId"]?.stringValue {
                let s = DSHSessionSummary(payload)
                if !sessions.contains(where: { $0.sessionId == sid }) {
                    sessions.insert(s, at: 0)
                }
            }
        case "host/session-removed":
            if let sid = payload["sessionId"]?.stringValue {
                sessions.removeAll { $0.sessionId == sid }
                if currentSessionId == sid { currentSessionId = nil }
            }
        case "host/session-status":
            if let sid = payload["sessionId"]?.stringValue {
                let running = payload["running"]?.boolValue ?? false
                store(for: sid).running = running
                if let idx = sessions.firstIndex(where: { $0.sessionId == sid }) {
                    sessions[idx].running = running
                }
            }
        case "approval/requested":
            pendingApproval = DSHApprovalRequest(
                rpcId: rpcId,
                sessionId: payload["sessionId"]?.stringValue ?? "",
                approvalId: payload["approvalId"]?.stringValue ?? "",
                toolName: payload["toolName"]?.stringValue ?? "?",
                reason: payload["reason"]?.stringValue
            )
        case "approval/resolved":
            pendingApproval = nil
        case "question/requested":
            pendingQuestion = DSHQuestionRequest(
                rpcId: rpcId,
                sessionId: payload["sessionId"]?.stringValue ?? "",
                payload: payload
            )
        case "question/resolved":
            pendingQuestion = nil
        default:
            break
        }
    }
}

