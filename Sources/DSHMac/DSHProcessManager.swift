import Foundation
import AppKit

// MARK: - dsh web 子进程管理（UDS 通讯 + 独立数据目录，崩溃自动重启）

@MainActor
public final class DSHProcessManager: ObservableObject {
    public struct Config {
        public var repoPath: String
        public var nodeBin: String
        public var shimPath: String
        /// App 数据目录（~/Library/Application Support/DeepSeek Harness）
        public var dataHome: String
        public var socketPath: String

        public init(repoPath: String, nodeBin: String, shimPath: String, dataHome: String, socketPath: String) {
            self.repoPath = repoPath
            self.nodeBin = nodeBin
            self.shimPath = shimPath
            self.dataHome = dataHome
            self.socketPath = socketPath
        }
    }

    @Published public private(set) var running = false
    @Published public private(set) var lastLines: [String] = []
    @Published public private(set) var ready = false
    @Published public private(set) var restartCount = 0

    public let config: Config
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var restartTimer: Timer?
    private var stopping = false
    public var onReady: (() -> Void)?

    public init(config: Config) {
        self.config = config
    }

    // MARK: 数据目录

    /// 标准数据目录：~/Library/Application Support/DeepSeek Harness（与 ~/.dsh 完全隔离）
    public static func defaultDataHome() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("DeepSeek Harness").path
    }

    public static func makeConfig(repoPath: String, nodeBin: String, shimPath: String) -> Config {
        let dataHome = defaultDataHome()
        try? FileManager.default.createDirectory(atPath: dataHome, withIntermediateDirectories: true)
        // socket 必须放在数据目录之外：dsh 会 watch DSH_HOME（chokidar 无法 watch socket 文件会崩溃）
        let socketPath = NSTemporaryDirectory() + "/dsh-mac.sock"
        return Config(repoPath: repoPath, nodeBin: nodeBin, shimPath: shimPath, dataHome: dataHome, socketPath: socketPath)
    }

    // MARK: 启动/停止

    public func start() {
        guard process == nil else { return }
        stopping = false
        ready = false

        let cliEntry = config.repoPath + "/apps/cli/lib/bin.js"
        guard FileManager.default.fileExists(atPath: cliEntry) else {
            appendLog("找不到 dsh CLI 构建产物: \(cliEntry)")
            return
        }
        guard FileManager.default.fileExists(atPath: config.shimPath) else {
            appendLog("找不到 UDS shim: \(config.shimPath)")
            return
        }
        // 清理残留 socket
        try? FileManager.default.removeItem(atPath: config.socketPath)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.nodeBin)
        p.arguments = ["--import", config.shimPath, cliEntry, "web", "--port", "3080"] // port 被 shim 重定向到 UDS
        // 关键隔离：数据目录独立、进程工作目录为用户主目录（agent 工具不再落到 .app 内）
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["DSH_HOME"] = config.dataHome
        env["DSH_SOCKET_PATH"] = config.socketPath
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                self?.handleTermination(reason: terminated.terminationReason)
            }
        }

        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                self?.ingest(text)
            }
        }

        do {
            try p.run()
            process = p
            stdoutPipe = pipe
            running = true
            appendLog("已启动后端（pid \(p.processIdentifier)，UDS \(config.socketPath)）")
            beginReadinessPolling()
        } catch {
            appendLog("启动失败: \(error.localizedDescription)")
        }
    }

    public func stop() {
        stopping = true
        restartTimer?.invalidate()
        restartTimer = nil
        if let p = process, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak p] in
                if let p, p.isRunning { p.interrupt() }
            }
        }
        process = nil
        running = false
        ready = false
    }

    public func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            start()
        }
    }

    // MARK: 就绪轮询（UDS API 探测）

    private func beginReadinessPolling() {
        let socketPath = config.socketPath
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if stopping || process == nil { return }
                if await DSHTransport.probe(socketPath: socketPath) {
                    await MainActor.run {
                        guard !stopping, process != nil else { return }
                        ready = true
                        appendLog("后端就绪（UDS）")
                        onReady?()
                    }
                    return
                }
            }
            await MainActor.run {
                appendLog("后端 30 秒内未就绪")
            }
        }
    }

    // MARK: 内部

    private func ingest(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            appendLog(String(line))
        }
    }

    private func handleTermination(reason: Process.TerminationReason) {
        process = nil
        running = false
        ready = false
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        guard !stopping else { return }
        restartCount += 1
        appendLog("进程退出（\(reason == .uncaughtSignal ? "异常信号" : "正常退出")），2 秒后自动重启（第 \(restartCount) 次）")
        restartTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.start() }
        }
    }

    private func appendLog(_ line: String) {
        lastLines.append(line)
        if lastLines.count > 300 { lastLines.removeFirst(lastLines.count - 300) }
        print("[dsh-proc] \(line)") // 诊断：同步到 stdout
    }
}
