import Foundation

// MARK: - AppState 设置域扩展（官方 settings/credentials/agentPreset/pluginInventory/llm.discover 的完整 wire 封装）

extension AppState {
    // MARK: settings.describe

    struct SettingsSnapshot {
        var writable = true
        var hasDocument = false
        var namespaces: [String: JSONValue] = [:]   // 完整 namespace view（ns/schema/value/base/user/revision/…）
        var revisions: [String: Int] = [:]
    }

    func settingsDescribe() async throws -> SettingsSnapshot {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        let v = try await t.call("settings.describe")
        var snap = SettingsSnapshot()
        snap.writable = v["writable"]?.boolValue ?? true
        snap.hasDocument = v["hasDocument"]?.boolValue ?? false
        for ns in v["namespaces"]?.arrayElements ?? [] {
            guard let key = ns["ns"]?.stringValue else { continue }
            snap.namespaces[key] = ns
            snap.revisions[key] = ns["revision"]?.intValue ?? 0
        }
        return snap
    }

    /// ns view 的合成值
    static func valueOf(ns: JSONValue?) -> JSONValue? { ns?["value"] }
    static func userLayerOf(ns: JSONValue?) -> JSONValue? { ns?["user"] }
    static func baseLayerOf(ns: JSONValue?) -> JSONValue? { ns?["base"] }

    // MARK: 写

    func settingsMutate(ns: String, ops: [SettingsDiff.Op], expectedRevision: Int?) async throws -> JSONValue {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        var payload: [String: JSONValue] = [
            "ns": .string(ns),
            "ops": SettingsDiff.opsAsJSON(ops),
        ]
        if let r = expectedRevision { payload["expectedRevision"] = .number(Double(r)) }
        return try await t.call("settings.mutate", payload: payload) // → 新 namespace view
    }

    func settingsUpdate(ns: String, patch: [String: JSONValue], expectedRevision: Int?) async throws -> JSONValue {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        var payload: [String: JSONValue] = ["ns": .string(ns), "patch": .object(patch)]
        if let r = expectedRevision { payload["expectedRevision"] = .number(Double(r)) }
        return try await t.call("settings.update", payload: payload)
    }

    // MARK: provider join（官方 ModelsSettingsStore.load 语义）

    func loadProviderRows() async throws -> (rows: [SettingsProviderRow], snapshot: SettingsSnapshot) {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        async let providersValue = t.call("llm.providers")
        async let describeValue = t.call("settings.describe")
        let providersJSON = try await providersValue
        let describeJSON = try await describeValue

        var snap = SettingsSnapshot()
        snap.writable = describeJSON["writable"]?.boolValue ?? true
        for ns in describeJSON["namespaces"]?.arrayElements ?? [] {
            if let key = ns["ns"]?.stringValue {
                snap.namespaces[key] = ns
                snap.revisions[key] = ns["revision"]?.intValue ?? 0
            }
        }

        let list = providersJSON["providers"]?.arrayElements ?? providersJSON.arrayElements
        var rows: [SettingsProviderRow] = (list ?? []).compactMap { p in
            guard let id = p["provider"]?.stringValue else { return nil }
            return SettingsProviderRow(
                id: id,
                name: p["displayName"]?.stringValue ?? id,
                settingsNs: p["settingsNs"]?.stringValue ?? "",
                settingsPath: (p["settingsPath"]?.arrayElements ?? []).compactMap(\.stringValue),
                active: p["active"]?.boolValue ?? false,
                declared: p["declared"]?.boolValue ?? false,
                apiKeyEnv: nil
            )
        }

        // join：value/user/base + apiKeyEnv
        for idx in rows.indices {
            let row = rows[idx]
            guard let nsView = snap.namespaces[row.settingsNs] else { continue }
            let value = nsView["value"]
            let user = nsView["user"]
            let base = nsView["base"]
            let profileValue = JSONPath.get(value, path: row.settingsPath)
            rows[idx].configured = row.settingsPath.isEmpty ? (value != nil) : (profileValue != nil)
            if row.settingsPath.isEmpty {
                rows[idx].apiKeyEnv = profileValue?["apiKeyEnv"]?.stringValue
                rows[idx].removable = false
            } else {
                rows[idx].apiKeyEnv = profileValue?["apiKeyEnv"]?.stringValue
                let inUser = JSONPath.has(user, path: row.settingsPath)
                let inBase = JSONPath.has(base, path: row.settingsPath)
                rows[idx].removable = inUser && !inBase
            }
        }

        // 批量凭据状态
        let refs = Array(Set(rows.compactMap(\.apiKeyEnv)))
        if !refs.isEmpty, let cred = try? await t.call("credentials.describe", payload: ["refs": .array(refs.map { .string($0) })]) {
            if case .object(let map)? = cred["credentials"] {
                for idx in rows.indices {
                    if let ref = rows[idx].apiKeyEnv, let view = map[ref] {
                        rows[idx].credentialConfigured = view["configured"]?.boolValue ?? false
                        rows[idx].credentialWritable = view["writable"]?.boolValue ?? true
                    }
                }
            }
        }
        return (rows, snap)
    }

