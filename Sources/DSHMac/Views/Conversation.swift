import SwiftUI
import AppKit

// MARK: - 会话列（ConversationRoot + ChatView 复刻）：
// 头部 + 消息流 + composer 栈（QueueDock / TodoPanel / StatsLine / 审批 takeover / 输入卡）

struct ConversationColumn: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if let sid = app.currentSessionId {
                let store = app.store(for: sid)
                if store.items.isEmpty && store.title == nil {
                    // 官方：blank 会话呈现欢迎页（composer 常驻，模型/权限 chip 可用）
                    HeroEmptyState()
                } else {
                    VStack(spacing: 0) {
                        header(sessionId: sid)
                        ChatTranscript(sessionId: sid)
                    }
                }
            } else {
                HeroEmptyState()
            }
        }
        .frame(maxWidth: .infinity)   // 内容撑满列宽（否则按 ideal 宽 leading 对齐，右侧留白）
    }

    private func header(sessionId: String) -> some View {
        let store = app.store(for: sessionId)
        return HStack(spacing: 10) {
            if let cwd = store.cwd ?? app.sessions.first(where: { $0.sessionId == sessionId })?.cwd {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(DSH.labelTertiary)
                Text((cwd as NSString).lastPathComponent)
                    .font(.system(size: 14))
                    .foregroundStyle(DSH.labelTertiary)
                    .lineLimit(1)
            }
            Text(store.title ?? "新会话")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSH.labelPrimary)
                .lineLimit(1)
            Spacer()
            if store.running {
                HStack(spacing: 8) {
                    ShimmerText(text: "正在处理")
                    Button {
                        Task { await app.cancelTurn() }
                    } label: {
                        Text(L.t("停止", "Stop"))
                            .font(.system(size: 13))
                            .foregroundStyle(DSH.labelSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(DSH.hoverBg))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DSH.borderL2).frame(height: 1)
        }
    }
}

// MARK: - 消息流 + composer 栈

struct ChatTranscript: View {
    @EnvironmentObject private var app: AppState
    let sessionId: String

    @State private var columnWidth: CGFloat = 900   // 会话列实时宽（GeometryReader 驱动）

