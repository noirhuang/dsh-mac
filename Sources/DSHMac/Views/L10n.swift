import Foundation

// MARK: - 双语文案（内联式：L.t("中文", "English")；语言由设置-语言行驱动，默认 zh）

enum L {
    /// 当前语言（"zh" | "en"；AppState 启动时读 locale.preference 后设置）
    static var language: String = "zh"

    static func t(_ zh: String, _ en: String) -> String {
        language == "en" ? en : zh
    }
}
