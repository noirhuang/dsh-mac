import Foundation

// MARK: - 设置数据层支撑：JSON path 工具 / schemastery schema 挖掘 / diff ops
// 语义全部对齐官方 ui-settings-models/store.ts（调研结论）。

// MARK: JSON path 工具

enum JSONPath {
    /// 沿 path 深入对象；缺任一段返回 nil
    static func get(_ root: JSONValue?, path: [String]) -> JSONValue? {
        var node = root
        for seg in path {
            guard let next = node?[seg] else { return nil }
            node = next
        }
        return node
    }

    static func has(_ root: JSONValue?, path: [String]) -> Bool {
        get(root, path: path) != nil
    }

    /// 不可变 set：返回新树；path 缺失的中间层会创建为空对象
    static func set(_ root: JSONValue, path: [String], value: JSONValue) -> JSONValue {
        guard !path.isEmpty else { return value }
        var dict: [String: JSONValue]
        if case .object(let o) = root { dict = o } else { dict = [:] }
        let head = path[0]
        dict[head] = set(dict[head] ?? .object([:]), path: Array(path.dropFirst()), value: value)
        return .object(dict)
    }

    /// 不可变 unset：删除 path 指向的键；中间层不存在则原样返回
    static func unset(_ root: JSONValue, path: [String]) -> JSONValue {
        guard !path.isEmpty else { return root }
        if path.count == 1 {
            guard case .object(var dict) = root else { return root }
            dict[path[0]] = nil
            return .object(dict)
        }
        guard case .object(var dict) = root, let child = dict[path[0]] else { return root }
        dict[path[0]] = unset(child, path: Array(path.dropFirst()))
        return .object(dict)
    }
}

// MARK: diff → settings.mutate ops（对齐官方 pathOps）

enum SettingsDiff {
    /// 提交单元：op set/unset 的 wire 形态
    struct Op {
        var op: String            // "set" | "unset"
        var path: [String]
        var value: JSONValue?
    }

    static func opsAsJSON(_ ops: [Op]) -> JSONValue {
        .array(ops.map { op in
            var d: [String: JSONValue] = ["op": .string(op.op), "path": .array(op.path.map { .string($0) })]
            if let v = op.value { d["value"] = v }
            return .object(d)
        })
    }

    /// 顶层逐键 diff（before/after 均为 profile 对象）：值不同→set；before 有 after 无→unset
    static func pathOps(base: [String: JSONValue], before: [String: JSONValue], after: [String: JSONValue], prefix: [String]) -> [Op] {
        var ops: [Op] = []
        let keys = Set(before.keys).union(after.keys)
        for key in keys.sorted() {
            let b = before[key]
            let a = after[key]
            let path = prefix + [key]
            switch (b, a) {
            case (nil, .some(let av)):
                ops.append(Op(op: "set", path: path, value: av))
            case (.some, nil):
                ops.append(Op(op: "unset", path: path, value: nil))
            case (.some(let bv), .some(let av)):
                if bv != av {
                    ops.append(Op(op: "set", path: path, value: av))
                }
            case (nil, nil):
                break
            }
        }
        return ops
    }
}

// MARK: key ref 派生（官方 deriveKeyRef：'minimax-cn' → 'MINIMAX_CN_API_KEY'）

func deriveKeyRef(_ provider: String) -> String {
    let upper = provider.uppercased().replacingOccurrences(of: "-", with: "_")
    return upper + "_API_KEY"
}

// MARK: schemastery schema 挖掘（实测 envelope：refs 裸 id 引用；dict 值模式在 inner）

enum SchemaMiner {
    /// 解引用：节点可能是裸 ref id（数字/字符串）或 {"ref": id}
    static func deref(_ node: JSONValue, refs: [String: JSONValue]) -> JSONValue? {
        var current = node
        for _ in 0..<40 {
            switch current {
            case .number(let n):
                guard let next = refs[String(Int(n))] else { return nil }
                current = next
            case .string(let s):
                guard let next = refs[s] else {
                    return current // 真字符串值，非 ref
                }
                current = next
            case .object(let dict):
                if let ref = dict["ref"], let next = refs[ref.stringValue ?? ""] {
                    current = next
                } else {
                    return current
                }
            default:
                return current
            }
        }
        return current
    }

    static func refsRoot(_ schema: JSONValue) -> (refs: [String: JSONValue], root: JSONValue?) {
        guard case .object(let o) = schema else { return ([:], nil) }
        var refs: [String: JSONValue] = [:]
        if case .object(let r) = o["refs"] {
            for (k, v) in r { refs[k] = v }
        }
        let root = deref(o["uid"] ?? .null, refs: refs)
        return (refs, root)
    }

    /// 对象 dict 的子节点（处理后 inner）
    static func dictNode(_ node: JSONValue, key: String, refs: [String: JSONValue]) -> JSONValue? {
        guard let dict = node["dict"]?.objectPairs else { return nil }
        for (k, v) in dict where k == key {
            return deref(v, refs: refs)
        }
        return nil
    }

    /// 字典值模式：dict 类型的 inner（实测 providers 用 inner 而非 valuePattern）
    static func innerNode(_ node: JSONValue, refs: [String: JSONValue]) -> JSONValue? {
        if let inner = node["inner"] { return deref(inner, refs: refs) }
        if let vp = node["valuePattern"] { return deref(vp, refs: refs) }
        return nil
    }

    /// union 节点的 const string 选项
    static func unionStrings(_ node: JSONValue, refs: [String: JSONValue]) -> [String] {
        guard node["type"]?.stringValue == "union" else { return [] }
        var out: [String] = []
        for item in node["list"]?.arrayElements ?? [] {
            if let c = deref(item, refs: refs), c["type"]?.stringValue == "const",
               let v = c["value"]?.stringValue {
                out.append(v)
            }
        }
        return out
    }

    /// 字段默认值（meta.default）
    static func defaultValue(_ node: JSONValue) -> JSONValue? {
        node["meta"]?["default"]
    }

    /// pi-ai providers.<route>.api 的协议选项（实测路径：root.dict.providers → inner → dict.api → union）
    static func protocolChoices(piAISchema: JSONValue) -> [String] {
        let (refs, root) = refsRoot(piAISchema)
        guard let root else { return [] }
        guard let providers = dictNode(root, key: "providers", refs: refs) else { return [] }
        guard let profile = innerNode(providers, refs: refs) else { return [] }
        guard let api = dictNode(profile, key: "api", refs: refs) else { return [] }
        return unionStrings(api, refs: refs)
    }
}

// MARK: Provider 行 join 模型（对齐官方 ProviderRow）

struct SettingsProviderRow: Identifiable {
    let id: String                    // provider 路由 id
    let name: String                  // displayName
    let settingsNs: String
    let settingsPath: [String]
    let active: Bool
    let declared: Bool
    // join 结果
    var apiKeyEnv: String?
    var configured = false            // profile 解析得到
    var removable = false             // 仅 user 层携带
    var credentialConfigured = false
    var credentialWritable = false

    /// 官方 providerUsable：active &&（无 key ref || credential.configured）
    var usable: Bool {
        if !active { return false }
        if apiKeyEnv == nil { return true }
        return credentialConfigured
    }

    var managedCredentialRef: String? {
        guard let env = apiKeyEnv, env == deriveKeyRef(id), credentialConfigured, credentialWritable else { return nil }
        return env
    }
}
