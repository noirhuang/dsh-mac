import Foundation
import SwiftUI

// MARK: - 聊天条目模型（由 SessionEvent fold 而来）

public struct DisplayBlock: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable { case text, reasoning }
    public var id: Int
    public var kind: Kind
    public var text: String
}

public struct ToolItem: Identifiable, Equatable, Sendable {
    public var id: String { callId }
    public let callId: String
    public let name: String
    public let arguments: String
    public var output: String?
    public var isError: Bool = false
    public var running: Bool = true
}

public enum ChatItem: Identifiable, Equatable {
    case user(id: String, text: String, time: Double?)
    case assistant(id: String, blocks: [DisplayBlock], streaming: Bool, time: Double?)
    case tool(ToolItem)
    case system(id: String, text: String, isError: Bool)

    public var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _, _, _), .system(let id, _, _): return id
        case .tool(let t): return t.callId
        }
    }

    public var streaming: Bool {
        if case .assistant(_, _, let s, _) = self { return s }
        return false
    }

    public var time: Double? {
        switch self {
        case .user(_, _, let t): return t
        case .assistant(_, _, _, let t): return t
        default: return nil
        }
    }

    public var plainText: String {
        switch self {
        case .user(_, let text, _): return text
        case .assistant(_, let blocks, _, _): return blocks.map(\.text).joined(separator: "\n")
        default: return ""
        }
    }
}

// MARK: - 单会话存储（事件 fold + 投影状态）

@MainActor
public final class SessionStore: ObservableObject {
    public let sessionId: String
    @Published public var items: [ChatItem] = []
    @Published public var running = false
    @Published public var title: String?
    @Published public var cwd: String?
    @Published public var models: DSHModelCatalog?

    // 投影/队列状态（QueueDock / TodoPanel / StatsLine / 权限 chip 数据源）
    @Published public var queuedItems: [QueuedItem] = []
    @Published public var todos: [TodoItem] = []
    @Published public var stats: String = ""            // 一行统计文本
    @Published public var permissions = DSHPermissions()
    @Published public var hasMoreHistory = false
    @Published public var loadingOlder = false

    public struct QueuedItem: Identifiable, Equatable {
        public var id: String
        public var text: String
        public var placement: String
    }

    public struct TodoItem: Identifiable, Equatable {
        public var id: String
        public var content: String
        public var status: String   // pending / in-progress / completed
    }

    public struct DSHPermissions: Equatable {
        public var options: [(value: String, name: String)] = []
        public var current: String = ""
        public static func == (l: DSHPermissions, r: DSHPermissions) -> Bool {
            l.current == r.current && l.options.map(\.value) == r.options.map(\.value)
        }
    }

    /// 流式草稿块（assistant/chunk 累积；assistant/message 到达时转正）
    private var draftBlocks: [DisplayBlock] = []
    private var draftTurn = -1
    private var draftStep = -1
    private var loadingHistory = false

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    // MARK: 事件 fold（mux session/event）

