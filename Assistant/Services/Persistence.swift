import Foundation
import SwiftData

/// 全局共享的 SwiftData 容器。App 界面和 App Intent（后台）用同一个。
enum Persistence {
    private static var storedRecoveryError: String?
    static var recoveryError: String? {
        _ = shared
        return storedRecoveryError
    }

    static var storeFiles: [URL] {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        return ["default.store", "default.store-wal", "default.store-shm"]
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 主库文件路径（默认配置的 default.store）。供文件层维护（如密码迁移后的残留清理）使用。
    static var storeURL: URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return directory.appendingPathComponent("default.store")
    }

    static let shared: ModelContainer = {
        StartupMetrics.mark("store.open begin")
        do {
            let container = try openStore()
            StartupMetrics.mark("store.open ready")
            return container
        } catch {
            // 真机旧库由引入迁移计划前的「无版本容器」创建，版本标识/内容可能与此处 V1 声明不符，
            // 带计划的轻量迁移会找不到源库。退回旧路径：无迁移计划、由系统自动轻量升级
            // （纯加法变更，历次发布在真机上就是这么升级的）；仍不动磁盘文件。
            do {
                let container = try openStoreAutoMigrate()
                StartupMetrics.mark("store.open ready(autoMigrate)")
                return container
            } catch {
                // 不删除或覆盖原库。仅用内存容器承载恢复页，禁止进入正常业务界面。
                storedRecoveryError = Self.diagnose(openError: error)
                let memSchema = Schema(AssistantSchemaV4.models)
                if let memContainer = try? ModelContainer(for: memSchema, configurations: ModelConfiguration(isStoredInMemoryOnly: true)) {
                    return memContainer
                }
                fatalError("无法打开数据库或恢复页: \(error)")
            }
        }
    }()

    /// 带版本化迁移打开持久库。
    /// 旧库（V1）经 lightweight 阶段自动升级到 V2；**任何失败都不动磁盘文件**，
    /// 由调用方走恢复页导出原库。详见 `AssistantMigrationPlan`。
    private static func openStore() throws -> ModelContainer {
        let schema = Schema(AssistantSchemaV4.models)
        let config = ModelConfiguration(schema: schema)
        #if DEBUG
        Self.assertSchemaCoverage()
        #endif
        return try StartupMetrics.measure("openStore(versioned)") {
            try ModelContainer(for: schema, migrationPlan: AssistantMigrationPlan.self, configurations: config)
        }
    }

    /// 无迁移计划的旧路径：仅作为版本化计划识别不了真机遗留库时的兜底。
    private static func openStoreAutoMigrate() throws -> ModelContainer {
        let schema = Schema(AssistantSchemaV4.models)
        let config = ModelConfiguration(schema: schema)
        return try StartupMetrics.measure("openStore(autoMigrate)") {
            try ModelContainer(for: schema, configurations: config)
        }
    }

    /// 打开失败时生成可诊断的错误描述：附带库文件路径与体积，
    /// 让恢复页能引导用户导出原文件，而不是只显示一句「打不开」。
    private static func diagnose(openError: Error) -> String {
        var lines: [String] = [openError.localizedDescription]
        let files = storeFiles
        if !files.isEmpty {
            lines.append("数据库文件：")
            for url in files {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                lines.append("• \(url.lastPathComponent)（\(size / 1024) KB）")
            }
            lines.append("路径：\(files[0].deletingLastPathComponent().path)")
        }
        lines.append("原文件未被修改，可通过下方导出备份后重建数据库。")
        return lines.joined(separator: "\n")
    }

    /// V1 的每个模型必须仍在当前版本中：轻量迁移只能加字段/加模型，
    /// 删模型会让旧库升级后静默丢表。DEBUG 下断言，发布构建不增开销。
    private static func assertSchemaCoverage() {
        let v1 = Set(AssistantSchemaV1.models.map { String(describing: $0) })
        let current = Set(AssistantSchemaV4.models.map { String(describing: $0) })
        let missing = v1.subtracting(current)
        assert(missing.isEmpty, "V1 模型从当前版本消失，旧库升级会丢数据：\(missing.sorted())")
    }
}

