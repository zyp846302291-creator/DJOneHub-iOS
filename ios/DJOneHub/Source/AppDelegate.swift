import UIKit
import SwiftUI

/// 方向策略（屏幕比例判定，不依赖设备型号列表）：
/// - 折叠屏设备特征：同一物理设备存在两块屏——外屏"高瘦"（比例≈2.2+），
///   展开内屏"矮宽"（比例≈1.4）。常规手机无论怎么转都只有一种高宽形态。
/// - 判定逻辑：竖向拿持时比例 ≥2.18 视为折叠外屏（允许旋转）；
///   横向尺寸类为 regular 且比例 <2.0 视为展开内屏（允许旋转）；
///   其余（常规直板机 2.16~2.17）锁定竖屏；iPad 不限制。
final class OrientationLock: NSObject, UIApplicationDelegate {

    static let shared = OrientationLock()

    /// 常规直板 iPhone 的纵向比例集中在 2.16~2.17；折叠外屏更瘦（≥2.18）。
    /// 阈值 2.18 在常规机上限（2.174）之上留有缓冲。
    private static let foldableOuterRatio: CGFloat = 2.18

    private static func currentScreen() -> UIScreen? {
        // iOS 26+ UIScreen.main 非可选（弃用但仍可用）；scenes 兜底
        let main = UIScreen.main
        if main.nativeBounds.height > 0 {
            return main
        }
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first { $0.nativeBounds.height > 0 }
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // iPad 不限制
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }

        guard let screen = Self.currentScreen() else {
            return .portrait
        }
        let native = screen.nativeBounds
        guard native.width > 0 else { return .portrait }
        let ratio = CGFloat(native.height) / CGFloat(native.width)

        // 展开内屏：矮宽（≈1.4）且 regular——折叠屏专属形态，允许旋转
        if ratio < 2.0,
           window?.windowScene?.traitCollection.horizontalSizeClass == .regular {
            return .allButUpsideDown
        }

        // 折叠外屏：比常规机更瘦长（≥2.18）——允许旋转
        if ratio >= Self.foldableOuterRatio {
            return .allButUpsideDown
        }

        // 常规直板机：锁定竖屏
        return .portrait
    }
}
