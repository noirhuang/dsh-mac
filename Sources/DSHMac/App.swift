import SwiftUI

@main
struct DSHMacApp: App {
    @StateObject private var app = AppState()
    @StateObject private var updater = SourceUpdater()

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var colorScheme: ColorScheme? {
        switch app.preferredColorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil // 跟随系统
        }
    }

    var body: some Scene {
        WindowGroup {
            AppFrame()
                .environmentObject(app)
                .environmentObject(updater)
                .frame(minWidth: 900, minHeight: 620)
                .preferredColorScheme(colorScheme)
                .sheet(isPresented: $app.showSettings) {
                    SettingsPanel()
                        .environmentObject(app)
                        .environmentObject(updater)
                }
                .sheet(isPresented: $app.showOnboardingWelcome) {
                    OnboardingWelcomeSheet()
                        .environmentObject(app)
                }
                .sheet(isPresented: $app.showOnboardingKey) {
                    OnboardingKeySheet()
                        .environmentObject(app)
                }
                .onAppear {
                    appDelegate.appState = app
                    appDelegate.updater = updater
                    updater.appState = app
                    app.updaterBridge = updater
                    Task { await app.bootstrap() }
                    // 调试：--screenshot <path> [--settings [section]] 渲染后截取自身窗口
                    let args = CommandLine.arguments
                    if let idx = args.firstIndex(of: "--screenshot"), idx + 1 < args.count {
                        let outPath = args[idx + 1]
                        var withSettings: String? = nil
                        if let sIdx = args.firstIndex(of: "--settings") {
                            let next = sIdx + 1 < args.count ? args[sIdx + 1] : ""
                            withSettings = (next.hasPrefix("--") || sIdx + 1 == idx || next.isEmpty) ? "general" : next
                        }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            if let section = withSettings {
                                app.showSettings = true
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                app.screenshotSettingsSection = section
                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                            }
                            Self.captureMainWindow(to: outPath)
                            NSApp.terminate(nil)
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("设置…") { app.showSettings = true }
                    .keyboardShortcut(",", modifiers: [.command])
                Button("重启后端服务") { app.processManager?.restart() }
                Button("打开服务日志") { LogWindowController.shared.show(processManager: app.processManager) }
            }
            CommandGroup(after: .newItem) {
                Button("新建会话") { Task { await app.newSession(cwd: nil) } }
                    .keyboardShortcut("N", modifiers: [.command])
            }
        }
    }
    /// 截取自身主窗口（CGWindowListCreateImage 对本进程窗口无需屏幕录制权限）
    static func captureMainWindow(to path: String) {
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            print("[screenshot] 无法枚举窗口")
            return
        }
        var winID: Int?
        for w in list {
            let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            if pid == myPID && layer == 0 {
                winID = w[kCGWindowNumber as String] as? Int
                break
            }
        }
        guard let id = winID else { print("[screenshot] 找不到自身窗口"); return }
        guard let image = CGWindowListCreateImage(.null, .optionOnScreenBelowWindow, CGWindowID(id), [.boundsIgnoreFraming, .bestResolution]) else {
            print("[screenshot] 截图失败")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("[screenshot] 已保存 \(path)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    weak var updater: SourceUpdater?
    static var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
    }
}