    public func apply(event: DSHSessionEvent) {
        switch event.type {
        case "user/message":
            // 一个 data.content[]，取文本块
            let text = (event.d["content"]?.arrayElements ?? [])
                .compactMap { $0["text"]?.stringValue }
                .joined(separator: "\n")
            let mid = event.d["id"]?.stringValue ?? "u-\(event.seq)"
            items.append(.user(id: mid, text: text, time: event.time))
        case "assistant/chunk":
            applyChunk(event)
        case "assistant/message":
            // 完成消息：以 content 块为准转正（reasoning/text），并结束草稿
            finalizeAssistant(event)
        case "tool/call":
            let callId = event.d["callId"]?.stringValue ?? "c-\(event.seq)"
            let name = event.d["name"]?.stringValue ?? "?"
            let args = event.d["arguments"]?.stringValue ?? ""
            upsertTool(ToolItem(callId: callId, name: name, arguments: args))
        case "tool/result":
            let content = event.d["message"]?["content"]?.arrayElements ?? []
            let output = content.compactMap { block -> String? in
                guard block["type"]?.stringValue == "tool-result" else { return nil }
                return (block["content"]?.arrayElements ?? [])
                    .compactMap { $0["text"]?.stringValue }
                    .joined(separator: "\n")
            }.joined(separator: "\n")
            let callId = content.first?["toolCallId"]?.stringValue ?? ""
            let isError = content.first?["isError"]?.boolValue ?? false
            if var tool = items.compactMap({ if case .tool(let t) = $0 { return t } else { return nil } })
                .first(where: { $0.callId == callId }) {
                tool.output = output.isEmpty ? "(无输出)" : output
                tool.isError = isError
                tool.running = false
                upsertTool(tool)
            }
        case "turn/start":
            running = true
            turnStartAt = event.time
        case "turn/end":
            running = false
            sealDraft()
            if let start = turnStartAt {
                lastRunSeconds = max(0, (event.time - start) / 1000)
            }
        case "todo/write":
            todos = (event.d["todos"]?.arrayElements ?? []).compactMap { t in
                guard let content = t["content"]?.stringValue else { return nil }
                return TodoItem(id: content, content: content, status: t["status"]?.stringValue ?? "pending")
            }
        case "host/agent-error", "agent/error":
            let msg = event.d["message"]?.stringValue ?? "agent 出错"
            items.append(.system(id: "sys-\(event.seq)", text: msg, isError: true))
        default:
            break // permission/preset、session/title、request/* 等 log-only 事件不渲染
        }
    }

    private func applyChunk(_ event: DSHSessionEvent) {
        let turn = event.d["turn"]?.intValue ?? 0
        let step = event.d["step"]?.intValue ?? 0
        guard let chunk = event.d["chunk"] else { return }
        let ctype = chunk["type"]?.stringValue ?? ""

        if turn != draftTurn || step != draftStep {
            sealDraft()
            draftTurn = turn
            draftStep = step
        }
        switch ctype {
        case "block-start":
            let index = chunk["index"]?.intValue ?? draftBlocks.count
            let btype = chunk["blockType"]?.stringValue ?? "text"
            while draftBlocks.count <= index { draftBlocks.append(DisplayBlock(id: draftBlocks.count, kind: .text, text: "")) }
            draftBlocks[index] = DisplayBlock(id: index, kind: btype == "reasoning" ? .reasoning : .text, text: "")
        case "text-delta", "reasoning-delta":
            let index = chunk["index"]?.intValue ?? 0
            while draftBlocks.count <= index { draftBlocks.append(DisplayBlock(id: draftBlocks.count, kind: .text, text: "")) }
            if chunk["type"]?.stringValue == "reasoning-delta" { draftBlocks[index].kind = .reasoning }
            draftBlocks[index].text += chunk["text"]?.stringValue ?? ""
        default:
            break // block-end / usage / finish 由 assistant/message 兜底
        }
        publishDraft()
    }

    private func finalizeAssistant(_ event: DSHSessionEvent) {
        let blocks = (event.d["message"]?["content"]?.arrayElements ?? []).compactMap { b -> DisplayBlock? in
            switch b["type"]?.stringValue ?? "" {
            case "text":
                return DisplayBlock(id: blocksSeed(), kind: .text, text: b["text"]?.stringValue ?? "")
            case "reasoning":
                return DisplayBlock(id: blocksSeed(), kind: .reasoning, text: b["text"]?.stringValue ?? "")
            default:
                return nil // tool-call 块由 tool/call 事件渲染
            }
        }
        if !blocks.isEmpty || !draftBlocks.isEmpty {
            let final = blocks.isEmpty ? draftBlocks : blocks
            items.append(.assistant(id: "a-\(event.seq)", blocks: final, streaming: false, time: event.time))
        }
        draftBlocks = []
        draftTurn = -1
        draftStep = -1
        refreshStreamingFlags()
    }

