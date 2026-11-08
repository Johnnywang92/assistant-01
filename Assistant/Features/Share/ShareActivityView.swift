/// 系统分享面板桥接。
///
/// **白屏根因**：`UIActivityViewController` 必须被 `present` 出来，
/// 不能被 SwiftUI 当成 `.sheet` 的内容控制器直接嵌入。旧实现把它作为
/// `UIViewControllerRepresentable` 的返回值交给 sheet，它内部的
/// presentation 会失败，用户看到的就是一片空白。
///
/// 现在返回一个透明宿主 VC，等它真正进入视图层级后主动 present 系统面板；
/// 面板关闭后再 dismiss 外层 SwiftUI sheet。项目里所有分享入口共用这一处。
import SwiftUI
import UIKit

struct ShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    @Environment(\.dismiss) private var dismiss

    init(activityItems: [Any]) {
        self.activityItems = activityItems
    }

    func makeUIViewController(context: Context) -> ShareActivityHostController {
        let host = ShareActivityHostController()
        host.items = activityItems
        host.onFinish = { [dismiss] in dismiss() }
        return host
    }

    func updateUIViewController(_ uiViewController: ShareActivityHostController, context: Context) {
        // 一次展示只 present 一次；items 已在 make 时注入。
    }
}

/// 透明宿主：自己不画任何内容，只负责把系统分享面板 present 出来。
final class ShareActivityHostController: UIViewController {
    var items: [Any] = []
    var onFinish: (() -> Void)?

    private var didPresent = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresent else { return }
        didPresent = true

        // 没有可分享内容时别留一个空白 sheet 在屏幕上。
        guard !items.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.onFinish?() }
            return
        }

        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad 上走 popover，缺锚点会直接抛异常。
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX,
            y: view.bounds.midY,
            width: 0,
            height: 0
        )
        activity.popoverPresentationController?.permittedArrowDirections = []
        activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
            DispatchQueue.main.async { self?.onFinish?() }
        }
        present(activity, animated: true)
    }
}
