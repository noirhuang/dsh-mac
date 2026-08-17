import SwiftUI
import AppKit

// MARK: - 官方 dsh Web UI 设计 tokens（design-platform.css）→ SwiftUI 动态色

/// 亮/暗双值动态色（跟随系统外观，与官方 body[data-ds-dark-theme] 切换一致）
func dshColor(light: UInt32, dark: UInt32, alphaL: Double = 1, alphaD: Double = 1) -> Color {
    let ns = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
        let (rgb, a) = isDark ? (dark, alphaD) : (light, alphaL)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
    }
    return Color(ns)
}

enum DSH {
    // ---- 静态色板（neutral-bluish 系 + deepseek 品牌系）----
    // 亮色值 / 暗色值 成对书写，来源 design-platform.css

    // 背景
    static let bgBase = dshColor(light: 0xFFFFFF, dark: 0x151517)                    // neutral-bluish-00 / 950
    static let sidebarFill = dshColor(light: 0xF9FAFB, dark: 0x1B1B1C)               // neutral-bluish-50 / 900
    static let bubble = dshColor(light: 0xEDF3FE, dark: 0x2C2C2E)                    // deepseek-50 / bluish-850
    static let inputMajor = dshColor(light: 0xFFFFFF, dark: 0x2C2C2E)                // 白 / bluish-850
    static let elevatedFill = dshColor(light: 0xFFFFFF, dark: 0x43454A)              // 新建按钮底（button-elevated）
    static let floatingFill = dshColor(light: 0xFFFFFF, dark: 0x2C2C2E)              // 悬浮按钮底
    static let codeBlockBg = dshColor(light: 0xF9FAFB, dark: 0x1B1B1C)               // markdown-code-block
    static let inlineCodeBg = dshColor(light: 0xEBEEF2, dark: 0x2C2C2E)              // markdown-inline-code

    // 品牌/状态
    static let businessPrimary = dshColor(light: 0x4176E6, dark: 0x679EFE)           // deepseek-500 / 400
    static let successPrimary = dshColor(light: 0x22C55E, dark: 0x22C55E)
    static let errorPrimary = dshColor(light: 0xEC1313, dark: 0xF25A5A)

    // 文字
    static let labelPrimary = dshColor(light: 0x0F1115, dark: 0xF9FAFB)              // bluish-1000 / 50
    static let labelSecondary = dshColor(light: 0x61666B, dark: 0xCFD3D6)            // bluish-700 / 300
    static let labelTertiary = dshColor(light: 0x81858C, dark: 0xADB2B8)             // bluish-600 / 400
    static let labelCaption = dshColor(light: 0xADB2B8, dark: 0x81858C)              // bluish-400 / 600

    // 边框与交互
    static let borderL1 = dshColor(light: 0x000000, dark: 0xFFFFFF, alphaL: 0.04, alphaD: 0.06)
    static let borderL2 = dshColor(light: 0x000000, dark: 0xFFFFFF, alphaL: 0.10, alphaD: 0.12)
    static let hoverBg = dshColor(light: 0x263148, dark: 0xFFFFFF, alphaL: 0.06, alphaD: 0.08)
    static let hoverBgSolid = dshColor(light: 0xF1F3F5, dark: 0x353538)              // bluish-75 / 800
    static let selectorFill = dshColor(light: 0xF9FAFB, dark: 0x353538)              // "+"附件钮底

    // ---- 几何 tokens（figma 规格）----
    enum Metrics {
        static let chatContentWidth: CGFloat = 748       // --dsh-chat-content-width
        static let composerExtra: CGFloat = 32           // 输入卡 = 内容宽 + 32
        static let bubbleRadius: CGFloat = 22
        static let cardRadius: CGFloat = 22
        static let buttonRadius: CGFloat = 12            // 新建会话钮
        static let rowRadius: CGFloat = 8                // 列表行
        static let sidebarDefaultWidth: CGFloat = 260
        static let sidebarRailWidth: CGFloat = 56
        static let newSessionHeight: CGFloat = 38
        static let logoRowHeight: CGFloat = 60
        static let projectRowHeight: CGFloat = 34
        static let sessionRowHeight: CGFloat = 32
        static let sendButtonSize: CGFloat = 34
        static let attachButtonSize: CGFloat = 28
        static let itemSpacing: CGFloat = 16             // 消息列间距（16px rhythm）
    }
}

// MARK: - 阴影（--dsw-shadow-lv2 等效）

struct DSHCardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
    }
}

extension View {
    func dshCardShadow() -> some View { modifier(DSHCardShadow()) }
}

// MARK: - Shimmer 扫光（turn 运行态文字，官方 1.8s 线性循环）

struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = 0

    var body: some View {
        let font = Font.system(size: 14, weight: .medium)
        Text(text)
            .font(font)
            .foregroundStyle(DSH.businessPrimary.opacity(0.5))
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, DSH.businessPrimary, .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * 0.7)
                        .offset(x: phase * geo.size.width * 1.7 - geo.size.width * 0.7)
                }
            }
            .mask(Text(text).font(font))
            .onAppear {
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - 思考行扫光（官方 reasoning-row-sweep 2.6s ease-out）

struct SweepOverlay: View {
    @State private var x: CGFloat = -300

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, DSH.bgBase.opacity(0.6), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 300)
            .offset(x: x)
            .onAppear {
                withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) {
                    x = geo.size.width
                }
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }
}
