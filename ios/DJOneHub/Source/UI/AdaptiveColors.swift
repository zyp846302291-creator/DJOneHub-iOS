import SwiftUI

// MARK: - Adaptive Colors (跟随系统浅色/深色模式自动切换)

extension Color {
    /// 主背景色：浅色模式白色，深色模式黑色
    static let appBackground = Color(UIColor.systemBackground)

    /// 二级背景色：卡片/列表区域
    static let appCard = Color(UIColor.secondarySystemGroupedBackground)

    /// 卡片背景带半透明（保留深色风格一致性）
    static let appCardOpaque = Color(UIColor.systemGray6)

    /// 一级文字色
    static let appPrimary = Color(UIColor.label)

    /// 二级文字色
    static let appSecondary = Color(UIColor.secondaryLabel)

    /// 三级文字色
    static let appTertiary = Color(UIColor.tertiaryLabel)

    /// 分隔线
    static let appSeparator = Color(UIColor.separator)

    /// 系统灰色背景
    static let appFill = Color(UIColor.systemFill)
}

// MARK: - Environment-aware modifier for dial pad (always dark)

struct AlwaysDarkBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.black.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func alwaysDark() -> some View {
        modifier(AlwaysDarkBackground())
    }
}