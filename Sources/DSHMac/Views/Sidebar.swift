import SwiftUI

// MARK: - 官方侧栏（SidebarRoot + WorkspaceBrowser rows 复刻）

struct DSHSidebar: View {
    @EnvironmentObject private var app: AppState
    let collapsed: Bool
    let onToggle: () -> Void

    // workspace 分组（按 cwd 分组的树）
    private var groups: [(cwd: String, sessions: [DSHSessionSummary])] {
        Dictionary(grouping: app.sessions.filter { !$0.blank }) { $0.cwd ?? "默认目录" }
            .map { (cwd: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { $0.sessions.map(\.updatedAt).max() ?? 0 > $1.sessions.map(\.updatedAt).max() ?? 0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            logoRow
            if !collapsed {
                newSessionButton
                    .padding(.horizontal, 2)
                    .padding(.bottom, 8)
                sessionTree
            } else {
                Spacer()
            }
            Spacer(minLength: 0)
            footArea
        }
        .padding(.horizontal, collapsed ? 10 : 12)
        .padding(.vertical, 6)
        .foregroundStyle(DSH.labelPrimary)
        .font(.system(size: 14))
    }

    // ---- logo 行（60px，wordmark + 折叠钮）----
    private var logoRow: some View {
        HStack(spacing: 8) {
            if !collapsed {
                Button(action: { Task { await app.newSession(cwd: nil) } }) {
                    Text("DeepSeek")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DSH.labelPrimary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("新建会话")
                Spacer(minLength: 0)
                iconButton(symbol: "sidebar.leading") { onToggle() }
            } else {
                iconButton(symbol: "sidebar.left") { onToggle() }
            }
        }
        .frame(height: collapsed ? 36 : DSH.Metrics.logoRowHeight)
        .padding(.bottom, collapsed ? 12 : 8)
    }

    // ---- 新建会话按钮（38px，白底 1px 边框 12px 圆角）----
    private var newSessionButton: some View {
        Button {
            Task { await app.newSession(cwd: nil) }
        } label: {
            Group {
                if collapsed {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                        Text(L.t("新建会话", "New Session"))
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: collapsed ? 36 : DSH.Metrics.newSessionHeight)
            .background(
                RoundedRectangle(cornerRadius: DSH.Metrics.buttonRadius)
                    .fill(DSH.elevatedFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSH.Metrics.buttonRadius)
                            .strokeBorder(collapsed ? Color.clear : DSH.borderL2, lineWidth: 1)
                    )
            )
            .foregroundStyle(DSH.labelPrimary)
        }
        .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBgSolid))
        .disabled(app.connectionState != .connected)
    }

    // ---- 会话树（workspace 34px 行 + 会话 32px 行）----
    private var sessionTree: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.cwd) { group in
                    WorkspaceGroupRow(cwd: group.cwd, count: group.sessions.count)
                    ForEach(group.sessions) { session in
                        SessionListRow(
                            session: session,
                            selected: session.sessionId == app.currentSessionId
                        )
                    }
                }
                if groups.isEmpty && app.connectionState == .connected {
                    Text("暂无会话")
                        .font(.system(size: 13))
                        .foregroundStyle(DSH.labelTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                }
                if app.connectionState != .connected {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.horizontal")
                            .font(.system(size: 11))
                        Text(app.connectionState == .reconnecting ? "重连中…" : "连接中…")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(DSH.labelTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // ---- 底部（官方：设置入口）----
    private var footArea: some View {
        VStack(spacing: 0) {
            sideRow(symbol: "gearshape", label: L.t("设置", "Settings")) {
                app.showSettings = true
            }
        }
        .padding(.top, 4)
    }

    private func sideRow(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if collapsed {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .frame(width: 36, height: 36)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(DSH.labelSecondary)
                        Text(label)
                            .font(.system(size: 14))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                }
            }
            .background(RoundedRectangle(cornerRadius: DSH.Metrics.rowRadius).fill(Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: DSH.Metrics.rowRadius))
        }
        .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBg))
    }

    private func iconButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(DSH.labelSecondary)
                .frame(width: collapsed ? 36 : 28, height: collapsed ? 36 : 28)
                .background(Circle().fill(Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBg, shape: AnyShape(Circle())))
    }
}

