import SwiftUI
import AppKit

// MARK: - 更新窗口 + 日志窗口（辅助 UI）

final class LogWindowController: NSWindowController {
    static let shared = LogWindowController()
    private var hostingView: NSView?

    func show(processManager: DSHProcessManager?) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            w.title = "dsh 服务日志"
            w.isReleasedWhenClosed = false
            self.window = w
        }
        if let pm = processManager {
            let view = NSHostingView(rootView: LogView().environmentObject(pm))
            window?.contentView = view
            hostingView = view
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct LogView: View {
    @EnvironmentObject private var pm: DSHProcessManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(pm.lastLines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("log-end")
            }
            .onChange(of: pm.lastLines.count) { _, _ in
                proxy.scrollTo("log-end", anchor: .bottom)
            }
        }
        .background(Color.black.opacity(0.85))
        .foregroundStyle(.green)
    }
}

struct UpdateView: View {
    @EnvironmentObject private var updater: SourceUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text("从源码更新").font(.headline)
                    Text("本地 commit: \(updater.localSHA)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                phaseBadge
            }

            Divider()

            phaseList

            Divider()

            ScrollView {
                Text(updater.logLines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 180)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                switch updater.phase {
                case .idle, .upToDate, .done, .failed:
                    Button("关闭") {
                        NSApp.windows.first { $0.title == "从源码更新" }?.close()
                    }
                    .keyboardShortcut(.defaultAction)
                default:
                    Button("取消") {}.disabled(true).opacity(0)
                    ProgressView().controlSize(.small)
                        .help("更新进行中，请勿关闭")
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch updater.phase {
        case .idle:
            Text("待机").foregroundStyle(.secondary)
        case .checking:
            Label("检查中…", systemImage: "magnifyingglass").foregroundStyle(.orange)
        case .upToDate:
            Label("已是最新", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .downloading, .installingDependencies, .building, .restarting:
            Label("更新中…", systemImage: "arrow.down.circle").foregroundStyle(.orange)
        case .done(let sha):
            Label("已更新到 \(sha)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed(let reason):
            VStack(alignment: .trailing) {
                Label("失败", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var phaseList: some View {
        let steps: [(String, SourceUpdater.Phase)] = [
            ("检查版本", .checking),
            ("下载源码", .downloading),
            ("安装依赖", .installingDependencies),
            ("构建", .building),
            ("重启服务", .restarting),
        ]
        let currentOrder: Int
        switch updater.phase {
        case .checking: currentOrder = 0
        case .downloading: currentOrder = 1
        case .installingDependencies: currentOrder = 2
        case .building: currentOrder = 3
        case .restarting: currentOrder = 4
        case .done: currentOrder = 5
        default: currentOrder = -1
        }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                HStack(spacing: 8) {
                    Image(systemName: idx < currentOrder ? "checkmark.circle.fill" : (idx == currentOrder ? "arrow.right.circle.fill" : "circle.dotted"))
                        .foregroundStyle(idx < currentOrder ? .green : (idx == currentOrder ? .orange : .secondary))
                    Text(step.0)
                        .foregroundStyle(idx <= currentOrder ? .primary : .secondary)
                }
                .font(.callout)
            }
        }
    }
}

/// 更新窗口控制器（由菜单触发的通知展示）
final class UpdateWindowController: NSWindowController {
    static let shared = UpdateWindowController()
    private var updater: SourceUpdater?
    private var observer: Any?

    func installHook(updater: SourceUpdater) {
        self.updater = updater
        observer = NotificationCenter.default.addObserver(
            forName: .dshShowUpdateWindow, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let updater = self.updater else { return }
            self.show(updater: updater)
        }
    }

    func show(updater: SourceUpdater) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            w.title = "从源码更新"
            w.isReleasedWhenClosed = false
            self.window = w
        }
        window?.contentView = NSHostingView(rootView: UpdateView().environmentObject(updater))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