    /// 把当前流式草稿发布为 streaming 条目
    private func publishDraft() {
        let id = "draft-\(draftTurn)-\(draftStep)"
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = .assistant(id: id, blocks: draftBlocks, streaming: true, time: nil)
        } else if !draftBlocks.isEmpty {
            items.append(.assistant(id: id, blocks: draftBlocks, streaming: true, time: nil))
        }
    }

    /// 草稿定稿（turn 结束但没收到 assistant/message 时也保留内容）
    private func sealDraft() {
        guard !draftBlocks.isEmpty else { return }
        let id = "draft-\(draftTurn)-\(draftStep)"
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = .assistant(id: id, blocks: draftBlocks, streaming: false, time: nil)
        }
        draftBlocks = []
    }

    private func refreshStreamingFlags() {
        for idx in items.indices {
            if case .assistant(let id, let blocks, true, let time) = items[idx] {
                items[idx] = .assistant(id: id, blocks: blocks, streaming: false, time: time)
            }
        }
    }

    private func upsertTool(_ tool: ToolItem) {
        if let idx = items.firstIndex(where: { $0.id == tool.callId }) {
            items[idx] = .tool(tool)
        } else {
            items.append(.tool(tool))
        }
    }

    private var seedCounter = 10_000
    private func blocksSeed() -> Int {
        seedCounter += 1
        return seedCounter
    }

    /// 回合计时（消息操作行时钟数据）
    public var turnStartAt: Double?
    public var lastRunSeconds: Double = 0

    // MARK: 投影应用（session/projection 帧）

    public func applyProjection(key: String, value: JSONValue) {
        switch key {
        case "title":
            title = value.stringValue
        case "permissions":
            var p = DSHPermissions()
            p.options = (value["options"]?.arrayElements ?? []).compactMap { o in
                guard let v = o["value"]?.stringValue else { return nil }
                return (value: v, name: o["name"]?.stringValue ?? v)
            }
            p.current = value["currentValue"]?.stringValue ?? ""
            permissions = p
        case "sessionStats":
            let s = value
            let turns = s["turns"]?.intValue ?? 0
            let steps = s["steps"]?.intValue ?? 0
            let llmS = (s["llmMs"]?.doubleValue ?? 0) / 1000
            let toolS = (s["toolMs"]?.doubleValue ?? 0) / 1000
            let decodeMs = s["decodeMs"]?.doubleValue ?? 0
            let decodeTokens = s["decodeTokens"]?.intValue ?? 0
            var parts: [String] = []
            if turns > 0 { parts.append("\(turns) 轮 · \(steps) 步") }
            if llmS > 0 { parts.append("LLM \(Self.fmtSeconds(llmS))") }
            if toolS > 0 { parts.append("工具 \(Self.fmtSeconds(toolS))") }
            if decodeMs > 0, decodeTokens > 0 {
                parts.append(String(format: "%.1f tok/s", Double(decodeTokens) / (decodeMs / 1000)))
            }
            stats = parts.joined(separator: " · ")
        default:
            break
        }
    }

    /// session/queue 帧（QueueDock 数据源）
    public func applyQueue(items raw: [JSONValue]) {
        queuedItems = raw.compactMap { q in
            guard let id = q["id"]?.stringValue else { return nil }
            let text = (q["message"]?["content"]?.arrayElements ?? [])
                .compactMap { $0["text"]?.stringValue }
                .joined(separator: " ")
            return QueuedItem(id: id, text: text, placement: q["placement"]?.stringValue ?? "queued")
        }
    }

    static func fmtSeconds(_ s: Double) -> String {
        s >= 60 ? String(format: "%.0fm", s / 60) : String(format: "%.0fs", s)
    }

    // MARK: 历史加载

    public func loadHistory(_ events: [DSHSessionEvent], hasMore: Bool = false) {
        guard !loadingHistory else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        items.removeAll()
        for e in events { apply(event: e) }
        sealDraft()
        hasMoreHistory = hasMore
    }

    /// 向前加载更早的历史（beforeSeq 分页）
    public func prependHistory(_ events: [DSHSessionEvent], hasMore: Bool) {
        guard !loadingHistory else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        var rebuilt: [ChatItem] = []
        var savedItems = items
        // 用旧折叠器逻辑重新 fold 前缀事件，再接现有条目
        let previous = items
        items.removeAll()
        for e in events { apply(event: e) }
        rebuilt = items
        items = rebuilt + previous
        savedItems.removeAll()
        hasMoreHistory = hasMore
    }
}
