import UIKit
import UniformTypeIdentifiers
import UserNotifications
import WidgetKit

/// 分享扩展：出现在系统分享面板中（「发送到小助」），把用户从微信等任意 App
/// 分享过来的图片/文本/链接落入 App Group 中转区，随后立即关闭。
///
/// 关键约束：**扩展进程不直接读写 SwiftData**（规避多进程写库，见 `Persistence.swift`）。
/// 重活（Vision OCR、解析、落库）全部在主 App 回前台时由 `ShareInboxService` 完成。
/// 这里只负责采集与交接，并发出一条本地通知给用户即时反馈。
final class ShareViewController: UIViewController {

    /// 记录本次是否有内容成功写入中转区（跨并发回调访问，用锁保护）
    private final class WriteState {
        private let lock = NSLock()
        private var success = false
        func markSuccess() {
            lock.lock(); success = true; lock.unlock()
        }
        var anySuccess: Bool {
            lock.lock(); defer { lock.unlock() }; return success
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 扩展不留 UI，采集完即关；加一层极简背景避免闪现空白
        view.backgroundColor = .systemBackground
        handleSharedItems()
    }

    private func handleSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish()
            return
        }

        let group = DispatchGroup()
        let state = WriteState()

        for item in extensionItems {
            guard let providers = item.attachments else { continue }
            for provider in providers {
                if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { [state] object, _ in
                        defer { group.leave() }
                        guard let image = object as? UIImage,
                              let data = image.jpegData(compressionQuality: 0.85) else { return }
                        if ShareImportBridge.writeImage(data, source: "share_extension") {
                            state.markSuccess()
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [state] itemObject, _ in
                        defer { group.leave() }
                        guard let url = itemObject as? URL else { return }
                        if ShareImportBridge.writeText(url.absoluteString, kind: .url, source: "share_extension") {
                            state.markSuccess()
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier) { [state] itemObject, _ in
                        defer { group.leave() }
                        let text: String? = (itemObject as? String) ?? (itemObject as? NSAttributedString)?.string
                        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        if ShareImportBridge.writeText(text, kind: .text, source: "share_extension") {
                            state.markSuccess()
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            if state.anySuccess {
                ShareViewController.postReceivedNotification()
                WidgetCenter.shared.reloadAllTimelines()
            }
            self?.finish()
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    /// 即时反馈：内容已收到，下次打开小助自动记账/建待办。
    private static func postReceivedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "小助 · 已收到分享"
        content.body = "打开小助即自动记账或建待办"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
