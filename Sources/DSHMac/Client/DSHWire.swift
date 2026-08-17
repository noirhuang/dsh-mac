import Foundation

// MARK: - wire 帧模型（与 dsh apiproxy 四象限协议一一对应）

/// WS 下行帧 / ServerRequest 信封：扁平结构 {type, rpcId, method, payload}
public struct DSHWireFrame: Decodable, Sendable {
    public let type: String
    public let rpcId: String
    public let method: String
    public let payload: JSONValue
}

/// HTTP 响应信封：{type:'server-response', rpcId, result:{ok, value|error}}
public struct DSHWireResponse: Decodable, Sendable {
    public struct WireResult: Decodable, Sendable {
        public let ok: Bool
        public let value: JSONValue?
        public struct WireError: Decodable, Sendable {
            public let code: String
            public let message: String
        }
        public let error: WireError?
    }
    public let rpcId: String
    public let result: WireResult
}

/// respond 的回执
public struct DSHWireReceipt: Decodable, Sendable {
    public let accepted: Bool
    public let reason: String?
}

// MARK: - 会话事件（session/event 的 event 字段）

public struct DSHSessionEvent: Decodable, Sendable, Identifiable {
    public let type: String
    public let seq: Int
    public let time: Double
    public let data: JSONValue?
    public var id: Int { seq }

    /// data 便捷取值
    public var d: JSONValue { data ?? .null }
}

// MARK: - 业务值模型（从 JSONValue 宽松提取）

public struct DSHSessionSummary: Identifiable, Hashable, Sendable {
    public let sessionId: String
    public let updatedAt: Double
    public var running: Bool
    public var blank: Bool
    public let cwd: String?
    public let agentPreset: String?
    public var title: String?
    public var id: String { sessionId }

    public init(_ v: JSONValue) {
        sessionId = v["sessionId"]?.stringValue ?? ""
        updatedAt = v["updatedAt"]?.doubleValue ?? 0
        running = v["running"]?.boolValue ?? false
        blank = v["blank"]?.boolValue ?? false
        cwd = v["cwd"]?.stringValue
        agentPreset = v["agentPreset"]?.stringValue
        title = v["projections"]?["values"]?["title"]?.stringValue
    }

    public var displayName: String {
        if let t = title, !t.isEmpty { return t }
        if let c = cwd { return (c as NSString).lastPathComponent }
        return sessionId.prefix(13).appending("…")
    }
}

public struct DSHHostDescription: Sendable {
    public let version: String
    public let cwd: String
    public let provider: String?
    public let model: String?
    public let attachedSessions: Int
    public let canOpenPath: Bool

    public init(_ v: JSONValue) {
        version = v["version"]?.stringValue ?? "?"
        cwd = v["cwd"]?.stringValue ?? ""
        provider = v["provider"]?.stringValue
        model = v["model"]?.stringValue
        attachedSessions = v["attachedSessions"]?.intValue ?? 0
        canOpenPath = v["canOpenPath"]?.boolValue ?? false
    }
}

public struct DSHModelSelection: Hashable, Sendable {
    public var provider: String
    public var model: String
    public var reasoningEffort: String?

    public init(_ v: JSONValue) {
        provider = v["provider"]?.stringValue ?? ""
        model = v["model"]?.stringValue ?? ""
        reasoningEffort = v["reasoningEffort"]?.stringValue
    }
}

public struct DSHModelCatalog: Sendable {
    public struct Effort: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public var description: String?
    }
    public struct Model: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public var description: String?
        public var efforts: [Effort]
        public var defaultEffort: String?
    }
    public struct Group: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let models: [Model]
    }
    public struct CatalogFailure: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let message: String
    }
    public let current: DSHModelSelection
    public let routable: Bool
    public let groups: [Group]
    public let failures: [CatalogFailure]

    public init(_ v: JSONValue) {
        current = DSHModelSelection(v["current"] ?? .null)
        routable = v["routable"]?.boolValue ?? false
        failures = (v["failures"]?.arrayElements ?? []).compactMap { f in
            guard let id = f["id"]?.stringValue else { return nil }
            return CatalogFailure(id: id, name: f["name"]?.stringValue ?? id, message: f["message"]?.stringValue ?? "")
        }
        groups = (v["groups"]?.arrayElements ?? []).map { g in
            Group(
                id: g["id"]?.stringValue ?? "",
                name: g["name"]?.stringValue ?? "",
                models: (g["models"]?.arrayElements ?? []).map { m in
                    Model(
                        id: m["id"]?.stringValue ?? "",
                        name: m["name"]?.stringValue ?? "",
                        description: m["description"]?.stringValue,
                        efforts: (m["reasoning"]?["efforts"]?.arrayElements ?? []).map { e in
                            Effort(id: e["id"]?.stringValue ?? "", name: e["name"]?.stringValue ?? "", description: e["description"]?.stringValue)
                        },
                        defaultEffort: m["reasoning"]?["defaultEffort"]?.stringValue
                    )
                }
            )
        }
    }
}

// MARK: - 权限/问题请求（answerable server-request）

public struct DSHApprovalRequest: Identifiable, Sendable {
    public let rpcId: String
    public let sessionId: String
    public let approvalId: String
    public let toolName: String
    public let reason: String?
    public var id: String { rpcId }
}

public struct DSHQuestionRequest: Identifiable, Sendable {
    public struct Item: Identifiable, Sendable {
        public let question: String
        public let header: String?
        public let options: [(label: String, description: String?)]

        // options 是元组数组，手写 Identifiable id
        public var id: String { question + String(options.count) }
    }
    public let rpcId: String
    public let sessionId: String
    public let items: [Item]
    public var id: String { rpcId }

    public init(rpcId: String, sessionId: String, payload: JSONValue) {
        self.rpcId = rpcId
        self.sessionId = sessionId
        var parsed: [Item] = []
        for q in payload["questions"]?.arrayElements ?? [] {
            let opts = (q["options"]?.arrayElements ?? []).map { o in
                (label: o["label"]?.stringValue ?? "", description: o["description"]?.stringValue)
            }
            parsed.append(Item(question: q["question"]?.stringValue ?? "", header: q["header"]?.stringValue, options: opts))
        }
        items = parsed
    }
}
