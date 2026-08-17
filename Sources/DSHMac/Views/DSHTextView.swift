import SwiftUI
import AppKit

// MARK: - 官方输入文本区（InputBar.module.css .input 精确复刻）
// padding 上4 左16 右12 下0 · 16px/24px 行高 · 光标品牌蓝 · 透明背景 · 高度由内容驱动（max 336）

struct DSHTextView: NSViewRepresentable {
    @Binding var text: String
    var font = NSFont.systemFont(ofSize: 16)
    var lineMultiple: CGFloat = 24.0        // 行高（pt）
    var minHeight: CGFloat = 28             // 官方单行 = 顶4 + 行24
    var maxHeight: CGFloat = 336
    var onEnter: ((Bool) -> Bool)? = nil    // 参数：⌘；返回 true=已处理（不插入换行）
    var onHeightChange: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(red: 0x41 / 255, green: 0x76 / 255, blue: 0xE6 / 255, alpha: 1) // deepseek-500
        textView.font = font
        textView.defaultParagraphStyle = Self.paragraphStyle(line: lineMultiple)
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        // 官方 .input 内容边距：上4 左16 右12 下0
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 16, bottom: 0, right: 12)

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.parent = self
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = font
        textView.insertionPointColor = NSColor(red: 0x41 / 255, green: 0x76 / 255, blue: 0xE6 / 255, alpha: 1)
        // 布局尺寸变化时重测高度（SwiftUI frame 驱动，视图自身不设高度约束）
        DispatchQueue.main.async {
            context.coordinator.measureAndReport()
        }
    }

    static func paragraphStyle(line: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = line
        p.maximumLineHeight = line
        return p
    }

    // MARK: Coordinator（文本同步 / 回车 / 高度上报）

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DSHTextView
        var textView: NSTextView?
        private var lastReported: CGFloat = 0

        init(_ parent: DSHTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            measureAndReport()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let command = NSEvent.modifierFlags.contains(.command)
                if parent.onEnter?(command) == true {
                    return true
                }
            }
            return false
        }

        /// 按当前可用宽度测文本高度，向 SwiftUI 上报（clamp 到官方 min/max）
        func measureAndReport() {
            guard let textView,
                  let container = textView.textContainer,
                  let manager = textView.layoutManager else { return }
            let scroll = textView.enclosingScrollView
            let available = max(0, (scroll?.frame.width ?? 0) - 16 - 12) // 左右内容边距
            guard available > 0 else { return }
            container.size = NSSize(width: available, height: .greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            let contentH = manager.usedRect(for: container).height
            let h = min(max(parent.minHeight, contentH), parent.maxHeight)
            if abs(h - lastReported) > 0.5 {
                lastReported = h
                parent.onHeightChange?(h)
            }
        }
    }
}
