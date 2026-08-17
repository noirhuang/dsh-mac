import SwiftUI

// MARK: - 消息条目（官方 MessageItem/AssistantMarkdown/ReasoningRow/ToolCallTree 复刻）

struct ChatItemView: View {
    let item: ChatItem
    var sessionId: String = ""

    var body: some View {
        switch item {
        case .user(_, let text, let time):
            VStack(alignment: .trailing, spacing: 6) {
                UserBubble(text: text)
                MessageActionsRow(text: text, time: time, runSeconds: 0, clockPosition: .leading, sessionId: sessionId, item: item)
            }
        case .assistant(_, let blocks, let streaming, let time):
            VStack(alignment: .leading, spacing: 6) {
                AssistantBody(blocks: blocks, streaming: streaming)
                if !streaming {
                    MessageActionsRow(text: blocks.map(\.text).joined(separator: "\n"), time: time, runSeconds: 0, clockPosition: .trailing, sessionId: sessionId, item: item)
                }
            }
        case .tool(let tool):
            ToolRow(tool: tool)
        case .system(_, let text, let isError):
            TurnErrorRow(text: text, isError: isError)
        }
    }
}

// MARK: 消息操作行（官方 MessageIconActions：复制 + fork + 时钟）

enum ClockPosition {
    case leading
    case trailing
}

struct MessageActionsRow: View {
    @EnvironmentObject private var app: AppState
    let text: String
    let time: Double?
    var runSeconds: Double
    var clockPosition: ClockPosition = .trailing
    let sessionId: String
    let item: ChatItem
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            if clockPosition == .leading, let label = clockLabel {
                Text(label).font(.system(size: 11)).foregroundStyle(DSH.labelCaption)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(copied ? DSH.successPrimary : DSH.labelTertiary)
            }
            .buttonStyle(.plain)
            .help("复制")
            .opacity(hover || copied ? 1 : 0.55)