    // MARK: agentPresets

    struct AgentPresetEntry: Identifiable, Hashable {
        public let id: String
        public let trust: String        // system | user
        public let isDefault: Bool
        public let name: String?
        public let description: String?
        public let broken: String?
    }

    func agentPresetList() async throws -> (presets: [AgentPresetEntry], authorable: Bool) {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        let v = try await t.call("agentPreset.list")
        let presets = (v["presets"]?.arrayElements ?? []).compactMap { p -> AgentPresetEntry? in
            guard let id = p["id"]?.stringValue else { return nil }
            return AgentPresetEntry(
                id: id,
                trust: p["trust"]?.stringValue ?? "system",
                isDefault: p["isDefault"]?.boolValue ?? false,
                name: p["name"]?.stringValue,
                description: p["description"]?.stringValue,
                broken: p["broken"]?.stringValue
            )
        }
        return (presets, v["authorable"]?.boolValue ?? false)
    }

    func agentPresetRead(id: String) async throws -> String {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        let v = try await t.call("agentPreset.read", payload: ["agentPreset": .string(id)])
        return v["content"]?.stringValue ?? ""
    }

    func agentPresetCopy(from: String, newId: String, name: String?) async throws {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        var payload: [String: JSONValue] = ["from": .string(from), "agentPreset": .string(newId)]
        if let name { payload["name"] = .string(name) }
        _ = try await t.call("agentPreset.copy", payload: payload)
    }

    func agentPresetRemove(id: String) async throws {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        _ = try await t.call("agentPreset.remove", payload: ["agentPreset": .string(id)])
    }

    func agentPresetOpenDocument(id: String) async throws -> String? {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        let v = try await t.call("agentPreset.openDocument", payload: ["agentPreset": .string(id)])
        if v["opened"]?.boolValue == true { return nil }
        return v["path"]?.stringValue
    }

    // MARK: pluginInventory（Typert Remote：payload 需 args 包裹，实测 /api/pluginInventory/list）

    struct PluginEntry: Identifiable, Hashable {
        public var id: String { entryId }
        public let entryId: String
        public let moduleName: String
        public let enabled: Bool
        public let fiberPhase: String?   // pending/loading/active/failed/unloading/null
    }

    func pluginInventory() async throws -> [PluginEntry] {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        let v = try await t.call("pluginInventory/list", payload: ["args": .object([:])])
        return (v["entries"]?.arrayElements ?? []).compactMap { e in
            guard let entryId = e["entryId"]?.stringValue else { return nil }
            return PluginEntry(
                entryId: entryId,
                moduleName: e["moduleName"]?.stringValue ?? entryId,
                enabled: e["enabled"]?.boolValue ?? false,
                fiberPhase: e["fiberPhase"]?.stringValue
            )
        }
    }

    // MARK: 模型发现（官方 llm.discoverModels：问的是表单当前值）

    func discoverModels(settingsNs: String, provider: String?, baseURL: String?, api: String?, apiKey: String?) async throws -> [String] {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        var payload: [String: JSONValue] = ["settingsNs": .string(settingsNs)]
        if let provider { payload["provider"] = .string(provider) }
        if let baseURL { payload["baseURL"] = .string(baseURL) }
        if let api { payload["api"] = .string(api) }
        if let apiKey, !apiKey.isEmpty { payload["apiKey"] = .string(apiKey) }
        let v = try await t.call("llm.discoverModels", payload: payload)
        // 响应：模型候选列表（宽松提取 ids）
        var ids: [String] = []
        for candidate in v["models"]?.arrayElements ?? v.arrayElements {
            if let id = candidate["id"]?.stringValue { ids.append(id) }
        }
        return ids
    }

    // MARK: 通用偏好读写（通用分区 5 行的存储路径，全部对齐官方）

    /// 官方 ns：ui-theme.preference / locale.preference / ui-conversation.busyEnter / permission.defaultPreset / agent-presets.default
    func readPreference(ns: String, field: String) async -> String? {
        guard let snap = try? await settingsDescribe(),
              let view = snap.namespaces[ns] else { return nil }
        return view["value"]?[field]?.stringValue
    }

    func writePreference(ns: String, field: String, value: String, usePatch: Bool = false) async throws {
        let snap = try await settingsDescribe()
        let revision = snap.revisions[ns]
        if usePatch {
            _ = try await settingsUpdate(ns: ns, patch: [field: .string(value)], expectedRevision: revision)
        } else {
            _ = try await settingsMutate(
                ns: ns,
                ops: [SettingsDiff.Op(op: "set", path: [field], value: .string(value))],
                expectedRevision: revision
            )
        }
    }
}

// MARK: - 凭据与设置缓存（主文件中已有 setCredential/credentialsState；此处补充其余）

extension AppState {
    /// credentials.unset：删除凭据（幂等）
    public func unsetCredential(ref: String) async throws {
        guard let t = transport else { throw DSHRpcError(code: "internal", message: "未连接") }
        _ = try await t.call("credentials.unset", payload: ["ref": .string(ref)])
    }
}
