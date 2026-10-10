import Foundation
import SwiftData

/// 全局共享的 SwiftData 容器。App 界面和 App Intent（后台）用同一个。
enum Persistence {
    static let shared: ModelContainer = {
        let schema = Schema([
            TodoItem.self,
            RawMessage.self,
            DataUsageRecord.self,
            LearnedPlace.self,
            LocationStaySample.self,
            PeriodicHabit.self,
            MedicationPlan.self,
            SubscriptionItem.self,
            ItemExpiryItem.self,
            AnniversaryItem.self,
            PasswordVaultItem.self,
            IDDocumentItem.self,
            ExpenseRecord.self,
            DepartureCheckItem.self,
            VoiceMemo.self,
            VehicleProfile.self,
            StoredItem.self,
            DialogueMessageRecord.self
        ])
        // 存在 Application Support，覆盖安装（重签）不会丢失
        let config = ModelConfiguration(schema: schema)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            print("⚠️ ModelContainer 首次加载失败: \(error)，尝试重置数据库文件...")
            // 可能是由于新增模型导致的数据库迁移不兼容，尝试清理旧 store 文件并重建
            if let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let defaultStore = appSupportURL.appendingPathComponent("default.store")
                let defaultStoreShm = appSupportURL.appendingPathComponent("default.store-shm")
                let defaultStoreWal = appSupportURL.appendingPathComponent("default.store-wal")
                try? FileManager.default.removeItem(at: defaultStore)
                try? FileManager.default.removeItem(at: defaultStoreShm)
                try? FileManager.default.removeItem(at: defaultStoreWal)
            }
            if let retryContainer = try? ModelContainer(for: schema, configurations: config) {
                print("✅ 重建数据库成功")
                return retryContainer
            }
            if let fallbackContainer = try? ModelContainer(for: schema) {
                print("✅ 默认路径数据库恢复成功")
                return fallbackContainer
            }
            // 内存模式终极兜底，保证应用绝不闪退或黑屏卡死
            if let memContainer = try? ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)) {
                print("⚠️ 使用内存数据库兜底")
                return memContainer
            }
            fatalError("无法创建数据库: \(error)")
        }
    }()
}

enum AppSettings {
    /// 助手名称（用户可自定义，默认："小助"）
    static var assistantName: String {
        get {
            let name = UserDefaults.standard.string(forKey: "assistant_custom_name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "小助" : name
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? "小助" : trimmed, forKey: "assistant_custom_name")
        }
    }

    /// 对用户的称呼（默认："你"）
    static var userTitle: String {
        get {
            let title = UserDefaults.standard.string(forKey: "user_preferred_title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "你" : title
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? "你" : trimmed, forKey: "user_preferred_title")
        }
    }

    /// 运行模式：提醒模式（默认）、安静模式、记录模式
    static var currentMode: AssistantMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "assistant_mode"),
                  let mode = AssistantMode(rawValue: raw) else {
                return .alert
            }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "assistant_mode") }
    }

    /// 语音对话中是否启用 TTS 语音朗读回答
    static var voiceReplyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "voice_reply_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voice_reply_enabled") }
    }

    /// 剩余流量低于此值（MB）时生成待办
    static var lowDataThresholdMB: Double {
        get { UserDefaults.standard.object(forKey: "lowDataThresholdMB") as? Double ?? 1024 }
        set { UserDefaults.standard.set(newValue, forKey: "lowDataThresholdMB") }
    }

    /// 对话记录保留策略（默认保留 30 天，支持 7 天 / 30 天 / 不保留 / 永久）
    static var dialogueRetentionPolicy: DialogueRetentionPolicy {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "dialogue_retention_policy"),
                  let policy = DialogueRetentionPolicy(rawValue: raw) else {
                return .thirtyDays // 默认开启 30 天自动保留
            }
            return policy
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "dialogue_retention_policy")
        }
    }
}
