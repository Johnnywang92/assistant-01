import Foundation
import SwiftData

/// 负责对话历史记录的端侧持久化、自动滚动过期清理与检索
@MainActor
final class DialogueHistoryManager {
    static let shared = DialogueHistoryManager()

    private init() {}

    /// 自动根据保留策略（7天 / 30天 / 不保留）清理超期记录
    func cleanExpiredRecords(context: ModelContext) {
        let policy = AppSettings.dialogueRetentionPolicy

        switch policy {
        case .none:
            // 不保留模式：清理全部历史
            clearAll(context: context)

        case .sevenDays, .thirtyDays:
            let days = policy.retentionDays
            guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }

            let descriptor = FetchDescriptor<DialogueMessageRecord>(
                predicate: #Predicate<DialogueMessageRecord> { record in
                    record.timestamp < cutoffDate
                }
            )

            do {
                let expiredList = try context.fetch(descriptor)
                guard !expiredList.isEmpty else { return }
                for record in expiredList {
                    context.delete(record)
                }
                try context.save()
            } catch {
                print("⚠️ 清理超期对话记录失败: \(error)")
            }

        case .forever:
            // 永久保留，不主动清理
            break
        }
    }

    /// 持久化单条对话消息（若设置为「不保留」，则直接忽略）
    func saveMessage(role: String, text: String, sessionID: UUID? = nil, context: ModelContext) {
        guard AppSettings.dialogueRetentionPolicy != .none else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let record = DialogueMessageRecord(
            role: role,
            text: trimmed,
            timestamp: .now,
            sessionID: sessionID
        )
        context.insert(record)
        do {
            try context.save()
        } catch {
            print("⚠️ 保存对话记录失败: \(error)")
        }
    }

    /// 获取最近历史对话（默认最多载入前 100 条）
    func fetchRecentMessages(limit: Int = 100, context: ModelContext) -> [DialogueMessageRecord] {
        guard AppSettings.dialogueRetentionPolicy != .none else { return [] }

        var descriptor = FetchDescriptor<DialogueMessageRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = limit

        do {
            return try context.fetch(descriptor)
        } catch {
            print("⚠️ 读取对话历史失败: \(error)")
            return []
        }
    }

    /// 获取用于喂给端侧模型的最近若干轮对话（按时间正序排列）
    /// - Parameters:
    ///   - sessionID: 会话标识；非空时仅读取同一会话的消息
    ///   - limit: 最大轮数（单条记录为一轮消息，默认取最近 8 句）
    ///   - context: SwiftData 模型上下文
    /// - Returns: `(role: String, text: String)` 数组；若保留策略为 `.none` 则直接返回空数组
    func recentTurns(
        sessionID: UUID? = nil,
        limit: Int = 8,
        context: ModelContext
    ) -> [(role: String, text: String)] {
        guard AppSettings.dialogueRetentionPolicy != .none else { return [] }
        guard limit > 0 else { return [] }

        var descriptor: FetchDescriptor<DialogueMessageRecord>
        if let sid = sessionID {
            descriptor = FetchDescriptor<DialogueMessageRecord>(
                predicate: #Predicate<DialogueMessageRecord> { $0.sessionID == sid },
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<DialogueMessageRecord>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
        }
        descriptor.fetchLimit = limit

        do {
            let records = try context.fetch(descriptor)
            // 查出的是最近倒序记录，反转为按时间正序喂给 ChatML
            return records.reversed().map { (role: $0.roleRaw, text: $0.text) }
        } catch {
            print("⚠️ 读取近期对话轮次失败: \(error)")
            return []
        }
    }

    /// 获取已保存的历史记录条数
    func countHistory(context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<DialogueMessageRecord>()
        descriptor.fetchLimit = 1000
        do {
            return try context.fetchCount(descriptor)
        } catch {
            return 0
        }
    }

    /// 清空所有历史对话记录
    func clearAll(context: ModelContext) {
        let descriptor = FetchDescriptor<DialogueMessageRecord>()
        do {
            let all = try context.fetch(descriptor)
            for item in all {
                context.delete(item)
            }
            try context.save()
        } catch {
            print("⚠️ 清空对话记录失败: \(error)")
        }
    }
}
