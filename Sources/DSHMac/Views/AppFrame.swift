import SwiftUI

// MARK: - 官方三栏框架（AppFrame）：侧栏 | 会话区 | 详情（可隐藏），拖拽调宽

struct AppFrame: View {
    @EnvironmentObject private var app: AppState
    @AppStorage("dsh.sidebarWidth") private var sidebarWidth: Double = 280   // 官方 SIDEBAR_DEFAULT
    @AppStorage("dsh.sidebarCollapsed") private var sidebarCollapsed = false
    @State private var draggingSidebar = false
    @State private var viewportWidth: CGFloat = 1280
    @State private var narrowExpanded = false   // 官方语义：窄模式下的手动展开覆盖

    /// 官方 SIDEBAR_AUTO_COLLAPSE = 1024：窄视口自动折叠为 rail
    private var autoCollapse: Bool { viewportWidth < 1024 }
    private var effectiveCollapsed: Bool { autoCollapse ? !narrowExpanded : sidebarCollapsed }

    var body: some View {
        HStack(spacing: 0) {
            // 侧栏列（官方 sidebar-fill + 1px 右边框）
            DSHSidebar(collapsed: effectiveCollapsed, onToggle: {
                withAnimation(.easeInOut(duration: 0.22)) {
                    if autoCollapse {
                        narrowExpanded.toggle()   // 官方：窄视图的切换翻转手动展开覆盖
                    } else {
                        sidebarCollapsed.toggle()
                    }
                }
            })
            .frame(width: effectiveCollapsed ? DSH.Metrics.sidebarRailWidth : sidebarWidth)
            .background(DSH.sidebarFill)
            .overlay(alignment: .trailing) {
                Rectangle().fill(DSH.borderL1).frame(width: 1)
            }

            // 拖拽把手（折叠时隐藏；拖拽范围官方 SIDEBAR_MIN 264 - SIDEBAR_MAX 420）
            if !effectiveCollapsed {
                sidebarHandle
            }

            // 会话列
            ConversationColumn()
                .frame(maxWidth: .infinity)
                .background(DSH.bgBase)
        }
        .background(
            GeometryReader { g in
                Color.clear.onAppear { viewportWidth = g.size.width }
                    .onChange(of: g.size.width) { _, new in
                        viewportWidth = new
                        if new >= 1024 { narrowExpanded = false } // 回到宽视图清除覆盖
                    }
            }
        )
        .background(DSH.bgBase)
        .overlay(alignment: .top) {
            // 断连横幅（官方 ConnectionBanner）
            if app.connectionState == .reconnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(L.t("与服务连接中断，正在重连…", "Connection lost, reconnecting…"))
                        .font(.system(size: 13))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color(nsColor: .systemRed).opacity(0.92)))
                .dshCardShadow()
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(text: toast)
                    .padding(.bottom, 110)
                    .task {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        app.toast = nil
                    }
            }
        }
    }

    private var sidebarHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .cursor { NSCursor.resizeLeftRight }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        draggingSidebar = true
                        let w = sidebarWidth + value.translation.width
                        sidebarWidth = min(420, max(264, w))
                    }
                    .onEnded { _ in draggingSidebar = false }
            )
    }
}

// MARK: - 鼠标指针辅助

enum DSHCursor {
    static func resizeLeftRight() -> NSCursor { NSCursor.resizeLeftRight }
}

extension View {
    func cursor(_ cursor: @escaping () -> NSCursor) -> some View {
        onHover { inside in
            if inside { cursor().push() } else { NSCursor.pop() }
        }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(nsColor: .darkGray), in: Capsule())
            .dshCardShadow()
    }
}
