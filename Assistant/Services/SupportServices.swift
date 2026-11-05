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

    /// 读取并导入收件箱中的所有条目，只把「已成功消费」的条目从文件移除，返回新导入条数。
    ///
    /// 事务语义（审计 SVC-03）：旧实现先把 inbox.txt 覆盖成空、再逐条 `try? ingest`，
    /// 落库失败时原文已被清空 —— 用户输入永久丢失且没有任何提示。现在：
    /// - 逐条 `do/catch` 落库：失败条目原文留在文件里，下次回前台自动重试；
    /// - `skippedDuplicate`（ImportService 的原文去重命中）算「已消费」，必须移除，
    ///   否则同一条会在每次巡检时被反复解析；
    /// - 清理文件前重读当前内容、按「本次消费掉的原文」逐段删除，
    ///   避免把快捷指令在读取之后新追加的条目一并覆盖掉；
    /// - 写回文件失败不当作消费成功：原文仍在文件里，下次重试；
    ///   重复导入由 ImportService 的原文去重兜底，不会产生重复数据。
    ///
    /// 文件协调与读写放到后台线程（NSFileCoordinator 是跨进程同步阻塞调用，
    /// 在主线程执行会在回前台时卡住 UI）；落库仍在调用方的主线程上下文进行。
    @MainActor
    @discardableResult
    static func drain(context: ModelContext) async -> Int {
        let content = await readInboxContent()
        let entries = InboxFormat.entries(from: content)
        guard !entries.isEmpty else { return 0 }

        let service = ImportService(context: context)
        var imported = 0
        var consumed: [String: Int] = [:]
        for entry in entries {
            do {
                let result = try service.ingest(entry, source: "inbox")
                consumed[entry, default: 0] += 1
                if !result.skippedDuplicate { imported += 1 }
            } catch {
                // 本条落库失败：回滚本条未提交的 insert。不回滚的话，后续条目的 save
                // 会把「失败的条目」一起提交，造成「报失败但其实入库了」的假象。
                context.rollback()
                print("⚠️ [Inbox] 条目落库失败，原文保留待下次重试: \(error.localizedDescription)")
            }
        }
        if !consumed.isEmpty {
            await removeConsumedEntries(consumed)
        }
        return imported
    }

    /// 后台读取收件箱原文（只读，不清空文件）。
    private static func readInboxContent() async -> String {
        await Task.detached(priority: .utility) { () -> String in
            ensureFile()
            let coordinator = NSFileCoordinator()
            var content = ""
            var coordError: NSError?
            coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges, error: &coordError) { url in
                content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            return content
        }.value
    }

    /// 后台把「本次已消费的条目」从收件箱文件移除；其余条目（含读取后新追加的）原样保留。
    private static func removeConsumedEntries(_ consumed: [String: Int]) async {
        await Task.detached(priority: .utility) {
            var pending = consumed
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordError) { url in
                // 重读再删：快捷指令可能在 drain 读取之后又追加了新条目，不能覆盖掉。
                let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                var kept: [String] = []
                for segment in current.components(separatedBy: InboxFormat.separator) {
                    let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { continue }
                    if let left = pending[text], left > 0 {
                        pending[text] = left - 1
                        continue
                    }
                    kept.append(segment)
                }
                let remainder = kept.isEmpty ? "" : kept.joined(separator: InboxFormat.separator)
                do {
                    try Data(remainder.utf8).write(to: url)
                } catch {
                    // 写回失败不做任何「已清理」的假设：文件里仍是原文，下次重试时由原文去重兜底。
                    print("⚠️ [Inbox] 已导入条目清理失败（下次会重复导入，原文去重会跳过）: \(error.localizedDescription)")
                }
            }
        }.value
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
