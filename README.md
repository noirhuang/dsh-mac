# DSHMac — DeepSeek Harness 原生 macOS 客户端

完全原生（SwiftUI/AppKit，零 WebView）的 [deepseek-harness (dsh)](https://github.com/deepseek-ai/deepseek-harness) 桌面客户端，内置 Node 运行时与源码，支持应用内一键从源码更新。

## 功能

- **原生界面**：会话侧栏（新建/切换/重命名/自动标题）、流式聊天（思考过程折叠、代码块高亮）、工具调用卡片（参数/输出）、权限审批弹窗、Agent 提问弹窗、模型/推理力度选择
- **自带运行时**：.app 内置 Node 24 + pnpm 11.7 + 完整 dsh 源码（已构建），双击即用
- **从源码更新**：菜单 `⌘U 检查更新（从源码）` → git 拉取最新 master → pnpm install → 重新构建 → 自动重启服务；无 git 环境自动回退 GitHub tarball；失败保留旧版可用
- **进程自治**：后端崩溃自动重启；端口占用自动改用随机端口

## 产物

| 文件 | 说明 |
|---|---|
| `dist/DeepSeek Harness.app` | 应用本体（ad-hoc 签名，首次打开需右键→打开） |
| `dist/DeepSeek-Harness-mac-arm64.dmg` | 分发镜像（Apple Silicon） |

## 构建与开发

```bash
# 一次性：准备源码（仓库需已 pnpm install + pnpm run build）
git clone --depth 1 https://github.com/deepseek-ai/deepseek-harness ../deepseek-harness

# 开发运行（连接本机 3080 已有服务，或自动拉起）
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run

# 完整打包（release 编译 + 内置 Node/pnpm/源码 + 签名 + DMG）
./scripts/bundle-app.sh
```

> **SDK 说明**：macOS 27 SDK 将 SwiftUI `@State` 等实现为宏且宏插件仅随完整 Xcode 分发；CLT 环境需用 `MacOSX26.5.sdk`（`SDKROOT` 指定）编译，产物在新系统上正常运行。装有完整 Xcode 的机器无需此设置。

## 架构

```
SwiftUI 视图层
  ├─ AppState（@MainActor）：连接/会话/审批/问题路由
  ├─ SessionStore：SessionEvent fold → 聊天条目（流式 chunk 转正、工具卡片配对）
  ├─ DSHTransport（actor）：POST /api/<method>（四象限信封）+ 双 WS 事件流 + 指数退避重连
  ├─ DSHProcessManager：spawn 内置 node 跑 repo 的 dsh web，stdout 解析端口
  └─ SourceUpdater：SHA 比对 → git/tarball 更新 → pnpm install → build → 重启
.app/Contents/Resources/{node, pnpm, repo, SOURCE_VERSION}
```

通信协议即 dsh Web UI 同款（HTTP 单向调用 + `events.mux`/`events.host` 两条只下行 WebSocket），wire 模型见 `Sources/DSHMac/Client/DSHWire.swift`，协议细节集中在 `Client/` 目录，上游协议变更时只需调整该层。

## 数据与凭据

后端使用默认 `~/.dsh`（与 CLI / 浏览器版共享：会话、凭据、插件配置）。API key 在 dsh 的设置体系（`settings`/`credentials` API）或首次对话时配置。
