import Foundation
import SwiftUI

// MARK: - 从源码一键更新：git fetch/reset（或 tarball 兜底）→ pnpm install → build

@MainActor
public final class SourceUpdater: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate(localSHA: String)
        case downloading
        case installingDependencies
        case building
        case restarting
        case done(newSHA: String)
        case failed(String)
    }

    @Published public var phase: Phase = .idle
    @Published public var logLines: [String] = []
    @Published public var localSHA: String = "?"

    public weak var appState: AppState?

    private var currentTask: Task<Void, Never>?

    public init() {}

    public var repoPath: String {
        appState?.processManager?.config.repoPath ?? ""
    }

    // MARK: 检查更新

    public func checkForUpdates() {
        guard currentTask == nil else { return }
        currentTask = Task { await runUpdate() }
    }

    /// 设置面板展示用的阶段描述
    public var phaseDescription: String {
        switch phase {
        case .idle: return "待机"
        case .checking: return "检查版本中…"
        case .downloading: return "下载源码…"
        case .installingDependencies: return "安装依赖…"
        case .building: return "构建中…"
        case .restarting: return "重启服务…"
        case .upToDate: return "已是最新"
        case .done: return "完成"
        case .failed: return "失败"
        }
    }

    private func runUpdate() async {
        phase = .checking
        appendLog("检查本地版本…")
        guard let sha = try? await git(["rev-parse", "HEAD"]) else {
            phase = .failed("无法读取本地 git 信息（\(repoPath)）")
            appendLog("失败：无法读取本地版本")
            finish()
            return
        }
        localSHA = String(sha.prefix(12))
        appendLog("本地 commit: \(localSHA)")

        appendLog("获取远端最新版本…")
        guard let remote = try? await git(["ls-remote", "origin", "-h", "refs/heads/master"]) else {
            appendLog("git 不可用或网络失败，改用 GitHub API…")
            await runUpdateViaAPI(local: sha)
            finish()
            return
        }
        let remoteSHA = remote.split(separator: "\t").first.map(String.init) ?? ""
        guard !remoteSHA.isEmpty else {
            phase = .failed("无法获取远端版本")
            finish()
            return
        }
        appendLog("远端 commit: \(String(remoteSHA.prefix(12)))")
        if remoteSHA == sha {
            phase = .upToDate(localSHA: localSHA)
            appendLog("已是最新版本 ✓")
            finish()
            return
        }

        // 有更新 → 拉取 + 构建
        phase = .downloading
        appendLog("拉取最新源码…")
        do {
            let _ = try await git(["fetch", "--depth", "1", "origin", "master"])
            let _ = try await git(["reset", "--hard", "FETCH_HEAD"])
            let _ = try await git(["clean", "-qfd", "-e", "node_modules"])
        } catch {
            phase = .failed("源码更新失败：\(error.localizedDescription)")
            finish()
            return
        }
        appendLog("源码已更新到 \(String(remoteSHA.prefix(12)))")

        await buildAndRestart(newSHA: remoteSHA)
        finish()
    }

    /// 无 git 兜底：用 GitHub API 查 SHA + codeload tarball 覆盖
    private func runUpdateViaAPI(local: String) async {
        guard
            let url = URL(string: "https://api.github.com/repos/deepseek-ai/deepseek-harness/commits/master"),
            let (data, _) = try? await URLSession.shared.data(from: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let remoteSHA = obj["sha"] as? String
        else {
            phase = .failed("无法查询远端版本（GitHub API）")
            return
        }
        if remoteSHA == local {
            phase = .upToDate(localSHA: String(local.prefix(12)))
            appendLog("已是最新版本 ✓")
            return
        }
        phase = .downloading
        appendLog("下载源码包…")
        let tmp = NSTemporaryDirectory() + "dsh-src-\(UUID().uuidString.prefix(8))"
        let tarball = tmp + ".tar.gz"
        guard
            let src = URL(string: "https://codeload.github.com/deepseek-ai/deepseek-harness/tar.gz/refs/heads/master"),
            let (tarData, _) = try? await URLSession.shared.data(from: src)
        else {
            phase = .failed("源码包下载失败")
            return
        }
        do {
            try tarData.write(to: URL(fileURLWithPath: tarball))
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            // 解压并 rsync 覆盖（保留 node_modules 与用户 patch）
            let untar = Process()
            untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            untar.arguments = ["-xzf", tarball, "-C", tmp]
            try untar.run(); untar.waitUntilExit()
            guard untar.terminationStatus == 0 else {
                phase = .failed("解压失败"); return
            }
            let extracted: String
            let contents = try FileManager.default.contentsOfDirectory(atPath: tmp)
            extracted = tmp + "/" + (contents.first ?? "")
            guard extracted != tmp + "/" else { phase = .failed("解压内容异常"); return }

            let rsync = Process()
            rsync.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
            rsync.arguments = ["-a", "--delete", "--exclude", "node_modules", "--exclude", ".git", extracted + "/", repoPath + "/"]
            try rsync.run(); rsync.waitUntilExit()
            guard rsync.terminationStatus == 0 else {
                phase = .failed("覆盖源码失败"); return
            }
            // 记录新 SHA（无 .git 时写入文件）
            try remoteSHA.write(toFile: repoPath + "/.source-sha", atomically: true, encoding: .utf8)
            appendLog("源码已更新到 \(String(remoteSHA.prefix(12)))")
            try? FileManager.default.removeItem(atPath: tmp)
            try? FileManager.default.removeItem(atPath: tarball)
        } catch {
            phase = .failed("更新失败：\(error.localizedDescription)")
            return
        }
        await buildAndRestart(newSHA: remoteSHA)
    }

    // MARK: 构建与重启

    private func buildAndRestart(newSHA: String) async {
        let fm = FileManager.default
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL

        // pnpm 优先用内置；否则 PATH
        let bundledPnpm = resources.appendingPathComponent("pnpm/pnpm").path
        let pnpmBin = fm.isExecutableFile(atPath: bundledPnpm) ? bundledPnpm : "/opt/homebrew/bin/pnpm"
        guard fm.isExecutableFile(atPath: pnpmBin) else {
            phase = .failed("找不到 pnpm（\(pnpmBin)）")
            return
        }

        phase = .installingDependencies
        appendLog("安装依赖（pnpm install）…")
        let install = await runProcess(pnpmBin, ["install", "--frozen-lockfile"], cwd: repoPath)
        appendLog(install.output)
        if install.status != 0 {
            // lockfile 漂移时回退普通 install
            appendLog("frozen-lockfile 失败，重试普通 install…")
            let retry = await runProcess(pnpmBin, ["install"], cwd: repoPath)
            appendLog(retry.output)
            guard retry.status == 0 else {
                phase = .failed("依赖安装失败"); return
            }
        }

        phase = .building
        appendLog("构建（pnpm run build）…")
        let build = await runProcess(pnpmBin, ["run", "build"], cwd: repoPath)
        appendLog(build.output)
        guard build.status == 0 else {
            phase = .failed("构建失败（旧版本仍可继续使用）"); return
        }

        phase = .restarting
        appendLog("重启后端服务…")
        appState?.processManager?.restart()

        // 更新改写了 .app 内容，重新 ad-hoc 签名（否则 Finder 双击会被 Gatekeeper 拦截）
        appendLog("重新签名应用…")
        let appPath = Bundle.main.bundleURL.path
        let resign = await runProcess("/usr/bin/codesign", ["--force", "--sign", "-", "--deep", appPath], cwd: "/")
        appendLog(resign.output.isEmpty ? "签名完成" : resign.output)

        // 等待服务就绪
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let socketPath = appState?.processManager?.config.socketPath,
               await DSHTransport.probe(socketPath: socketPath) {
                break
            }
        }
        phase = .done(newSHA: String(newSHA.prefix(12)))
        appendLog("更新完成 ✓ 已切换到 \(String(newSHA.prefix(12)))")
    }

    // MARK: 工具

    private func git(_ args: [String]) async throws -> String {
        guard FileManager.default.fileExists(atPath: repoPath + "/.git") else {
            throw DSHRpcError(code: "internal", message: "no .git")
        }
        let result = await runProcess("/usr/bin/git", args, cwd: repoPath)
        guard result.status == 0 else {
            throw DSHRpcError(code: "internal", message: "git \(args.first ?? "") failed: \(result.output.suffix(300))")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runProcess(_ bin: String, _ args: [String], cwd: String) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            p.environment = ProcessInfo.processInfo.environment
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { term in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                cont.resume(returning: (term.terminationStatus, out))
            }
            do {
                try p.run()
            } catch {
                cont.resume(returning: (-1, "启动失败: \(error.localizedDescription)"))
            }
        }
    }

    private func appendLog(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logLines.append("[\(stamp)] \(line)")
    }

    private func finish() {
        currentTask = nil
    }
}

public extension Notification.Name {
    static let dshShowUpdateWindow = Notification.Name("dshShowUpdateWindow")
}
