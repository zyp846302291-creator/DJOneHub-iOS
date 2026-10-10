import AppKit
import SwiftUI

@MainActor
final class NotifierPanel {
    private let panel: NSPanel
    private var hostingView: NSHostingView<AnyView>?
    var contactStore: ContactStore?
    var appSettings: AppSettings?
    private var autoHideWorkItem: DispatchWorkItem?
    private var lastMeasuredSize: CGSize?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 286, height: 138),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        // macOS 26 对全透明窗口有渲染 bug，用接近不透明的 alpha 规避，
        // 视觉上仍保持透明圆角浮层效果（内容自带圆角与材质背景）。
        panel.backgroundColor = .white.withAlphaComponent(0.000001)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
    }

    func show(
        _ content: PanelContent,
        onReject: @escaping () -> Void,
        onAnswer: @escaping () -> Void,
        onOpen: @escaping () -> Void
    ) {
        autoHideWorkItem?.cancel()
        lastMeasuredSize = nil
        // 探测尺寸：给出最大宽度与充足高度，让 SwiftUI 按内容实际排版后再收敛到测量值。
        let probe: NSSize
        switch content {
        case .incoming:
            probe = NSSize(width: 320, height: 240)
        case .sms:
            probe = NSSize(width: 286, height: 60)
        case .missed, .error:
            probe = NSSize(width: 286, height: 76)
        case .idle:
            probe = NSSize(width: 286, height: 60)
        }
        let store = contactStore ?? ContactStore()
        // 弹窗外观跟随 App 的「外观」设置（浅色/深色/跟随系统），避免始终深色
        let root = AnyView(
            NotifierView(
                content: content,
                onReject: onReject,
                onAnswer: onAnswer,
                onOpen: onOpen,
                onSizeChange: { [weak self] size in
                    self?.applyMeasuredSize(size)
                }
            )
            .environmentObject(store)
            .preferredColorScheme(appSettings?.appearance.colorScheme)
        )
        switch appSettings?.appearance {
        case .light:
            panel.appearance = NSAppearance(named: .aqua)
        case .dark:
            panel.appearance = NSAppearance(named: .darkAqua)
        default:
            panel.appearance = nil
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: probe)
        hostingView.layoutSubtreeIfNeeded()
        self.hostingView = hostingView
        panel.contentView = hostingView
        let size = lastMeasuredSize.map {
            NSSize(width: ceil($0.width), height: ceil($0.height))
        } ?? probe
        panel.setContentSize(size)
        position(size: size)
        panel.orderFrontRegardless()

        if !content.isCall {
            let work = DispatchWorkItem { [weak self] in
                self?.hide()
            }
            autoHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        }
    }

    /// 用 SwiftUI 实际排版出的内容尺寸收敛弹窗大小，去掉固定高度留下的留白。
    private func applyMeasuredSize(_ size: CGSize) {
        guard size.width >= 40, size.height >= 24 else { return }
        let rounded = NSSize(width: ceil(size.width), height: ceil(size.height))
        lastMeasuredSize = rounded
        guard rounded != panel.frame.size else { return }
        panel.setContentSize(rounded)
        position(size: rounded)
    }

    func hide() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        panel.orderOut(nil)
    }

    func saveSnapshot(to url: URL) throws {
        guard let view = panel.contentView else {
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private func position(size: NSSize) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            return
        }
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}