// MARK: - workspace 分组行（34px，文件夹 + 名称 + 计数）

struct WorkspaceGroupRow: View {
    let cwd: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(DSH.labelTertiary)
                .frame(width: 16)
            Text((cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12))
                .foregroundStyle(DSH.labelTertiary)
        }
        .frame(height: DSH.Metrics.projectRowHeight)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - 会话行（32px：状态点 + 标题 + 时间，hover 时间变更多钮）

struct SessionListRow: View {
    @EnvironmentObject private var app: AppState
    let session: DSHSessionSummary
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            Task { await app.select(session: session.sessionId) }
        } label: {
            HStack(spacing: 0) {
                // 16px 状态槽
                ZStack {
                    if session.running {
                        Circle()
                            .fill(DSH.businessPrimary)
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(width: 16)

                Text(session.displayName)
                    .font(.system(size: 14))
                    .foregroundStyle(DSH.labelPrimary)
                    .lineLimit(1)
                    .padding(.leading, 4)
                    .padding(.trailing, 6)

                Spacer(minLength: 0)

                if hovering {
                    Menu {
                        Button("重命名…") { renameDialog() }
                        Button("刷新列表") { Task { await app.refreshSessions() } }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DSH.labelTertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Text(Self.relativeTime(session.updatedAt))
                        .font(.system(size: 12))
                        .foregroundStyle(DSH.labelTertiary)
                        .lineLimit(1)
                }
            }
            .frame(height: DSH.Metrics.sessionRowHeight)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: DSH.Metrics.rowRadius)
                    .fill(selected || hovering ? DSH.hoverBg : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DSH.Metrics.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("重命名…") { renameDialog() }
        }
    }

    private func renameDialog() {
        let alert = NSAlert()
        alert.messageText = "重命名会话"
        alert.informativeText = session.displayName
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = session.title ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty {
            Task { await app.rename(session: session.sessionId, title: input.stringValue) }
        }
    }

    /// 官方 relativeTime 分桶 + locales：`刚刚`/`X分钟`/`X小时`/`X天`/`X个月`/`X年`（紧凑，不带"前"）
    static func relativeTime(_ timestamp: Double) -> String {
        let minute = 60_000.0, hour = 3_600_000.0, day = 86_400_000.0
        let diff = max(0, Date().timeIntervalSince1970 * 1000 - timestamp)
        let en = L.language == "en"
        if diff < minute { return en ? "now" : "刚刚" }
        if diff < hour { let n = Int(diff / minute); return en ? "\(n)min" : "\(n)分钟" }
        if diff < day { let n = Int(diff / hour); return en ? "\(n)h" : "\(n)小时" }
        if diff < 30 * day { let n = Int(diff / day); return en ? "\(n)d" : "\(n)天" }
        if diff < 365 * day { let n = Int(diff / (30 * day)); return en ? "\(n)mo" : "\(n)个月" }
        let n = Int(diff / (365 * day)); return en ? "\(n)y" : "\(n)年"
    }
}

// MARK: - hover 按钮样式

struct HoverButtonStyle: ButtonStyle {
    var hoverFill: Color
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: DSH.Metrics.rowRadius))

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                HoverOverlay(shape: shape, fill: hoverFill)
            )
    }
}

struct HoverOverlay: View {
    let shape: AnyShape
    let fill: Color
    @State private var hovering = false

    var body: some View {
        shape
            .fill(hovering ? fill : Color.clear)
            .allowsHitTesting(false)
            .onHover { hovering = $0 }
    }
}

extension View {
    func onHoverMouse(_ f: @escaping (Bool) -> Void) -> some View { self }
}