/// Schema V1：引入迁移计划（版本化容器）之前，旧版 App 在真机上实际持久化的模型全集
/// （即无版本容器最后一次使用的 31 模型清单，到 LifeEventGuest 为止）。
/// 真机旧库的内容与此对齐时，V1→V2 轻量迁移才能直接命中；对不上的库由
/// `openStoreAutoMigrate()` 兜底。**已发布版本的模型清单不可再改：新增模型请开 V3。**
enum AssistantSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
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
            DialogueMessageRecord.self,
            PetProfile.self,
            ChildProfile.self,
            ChildGrowthRecord.self,
            ChildMilestoneRecord.self,
            ChildHealthVisitRecord.self,
            ChildVaccinationRecord.self,
            LifeReminderAction.self,
            LifeEventProject.self,
            LifeEventStage.self,
            LifeEventTask.self,
            LifeEventPerson.self,
            LifeEventExpense.self,
            LifeEventGuest.self
        ]
    }
}

/// Schema V2：当前版本。V2 相对 V1 纯加法（Omnibox 事务 + 技能路径 3 模型 + 各模型默认值字段），
/// 走 lightweight 迁移即可。后续再有加法请新开 V3，不要原地改本清单。
enum AssistantSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [
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
            DialogueMessageRecord.self,
            PetProfile.self,
            ChildProfile.self,
            ChildGrowthRecord.self,
            ChildMilestoneRecord.self,
            ChildHealthVisitRecord.self,
            ChildVaccinationRecord.self,
            LifeReminderAction.self,
            LifeEventProject.self,
            LifeEventStage.self,
            LifeEventTask.self,
            LifeEventPerson.self,
            LifeEventExpense.self,
            LifeEventGuest.self,
            OmniboxTransaction.self,
            SkillPath.self,
            SkillStage.self,
            SkillPracticeLog.self
        ]
    }
}

/// Schema V3：当前版本。V3 相对 V2 纯加法（新增家庭常备药 MedicineItem），走 lightweight 迁移即可。
/// 已发布版本 V2 清单不可再改；后续再有加法请新开 V4。
enum AssistantSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        AssistantSchemaV2.models + [
            MedicineItem.self
        ]
    }
}

/// Schema V4：当前版本。V4 相对 V3 纯加法（新增饮食热量记录 FoodIntakeRecord），
/// 走 lightweight 迁移即可。已发布版本 V3 清单不可再改；后续再有加法请新开 V5。
enum AssistantSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] {
        AssistantSchemaV3.models + [
            FoodIntakeRecord.self
        ]
    }
}

/// 显式版本化迁移计划。**不要再回到「打不开就删库重建」**——
/// 旧代码首次失败即删 default.store，用户数据直接蒸发；现在失败走恢复页导出原库。
enum AssistantMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [AssistantSchemaV1.self, AssistantSchemaV2.self, AssistantSchemaV3.self, AssistantSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        // V1→V2→V3→V4 全是「加字段（带默认值）+ 加模型」，系统 lightweight 迁移可完成。
        // 若未来出现不兼容变更（删字段/改类型），在此插自定义阶段，
        // 并把目标版本的该字段改回可选或提供默认值——不要静默丢数据。
        [
            .lightweight(fromVersion: AssistantSchemaV1.self, toVersion: AssistantSchemaV2.self),
            .lightweight(fromVersion: AssistantSchemaV2.self, toVersion: AssistantSchemaV3.self),
            .lightweight(fromVersion: AssistantSchemaV3.self, toVersion: AssistantSchemaV4.self)
        ]
    }
}

enum AppSettings {
    /// 助手名称（用户可自定义，默认："小助" / "Assistant"）
    static var assistantName: String {
        get {
            let name = UserDefaults.standard.string(forKey: "assistant_custom_name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty || name == "小助" || name == "Assistant" {
                return L10n.isEnglish ? "Assistant" : "小助"
            }
            return name
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? "小助" : trimmed, forKey: "assistant_custom_name")
        }
    }

    /// 对用户的称呼（默认："你" / "You"）
    static var userTitle: String {
        get {
            let title = UserDefaults.standard.string(forKey: "user_preferred_title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.isEmpty || title == "你" || title == "You" {
                return L10n.isEnglish ? "You" : "你"
            }
            return title
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