    var body: some View {
        let store = app.store(for: sessionId)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DSH.Metrics.itemSpacing) {
                        // 加载更早（官方 older 胶囊）
                        if store.hasMoreHistory {
                            HStack {
                                Spacer()
                                Button {
                                    Task { await app.loadOlder(session: sessionId) }
                                } label: {
                                    if store.loadingOlder {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Text(L.t("加载更早的消息", "Load earlier messages"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(DSH.labelSecondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(DSH.hoverBgSolid))
                                .disabled(store.loadingOlder)
                                Spacer()
                            }
                        }
                        ForEach(store.items) { item in
                            ChatItemView(item: item, sessionId: sessionId)
                                .frame(maxWidth: DSH.Metrics.chatContentWidth)
                                .frame(maxWidth: .infinity)
                                .id(item.id)
                        }
                        if store.running && !store.items.contains(where: \.streaming) {
                            HStack(spacing: 8) {
                                ShimmerText(text: "正在思考")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("thinking")
                        }
                    }
                    .frame(maxWidth: min(columnWidth - 64, DSH.Metrics.chatContentWidth))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                }
                .frame(maxWidth: .infinity)
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.items.count) { _, _ in
                    if let last = store.items.last {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: store.items.last?.streaming == true) { _, streaming in
                    if streaming, let last = store.items.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            // composer 栈（官方 composer stack：dock 卡片 + takeover + 输入卡）
            VStack(spacing: 6) {
                QueueDockView(sessionId: sessionId)
                TodoPanelView(sessionId: sessionId)
                StatsLineView(sessionId: sessionId)
                if let approval = app.pendingApproval, approval.sessionId == sessionId {
                    ApprovalTakeover(approval: approval)
                } else if let question = app.pendingQuestion, question.sessionId == sessionId {
                    QuestionTakeover(question: question)
                } else {
                    DSHInputBar(sessionId: sessionId)
                        .frame(width: min(columnWidth - 32, DSH.Metrics.chatContentWidth + DSH.Metrics.composerExtra))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(
                LinearGradient(colors: [DSH.bgBase.opacity(0), DSH.bgBase], startPoint: .top, endPoint: .bottom)
                    .frame(height: 36)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { columnWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in columnWidth = w }
            }
        )
        .sheet(item: $app.pendingApproval) { approval in
            // 兜底 sheet（非当前会话的审批）
            ApprovalSheet(approval: approval).frame(width: 460)
        }
        .sheet(item: $app.pendingQuestion) { question in
            QuestionSheet(question: question).frame(width: 520)
        }
    }
}

// MARK: - 队列条（官方 QueueDock：排队消息，可编辑/移除）

struct QueueDockView: View {
    @EnvironmentObject private var app: AppState
    let sessionId: String
    @State private var collapsed = true

    var body: some View {
        let store = app.store(for: sessionId)
        let queue = store.queuedItems.filter { $0.placement == "queued" }
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: 12))
                        .foregroundStyle(DSH.labelTertiary)
                    if queue.count == 1 {
                        Text("排队中：\(queue[0].text)")
                            .font(.system(size: 13))
                            .foregroundStyle(DSH.labelSecondary)
                            .lineLimit(1)
                    } else {
                        Button {
                            collapsed.toggle()
                        } label: {
                            Text("排队中 \(queue.count) 条消息\(collapsed ? "" : "  ▾")")
                                .font(.system(size: 13))
                                .foregroundStyle(DSH.labelSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if queue.count > 1 {
                        ForEach(queue.prefix(collapsed ? 2 : queue.count)) { item in
                            Button {
                                Task { await app.removeQueued(sessionId: sessionId, itemId: item.id) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DSH.labelTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("移除")
                        }
                    }
                }
                if !collapsed {
                    ForEach(queue) { item in
                        HStack {
                            Text(item.text)
                                .font(.system(size: 13))
                                .foregroundStyle(DSH.labelSecondary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                Task { await app.removeQueued(sessionId: sessionId, itemId: item.id) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(DSH.labelTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DSH.hoverBgSolid))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: DSH.Metrics.chatContentWidth + DSH.Metrics.composerExtra)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(DSH.elevatedFill))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DSH.borderL1, lineWidth: 1))
        }
    }
}

// MARK: - 计划条（官方 TodoPanel）

struct TodoPanelView: View {
    @EnvironmentObject private var app: AppState
    let sessionId: String
    @State private var expanded = false

    var body: some View {
        let store = app.store(for: sessionId)
        if !store.todos.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .font(.system(size: 12))
                            .foregroundStyle(DSH.labelTertiary)
                        Text("计划：\(store.todos.filter { $0.status == "completed" }.count)/\(store.todos.count) 完成")
                            .font(.system(size: 13))
                            .foregroundStyle(DSH.labelSecondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(DSH.labelTertiary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(store.todos) { todo in
                        HStack(spacing: 8) {
                            Image(systemName: todo.status == "completed" ? "checkmark.circle.fill" : (todo.status == "in-progress" ? "circle.dashed" : "circle"))
                                .font(.system(size: 12))
                                .foregroundStyle(todo.status == "completed" ? DSH.successPrimary : DSH.labelTertiary)
                            Text(todo.content)
                                .font(.system(size: 13))
                                .foregroundStyle(todo.status == "completed" ? DSH.labelTertiary : DSH.labelSecondary)
                                .strikethrough(todo.status == "completed")
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: DSH.Metrics.chatContentWidth + DSH.Metrics.composerExtra)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DSH.elevatedFill))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DSH.borderL1, lineWidth: 1))
        }
    }
}

// MARK: - 用量行（官方 StatsLine）

struct StatsLineView: View {
    @EnvironmentObject private var app: AppState
    let sessionId: String

    var body: some View {
        let store = app.store(for: sessionId)
        if !store.stats.isEmpty {
            Text(store.stats)
                .font(.system(size: 11))
                .foregroundStyle(DSH.labelCaption)
                .frame(maxWidth: DSH.Metrics.chatContentWidth + DSH.Metrics.composerExtra)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - 审批 takeover（官方 ApprovalPanel：琥珀条 + 理由 + 命令 + 拒绝/允许）

struct ApprovalTakeover: View {
    @EnvironmentObject private var app: AppState
    let approval: DSHApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: .systemOrange)).frame(width: 8, height: 8)
                Text(L.t("等待批准", "Waiting for approval"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
            Text(approval.toolName)
                .font(.system(size: 14))
                .foregroundStyle(DSH.labelPrimary)
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(DSH.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button {
                    Task { await app.resolveApproval(approval, allow: false) }
                } label: {
                    Text(L.t("拒绝", "Refuse"))
                        .font(.system(size: 14))
                        .foregroundStyle(DSH.labelPrimary)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Capsule().strokeBorder(DSH.borderL2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    Task { await app.resolveApproval(approval, allow: true) }
                } label: {
                    Text(L.t("允许", "Allow"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Capsule().fill(DSH.businessPrimary))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: DSH.Metrics.chatContentWidth + DSH.Metrics.composerExtra)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DSH.Metrics.cardRadius)
                .fill(DSH.inputMajor)
                .overlay(RoundedRectangle(cornerRadius: DSH.Metrics.cardRadius).strokeBorder(DSH.borderL2, lineWidth: 1))
        )
        .dshCardShadow()
    }
}

// MARK: - 提问 takeover（官方 QuestionComposer）

struct QuestionTakeover: View {
    @EnvironmentObject private var app: AppState
    let question: DSHQuestionRequest
    @State private var selections: [Int] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(DSH.labelSecondary)
                Text("Agent 需要你的回答")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSH.labelPrimary)
            }
            ForEach(Array(question.items.enumerated()), id: \.element.id) { qIndex, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.question)
                        .font(.system(size: 14))
                        .foregroundStyle(DSH.labelPrimary)
                    if item.options.count > 1 {
                        Picker("", selection: Binding(
                            get: { qIndex < selections.count ? max(selections[qIndex], 0) : 0 },
                            set: { if qIndex < selections.count { selections[qIndex] = $0 } }
                        )) {
                            ForEach(Array(item.options.enumerated()), id: \.offset) { oIndex, opt in
                                Text(opt.label).tag(oIndex)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    Task { await app.resolveQuestion(question, answers: selections) }
                } label: {
                    Text("提交回答")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Capsule().fill(DSH.businessPrimary))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: DSH.Metrics.chatContentWidth + DSH.Metrics.composerExtra)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DSH.Metrics.cardRadius)
                .fill(DSH.inputMajor)
                .overlay(RoundedRectangle(cornerRadius: DSH.Metrics.cardRadius).strokeBorder(DSH.borderL2, lineWidth: 1))
        )
        .dshCardShadow()
        .onAppear { selections = question.items.map { $0.options.first != nil ? 0 : -1 } }
    }
}

// MARK: - Hero 空状态（官方 EmptyHero：光晕 + 输入卡 + workspace chip）

struct HeroEmptyState: View {
    @EnvironmentObject private var app: AppState
    @AppStorage("dsh.lastWorkspace") private var lastWorkspace = ""

    var body: some View {
        ZStack {
            Ellipse()
                .fill(
                    RadialGradient(colors: [DSH.businessPrimary.opacity(0.14), DSH.businessPrimary.opacity(0)], center: .center, startRadius: 10, endRadius: 380)
                )
                .frame(width: 900, height: 420)
                .offset(y: 60)

            VStack(spacing: 0) {
                if app.connectionState == .connected {
                    VStack(spacing: 12) {
                        heroCard
                    }
                } else {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.regular)
                        Text(app.connectionState == .reconnecting ? "正在连接 dsh 服务…" : "正在启动 dsh 服务…")
                            .font(.system(size: 15))
                            .foregroundStyle(DSH.labelSecondary)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var heroCard: some View {
        VStack(spacing: 0) {
            Text(L.t("有什么可以帮忙？", "How can I help today?"))
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(DSH.labelPrimary)
                .padding(.bottom, 12)
            // 官方 HeroShell：workspace chip 行在输入卡上方（左对齐 padding-left 20）
            workspaceChip
                .frame(maxWidth: DSH.Metrics.chatContentWidth + DSH.Metrics.composerExtra)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)
                .padding(.bottom, 8)
            DSHInputBar(sessionId: app.currentSessionId, hero: true, defaultCwd: lastWorkspace.isEmpty ? NSHomeDirectory() : lastWorkspace)
                .frame(maxWidth: DSH.Metrics.chatContentWidth + DSH.Metrics.composerExtra)
        }
    }

    // 官方 workspace chip：文件夹 + 路径 + 下拉
    private var workspaceChip: some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.message = "选择新会话的工作目录"
            if panel.runModal() == .OK, let url = panel.url {
                lastWorkspace = url.path
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                Text(lastWorkspace.isEmpty ? "选择工作目录" : (lastWorkspace as NSString).lastPathComponent)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(DSH.labelSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(DSH.hoverBgSolid))
        }
        .buttonStyle(.plain)
    }
}
