import SwiftUI
import AppKit

// MARK: - 官方输入卡（InputBar 精确复刻）
// 22px 圆角白卡 · 文本区（官方 inset 4/16/12/0、16px/24px、品牌蓝光标、max 336）
// 工具行：左（+ 附件、权限盾牌 chip）｜右（模型 chip、34px 蓝发送钮）

struct PendingImage: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let mediaType: String   // image/png 等
    let data: Data          // 原始字节（发送时 base64）
    let nsImage: NSImage
}

struct DSHInputBar: View {
    @EnvironmentObject private var app: AppState
    let sessionId: String?
    var hero = false
    /// hero 模式新建会话使用的默认工作目录
    var defaultCwd: String = ""

    @State private var draft = ""
    @State private var confirmFullAccess = false
    @State private var pendingImages: [PendingImage] = []

    var body: some View {
        card
    }

    private var card: some View {
        VStack(spacing: 12) {
            if !pendingImages.isEmpty {
                attachmentsRail
            }
            textArea
            toolbar
        }
        .padding(.top, 10)
        .frame(maxWidth: DSH.Metrics.chatContentWidth + DSH.Metrics.composerExtra)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DSH.Metrics.cardRadius)
                .fill(DSH.inputMajor)
                .overlay(
                    RoundedRectangle(cornerRadius: DSH.Metrics.cardRadius)
                        .strokeBorder(DSH.borderL2, lineWidth: 1)
                )
        )
        .dshCardShadow()
    }

    // ---- 文本区（DSHTextView：官方 padding/行高/光标；高度由内容测量驱动）----
    @State private var textHeight: CGFloat = 28

    private var minTextHeight: CGFloat { hero ? 52 : 28 }   // 官方 hero 两行底 52

    private var textArea: some View {
        ZStack(alignment: .topLeading) {
            DSHTextView(
                text: $draft,
                font: NSFont.systemFont(ofSize: 16),
                lineMultiple: 24,
                minHeight: minTextHeight,
                maxHeight: 336,
                onEnter: { command in
                    if NSEvent.modifierFlags.contains(.shift) {
                        return false // Shift+Enter 换行
                    }
                    send(command: command)
                    return true
                },
                onHeightChange: { h in
                    textHeight = h
                }
            )
            .frame(maxWidth: .infinity)   // 文本区撑满卡宽（NSViewRepresentable 无固有宽度，必须显式声明）
            .frame(height: max(minTextHeight, min(textHeight, 336)))

            if draft.isEmpty {
                Text(placeholder)
                    .font(.system(size: 16))
                    .foregroundStyle(DSH.labelCaption)
                    .padding(.top, 4)
                    .padding(.leading, 16)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var placeholder: String {
        app.connectionState == .connected ? L.t("给 DeepSeek 发送消息…", "Message DeepSeek…") : L.t("等待连接…", "Waiting for connection…")
    }

    // ---- 工具行（官方：tools 左 | trailing 右=模型+发送）----
    private var toolbar: some View {
        HStack(spacing: 12) {
            // 左：附件 +（28px 圆，selector 底；官方 imageLimits：png/jpeg/webp/gif、单张≤5MB、≤20张）
            Button {
                pickImages()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DSH.labelPrimary)
                    .frame(width: DSH.Metrics.attachButtonSize, height: DSH.Metrics.attachButtonSize)
                    .background(Circle().fill(DSH.selectorFill))
            }
            .buttonStyle(HoverButtonStyle(hoverFill: DSH.hoverBgSolid, shape: AnyShape(Circle())))
            .help(L.t("添加图片", "Add images"))

            // 左：权限预设盾牌 chip（28px 胶囊）
            if let sid = sessionId, let store = app.storesStorage[sid], !store.permissions.options.isEmpty {
                permissionChip(store: store)
            }

            Spacer(minLength: 0)

            // 右：模型 chip（官方 trailing 位）
            if let sid = sessionId, let store = app.storesStorage[sid], let catalog = store.models {
                ModelSeat(sessionId: sid, catalog: catalog)
            }

            // 右：发送钮（34px 圆，info 蓝，白箭头，空文 0.4）
            sendButton
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .confirmationDialog(
            L.t("Full access 会让新会话减少确认步骤并直接执行更多操作（含敏感操作、文件修改、外部命令）。仅在信任后续任务时使用。",
                "Full access lets new sessions perform more actions directly, including sensitive operations. Only use it when you trust subsequent tasks."),
            isPresented: $confirmFullAccess, titleVisibility: .visible
        ) {
            Button(L.t("仍然切换到 Full access", "Switch to Full access anyway"), role: .destructive) {
                Task { await app.selectPermission("danger-full-access") }
            }
            Button(L.t("取消", "Cancel"), role: .cancel) {}
        }
    }

    /// 权限预设 chip（盾牌 + 名称 + chevron，28px 胶囊；切换走官方 /permission 命令）
    private func permissionChip(store: SessionStore) -> some View {
        let current = store.permissions.current
        let currentName = store.permissions.options.first { $0.value == current }?.name ?? (current.isEmpty ? L.t("权限", "Permission") : current)
        return Menu {
            ForEach(store.permissions.options, id: \.value) { option in
                Button {
                    if option.value == "danger-full-access" && option.value != current {
                        confirmFullAccess = true
                    } else {
                        Task { await app.selectPermission(option.value) }
                    }
                } label: {
                    if option.value == current {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: shieldSymbol(current))
                    .font(.system(size: 11))
                    .foregroundStyle(DSH.labelSecondary)
                Text(currentName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DSH.labelSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DSH.labelCaption)
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 28)
            .background(Capsule().fill(Color.clear))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(HoverOverlay(shape: AnyShape(Capsule()), fill: DSH.hoverBg))
        .help(L.t("权限预设", "Permission preset"))
    }

    private func shieldSymbol(_ preset: String) -> String {
        switch preset {
        case "read-only": return "checkmark.shield"
        case "danger-full-access": return "exclamationmark.shield"
        default: return "pencil.and.shield.righthalf.filled"
        }
    }

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // ---- 发送钮 ----
    private var sendButton: some View {
        Button {
            send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: DSH.Metrics.sendButtonSize, height: DSH.Metrics.sendButtonSize)
                .background(Circle().fill(DSH.businessPrimary))
                .offset(y: -2)
        }
        .buttonStyle(.plain)
        .opacity(canSend ? 1 : 0.4)
        .disabled(!canSend)
        .help(L.t("发送 (Enter)", "Send (Enter)"))
    }

    private var canSend: Bool {
        (hasText || !pendingImages.isEmpty) && app.connectionState == .connected
    }

    private func send(command: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasText || !pendingImages.isEmpty, app.connectionState == .connected else { return }
        draft = ""
        Task {
            var sid = sessionId
            if sid == nil {
                await app.newSession(cwd: defaultCwd.isEmpty ? nil : defaultCwd)
                sid = app.currentSessionId
            }
            guard let sid else { return }
            // 官方 busyEnter：仅运行中生效（queue/steer），⌘Enter 使用另一行为
            let running = app.storesStorage[sid]?.running ?? false
            var mode = "queue"
            if running {
                let base = app.busyEnter == "steer" ? "steer" : "queue"
                mode = command ? (base == "steer" ? "queue" : "steer") : base
            }
            if pendingImages.isEmpty {
                await app.sendPrompt(text, mode: mode)
            } else {
                await sendWithImages(text: text, sessionId: sid, mode: mode)
            }
        }
    }
}

// MARK: - 输入卡扩展：图片附件（选图 / 校验 / 缩略图行 / 带图发送）

extension DSHInputBar {
    /// 官方 imageLimits（实测投影）：PNG/JPEG/WebP/GIF、单张 ≤5MB、每条 ≤20 张
    static let attachmentMediaTypes: [String] = ["public.png", "public.jpeg", "org.webm.project.webp", "com.compuserve.gif"]
    static let maxImageBytes = 5 * 1024 * 1024
    static let maxImagesPerMessage = 20

    func pickImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .webP, .gif]
        panel.message = L.t("选择图片（PNG/JPEG/WebP/GIF，单张 ≤5MB）", "Choose images (PNG/JPEG/WebP/GIF, ≤5MB each)")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        for url in panel.urls {
            addImage(url: url)
        }
    }

    func addImage(url: URL) {
        guard pendingImages.count < Self.maxImagesPerMessage else {
            app.toast = L.t("每条消息最多 20 张图片", "At most 20 images per message")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            app.toast = L.t("无法读取文件", "Cannot read file")
            return
        }
        guard data.count <= Self.maxImageBytes else {
            app.toast = L.t("\(url.lastPathComponent) 超过 5MB", "\(url.lastPathComponent) exceeds 5MB")
            return
        }
        let ext = url.pathExtension.lowercased()
        let mediaType: String
        switch ext {
        case "png": mediaType = "image/png"
        case "jpg", "jpeg": mediaType = "image/jpeg"
        case "webp": mediaType = "image/webp"
        case "gif": mediaType = "image/gif"
        default: mediaType = "image/png"
        }
        guard let nsImage = NSImage(data: data) else {
            app.toast = L.t("不支持的图片格式", "Unsupported image format")
            return
        }
        pendingImages.append(PendingImage(url: url, mediaType: mediaType, data: data, nsImage: nsImage))
    }

    /// 官方 attachments rail：横向滚动缩略图 + 删除
    var attachmentsRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { img in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: img.nsImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DSH.borderL2, lineWidth: 1))
                        Button {
                            pendingImages.removeAll { $0.id == img.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white, Color(nsColor: .black).opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                    }
                    .help(img.url.lastPathComponent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 带图发送：content = [文本?, 图片...]
    func sendWithImages(text: String, sessionId: String, mode: String) async {
        var content: [JSONValue] = []
        if !text.isEmpty {
            content.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        for img in pendingImages {
            content.append(.object([
                "type": .string("image"),
                "mediaType": .string(img.mediaType),
                "data": .string(img.data.base64EncodedString()),
                "name": .string(img.url.lastPathComponent),
            ]))
        }
        guard !content.isEmpty else { return }
        pendingImages = []
        await app.sendPromptContent(sessionId: sessionId, mode: mode, content: content)
    }
}
