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

/// 免费账号签名 7 天过期提醒与证书有效期解析。
enum ExpiryReminder {
    /// 从应用包内的 embedded.mobileprovision 提取苹果签发的真实到期时间
    static var actualExpiryDate: Date? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards, in: start.lowerBound..<data.count) else {
            return nil
        }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let expirationDate = plist["ExpirationDate"] as? Date else {
            return nil
        }
        return expirationDate
    }

    /// 证书到期时间（优先取真实签名描述文件到期时间，无描述文件时降级回退）
    static var expiryDate: Date {
        if let actual = actualExpiryDate {
            return actual
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath)
        let installDate = attrs?[.creationDate] as? Date ?? .now
        return installDate.addingTimeInterval(7 * 24 * 3600)
    }

    /// 剩余有效天数
    static var daysLeft: Int {
        let diff = Calendar.current.dateComponents([.day, .hour], from: .now, to: expiryDate)
        let days = diff.day ?? 0
        let hours = diff.hour ?? 0
        if days == 0 && hours > 0 {
            return 1
        }
        return max(0, days)
    }

    /// 友好展示文本（如："剩 6 天 23 小时"）
    static var displayDescription: String {
        let now = Date.now
        if expiryDate <= now {
            return L10n.tr("已过期")
        }
        let diff = Calendar.current.dateComponents([.day, .hour], from: now, to: expiryDate)
        let d = diff.day ?? 0
        let h = diff.hour ?? 0
        if d > 0 {
            return L10n.isEnglish ? "\(d) days \(h) hrs left" : "剩 \(d) 天 \(h) 小时"
        } else {
            return L10n.isEnglish ? "\(h) hrs left" : "仅剩 \(h) 小时"
        }
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
