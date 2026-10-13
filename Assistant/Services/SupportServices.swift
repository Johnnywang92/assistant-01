import AssistantCore
import Foundation
import SwiftData
import UserNotifications

/// 收件箱文件补录：Documents/inbox.txt（在「文件」App →「我的 iPhone」→「助手」下可见）。
enum InboxService {
    static var fileURL: URL {
        URL.documentsDirectory.appending(path: "inbox.txt")
    }

    /// 确保文件存在，方便在快捷指令里选择它。
    static func ensureFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? Data().write(to: fileURL)
        }
    }

    /// 读取并导入收件箱中的所有条目，然后清空。返回导入条数。
    /// 文件协调与读取放到后台线程（NSFileCoordinator 是跨进程同步阻塞调用，
    /// 在主线程执行会在回前台时卡住 UI）；落库仍在调用方的主线程上下文进行。
    @MainActor
    @discardableResult
    static func drain(context: ModelContext) async -> Int {
        let content = await Task.detached(priority: .utility) { () -> String in
            ensureFile()
            let coordinator = NSFileCoordinator()
            var content = ""
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordError) { url in
                content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if !content.isEmpty { try? Data().write(to: url) }
            }
            return content
        }.value
        let entries = InboxFormat.entries(from: content)
        guard !entries.isEmpty else { return 0 }
        let service = ImportService(context: context)
        var count = 0
        for entry in entries {
            if let r = try? service.ingest(entry, source: "inbox"), !r.skippedDuplicate { count += 1 }
        }
        return count
    }
}

enum NotificationService {
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func post(title: String, body: String, id: String = UUID().uuidString) {
        // 模式判定：安静模式或仅记录模式时不弹出横幅和声音
        let mode = AppSettings.currentMode
        if mode == .quiet || mode == .recordOnly {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = L10n.tr(title)
        content.body = L10n.tr(body)
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// 免费账号签名 7 天过期提醒。
enum ExpiryReminder {
    /// 本次安装时间（App 包的创建时间，每次重装都会更新）
    static var installDate: Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath)
        return attrs?[.creationDate] as? Date ?? .now
    }

    static var expiryDate: Date { installDate.addingTimeInterval(7 * 24 * 3600) }

    static var daysLeft: Int {
        max(0, Calendar.current.dateComponents([.day], from: .now, to: expiryDate).day ?? 0)
    }

    /// 在到期前 1 天发提醒（重复调用会覆盖之前的计划）。
    static func schedule() {
        let fireDate = expiryDate.addingTimeInterval(-24 * 3600)
        guard fireDate > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.tr("助手即将过期")
        content.body = L10n.tr("签名将于明天过期，请在 Mac 上运行 scripts/reinstall.sh 重新安装（数据不会丢失）。")
        content.sound = .default
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "expiry-reminder", content: content, trigger: trigger))
    }
}