            // fork/branch（assistant 消息）
            if clockPosition == .trailing, !sessionId.isEmpty {
                Button {
                    Task { await app.forkSession(atSeq: forkSeq) }
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12))
                        .foregroundStyle(DSH.labelTertiary)
                }
                .buttonStyle(.plain)
                .help("从此处分叉会话")
                .opacity(hover ? 1 : 0.55)
            }

            if clockPosition == .trailing, let label = clockLabel {
                Text(label).font(.system(size: 11)).foregroundStyle(DSH.labelCaption)
            }
        }
        .onHover { hover = $0 }
    }

    private var clockLabel: String? {
        var parts: [String] = []
        if let time {
            parts.append(Self.messageClock(time))
        }
        if runSeconds > 0 { parts.append(Self.runDuration(runSeconds * 1000)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 官方 formatMessageClock：今天 HH:mm；今年更早 m月d日 HH:mm；往年 y年m月d日 HH:mm
    static func messageClock(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let clock = f.string(from: date)
        let now = Date()
        if cal.isDate(date, inSameDayAs: now) { return clock }
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let n = cal.dateComponents([.year, .month, .day], from: now)
        let datePart = c.year == n.year
            ? L.t("\(c.month!)月\(c.day!)日", "\(c.month!)/\(c.day!)")
            : L.t("\(c.year!)年\(c.month!)月\(c.day!)日", "\(c.month!)/\(c.day!)/\(c.year!)")
        return "\(datePart) \(clock)"
    }

    /// 官方 formatRunDuration：X 秒 / X 分 YY 秒
    static func runDuration(_ ms: Double) -> String {
        let total = Int(max(0, ms) / 1000)
        let m = total / 60
        let s = total % 60
        return m > 0 ? L.t("\(m) 分 \(String(format: "%02d", s)) 秒", "\(m)m \(String(format: "%02d", s))s") : L.t("\(s) 秒", "\(s)s")
    }

    private var forkSeq: Int? {
        if item.id.hasPrefix("a-") { return Int(item.id.dropFirst(2)) }
        return nil
    }
}

// MARK: 用户气泡（右对齐，22px 圆角，最宽 min(525, 82%)）

struct UserBubble: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(text)
                .font(.system(size: 16))
                .lineSpacing(7)
                .foregroundStyle(DSH.labelPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DSH.Metrics.bubbleRadius)
                        .fill(DSH.bubble)
                )
                .frame(maxWidth: 525, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: 助手正文（无气泡全宽，16/28 行高，块间距 16px）

struct AssistantBody: View {
    let blocks: [DisplayBlock]
    let streaming: Bool
    @State private var expandedReasonings: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DSH.Metrics.itemSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                if block.kind == .reasoning {
                    if expandedReasonings.contains(block.id) || (streaming && index == 0) {
                        if streaming && index == 0 {
                            // 进行中的思考：摘要行 + 扫光
                            ReasoningRow(summary: summarize(block.text), running: true, expanded: true) {
                                toggle(block.id)
                            }
                            Text(block.text.suffix(600))
                                .font(.system(size: 14))
                                .lineSpacing(7)
                                .foregroundStyle(DSH.labelTertiary)
                                .textSelection(.enabled)
                                .padding(.leading, 22)
                        } else {
                            ReasoningRow(summary: summarize(block.text), running: false, expanded: true) {
                                toggle(block.id)
                            }
                            Text(block.text)
                                .font(.system(size: 14))
                                .lineSpacing(7)
                                .foregroundStyle(DSH.labelTertiary)
                                .textSelection(.enabled)
                                .padding(.leading, 22)
                        }
                    } else {
                        ReasoningRow(summary: summarize(block.text), running: false, expanded: false) {
                            toggle(block.id)
                        }
                    }
                } else if !block.text.isEmpty {
                    AssistantMarkdown(text: block.text)
                }
            }
            if streaming && blocks.allSatisfy(\.text.isEmpty) {
                TypingDots()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: Int) {
        if expandedReasonings.contains(id) { expandedReasonings.remove(id) } else { expandedReasonings.insert(id) }
    }

    private func summarize(_ text: String) -> String {
        let first = text.split(separator: "\n").first ?? Substring(text)
        return String(first.prefix(80))
    }
}

// MARK: 思考行（chevron + 摘要，运行时扫光）

struct ReasoningRow: View {
    let summary: String
    let running: Bool
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DSH.labelSecondary)
                Text(running ? "思考中…" : "已深度思考")
                    .font(.system(size: 14))
                    .foregroundStyle(DSH.labelSecondary)
                Circle()
                    .fill(DSH.labelCaption)
                    .frame(width: 2, height: 2)
                Text(summary)
                    .font(.system(size: 14))
                    .foregroundStyle(DSH.labelTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay {
                if running { SweepOverlay() }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: 工具行（紧凑行 + 展开详情，官方 ToolCallTree）

struct ToolRow: View {
    let tool: ToolItem
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    toolIcon
                    Text(tool.name)
                        .font(.system(size: 14))
                        .foregroundStyle(DSH.labelPrimary)
                    Text(argumentSummary)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(DSH.labelTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if tool.running {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: tool.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(tool.isError ? DSH.errorPrimary : DSH.successPrimary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DSH.labelTertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBg, shape: AnyShape(RoundedRectangle(cornerRadius: 6))))

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !tool.arguments.isEmpty {
                        Text(prettyArguments)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(DSH.labelSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(DSH.codeBlockBg)
                            )
                    }
                    if let output = tool.output {
                        ScrollView {
                            Text(output)
                                .font(.system(size: 13, design: .monospaced))
                                .lineSpacing(7)
                                .foregroundStyle(tool.isError ? DSH.errorPrimary : DSH.labelPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(DSH.codeBlockBg)
                        )
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    private var toolIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 12))
            .foregroundStyle(DSH.labelSecondary)
            .frame(width: 16)
    }

    private var iconName: String {
        switch tool.name {
        case let n where n.contains("bash") || n.contains("shell"): return "terminal"
        case let n where n.contains("read"): return "doc.text"
        case let n where n.contains("write") || n.contains("edit"): return "square.and.pencil"
        case let n where n.contains("glob"): return "folder"
        case let n where n.contains("grep") || n.contains("search"): return "magnifyingglass"
        case let n where n.contains("web") || n.contains("fetch"): return "globe"
        case let n where n.contains("todo"): return "checklist"
        case let n where n.contains("subagent"): return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }

    private var argumentSummary: String {
        guard let data = tool.arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return tool.arguments.prefix(60).description }
        let priority = ["command", "path", "pattern", "file_path", "url", "query", "description"]
        for key in priority {
            if let v = obj[key] as? String { return v.prefix(80).description }
        }
        if let first = obj.values.first(where: { ($0 as? String) != nil }) as? String {
            return first.prefix(80).description
        }
        return ""
    }

    private var prettyArguments: String {
        guard let data = tool.arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return tool.arguments }
        return String(data: pretty, encoding: .utf8) ?? tool.arguments
    }
}

// MARK: 错误/系统行

struct TurnErrorRow: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isError ? DSH.errorPrimary : DSH.labelCaption)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            if isError {
                Text("出错").font(.system(size: 13, weight: .semibold)).foregroundStyle(DSH.errorPrimary)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(DSH.labelSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: 打字指示（三点）

struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 5, height: 5)
                    .foregroundStyle(DSH.labelTertiary)
                    .opacity(animating ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

// MARK: 助手 Markdown（官方排版：代码块 12px 圆角 + 语言标签 + SF Mono；行内 code 浅灰底）

struct AssistantMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DSH.Metrics.itemSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .code(let lang, let code):
                    CodeBlockView(lang: lang, code: code)
                case .line(let line):
                    if !line.isEmpty {
                        richLine(line)
                            .font(.system(size: 16))
                            .lineSpacing(9)
                            .foregroundStyle(DSH.labelPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func richLine(_ line: String) -> some View {
        // 标题 / 列表 / 引用的简单增强
        if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4))).font(.system(size: 16, weight: .semibold))
        } else if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3))).font(.system(size: 18, weight: .semibold))
        } else if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2))).font(.system(size: 20, weight: .semibold))
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(DSH.labelSecondary)
                richText(String(line.dropFirst(2)))
            }
        } else if line.hasPrefix("> ") {
            richText(String(line.dropFirst(2)))
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(DSH.borderL2).frame(width: 2)
                }
        } else {
            richText(line)
        }
    }

    /// 行内 `code` 与 **bold** 富文本
    private func richText(_ line: String) -> Text {
        let ns = NSMutableAttributedString(
            string: line,
            attributes: [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        applyInlinePattern(ns, pattern: "`([^`]*)`") { range in
            ns.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 14.5, weight: .regular), range: range)
            ns.addAttribute(.backgroundColor, value: NSColor.controlBackgroundColor, range: range)
        }
        applyInlinePattern(ns, pattern: "\\*\\*([^*]+)\\*\\*") { range in
            ns.addAttribute(.font, value: NSFont.systemFont(ofSize: 16, weight: .semibold), range: range)
        }
        return Text(AttributedString(ns))
    }

    private func applyInlinePattern(_ ns: NSMutableAttributedString, pattern: String, apply: (NSRange) -> Void) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: ns.string, range: range) { match, _, _ in
            guard let match else { return }
            apply(match.range)
        }
    }

    enum Segment {
        case code(lang: String, code: String)
        case line(String)
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var code = ""
        var lang = ""
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(lang: lang, code: String(code.dropLast(1))))
                    code = ""; lang = ""; inCode = false
                } else {
                    lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode { code += line + "\n" } else { result.append(.line(line)) }
        }
        if inCode { result.append(.code(lang: lang, code: code)) }
        return result
    }
}

// MARK: 代码块（官方 ToolDetails .code：12px 圆角、16px 内边距、13px SF Mono、语言标签）

struct CodeBlockView: View {
    let lang: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !lang.isEmpty {
                HStack {
                    Text(lang)
                        .font(.system(size: 11))
                        .foregroundStyle(DSH.labelCaption)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(DSH.labelCaption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(7)
                    .foregroundStyle(DSH.labelPrimary)
                    .textSelection(.enabled)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DSH.codeBlockBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DSH.borderL1, lineWidth: 1)
        )
    }
}
