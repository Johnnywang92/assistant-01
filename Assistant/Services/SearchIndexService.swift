import AssistantCore
import Foundation
import SwiftData
import SwiftUI

/// 全局多维搜索与索引服务中心
///
/// 核心职责：
/// 1. 管理系统设置的静态索引与全域数据（待办、记账、物品、证件、备忘、密码、饮食、用药、习惯、档案、健康等）的动态倒排索引
/// 2. 提供毫秒级分词拼音搜索（支持拼音全拼与首字母缩写）
/// 3. 管理最近搜索历史与热门快捷检索词
/// 4. 配合 SearchPrivacyGate 执行统一隐私保护脱敏
@MainActor
public final class SearchIndexService: ObservableObject {
    public static let shared = SearchIndexService()

    public let engine = SearchIndexEngine()

    @Published public var totalIndexedCount: Int = 0
    @Published public var isIndexing: Bool = false
    @Published public var searchResults: [SearchIndexMatch] = []
    @Published public var recentSearches: [String] = []

    private let recentSearchesKey = "unified_search_recent_queries_v2"
    private var isIndexInitialized = false

    private init() {
        loadRecentSearches()
        indexStaticSettings()
    }

    // MARK: - 静态系统设置索引

    /// 索引全部设置模块与子功能项，赋予高优先级及丰富的中英文拼音关键词
    public func indexStaticSettings() {
        let settingsDocs: [SearchIndexDocument] = [
            SearchIndexDocument(
                id: "setting_assistant_name",
                category: .setting,
                title: "助手命名与称呼",
                subtitle: "自定义助手名称与称呼方式",
                keywords: ["助手", "名称", "改名", "小助", "称呼", "昵称", "对我的称呼", "命名"],
                route: .setting(destination: "assistant_name"),
                badge: "设置",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_language",
                category: .setting,
                title: "多语言与国际化",
                subtitle: "界面语言切换（简体中文/English）",
                keywords: ["语言", "多语言", "英文", "中文", "language", "english", "翻译", "界面语言"],
                route: .setting(destination: "appearance_language"),
                badge: "个性化",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_theme",
                category: .setting,
                title: "外观主题与深色模式",
                subtitle: "暗黑模式、浅色模式与个性色彩主题",
                keywords: ["主题", "深色", "暗黑", "浅色", "皮肤", "配色", "色彩", "夜间模式", "换肤", "theme", "dark mode"],
                route: .setting(destination: "appearance_theme"),
                badge: "个性化",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_background",
                category: .setting,
                title: "个性化背景与壁纸",
                subtitle: "自定义全局背景图片、毛玻璃与透明度",
                keywords: ["背景", "壁纸", "图片", "毛玻璃", "透明度", "自定义背景", "wallpaper", "background"],
                route: .setting(destination: "appearance_background"),
                badge: "个性化",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_dynamic_type",
                category: .setting,
                title: "大字关怀模式",
                subtitle: "加大字体字号、长辈关怀无障碍体验",
                keywords: ["大字", "字体", "大号字体", "长辈", "适老", "字号", "视力", "关怀", "无障碍"],
                route: .setting(destination: "appearance_dynamic_type"),
                badge: "个性化",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_voice_tts",
                category: .setting,
                title: "语音音色与人声朗读",
                subtitle: "离线语音合成人声、语速与音调配置",
                keywords: ["语音", "音色", "人声", "TTS", "朗读", "语速", "播报", "发音", "语音助手"],
                route: .setting(destination: "appearance_voice"),
                badge: "个性化",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_tabbar",
                category: .setting,
                title: "首页底栏 Tab 自定义",
                subtitle: "底部导航栏板块增删、拖拽排序与常驻管理",
                keywords: ["tab", "底栏", "导航栏", "自定义tab", "排序", "板块", "底部栏", "常用模块"],
                route: .setting(destination: "appearance_tabbar"),
                badge: "个性化",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_daily_report",
                category: .setting,
                title: "日程早报与每日晚报",
                subtitle: "晨间日程提醒与晚间生活复盘推送",
                keywords: ["早报", "晚报", "日报", "报告", "每日总结", "复盘", "早间提醒", "推送时间"],
                route: .setting(destination: "reminders_report"),
                badge: "提醒",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_sleep_reminder",
                category: .setting,
                title: "睡眠与就寝作息提醒",
                subtitle: "智能睡前酝酿、睡眠起始点追踪与多因子生物节律联动",
                keywords: ["睡眠", "就寝", "作息", "早睡", "生物钟", "睡前酝酿", "睡眠提醒", "入睡时间", "熬夜", "睡眠数据", "sleep"],
                route: .setting(destination: "reminders_sleep"),
                badge: "提醒",
                scoreBoost: 60
            ),
            SearchIndexDocument(
                id: "setting_screen_time",
                category: .setting,
                title: "屏幕使用时间防沉迷",
                subtitle: "屏幕时间追踪、蓝光抑制缓冲与快捷指令自动上报",
                keywords: ["屏幕", "屏幕时间", "使用时间", "手机时长", "防沉迷", "蓝光", "快捷指令上报", "screen time"],
                route: .setting(destination: "reminders_screentime"),
                badge: "提醒",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_budget_alert",
                category: .setting,
                title: "月度预算与支出预警",
                subtitle: "月度消费限额设定、进度预警与超支红线报警",
                keywords: ["预算", "月度预算", "超支", "预警", "消费报警", "限额", "省钱", "安心花", "记账预算"],
                route: .setting(destination: "reminders_budget"),
                badge: "提醒",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_anniversary_reminder",
                category: .setting,
                title: "纪念日提前提醒设置",
                subtitle: "生日、恋爱纪念日提前备礼提醒天数",
                keywords: ["纪念日", "生日", "倒数日", "提前提醒", "备礼提醒", "重要日子"],
                route: .setting(destination: "reminders_anniversary"),
                badge: "提醒",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_battery_care",
                category: .setting,
                title: "低电量与充电关怀提醒",
                subtitle: "出门前电量检查与临睡低电量插电提醒",
                keywords: ["电池", "电量", "低电量", "充电", "充电源", "电池关怀"],
                route: .setting(destination: "reminders_battery"),
                badge: "提醒",
                scoreBoost: 40
            ),
            SearchIndexDocument(
                id: "setting_privacy_details",
                category: .setting,
                title: "通知敏感详情与锁屏隐私",
                subtitle: "锁屏隐藏快递取件码、记账金额与证件信息",
                keywords: ["隐私", "敏感详情", "锁屏", "通知隐藏", "脱敏", "取件码隐藏", "金额隐藏", "安全"],
                route: .setting(destination: "reminders_privacy"),
                badge: "隐私",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_ai_model",
                category: .setting,
                title: "AI 大模型配置与 API Key",
                subtitle: "DeepSeek / OpenAI / Claude / Gemini API 密钥与地址配置",
                keywords: ["AI", "大模型", "模型", "API Key", "Base URL", "DeepSeek", "OpenAI", "Claude", "Gemini", "智能助手"],
                route: .setting(destination: "aiData_model"),
                badge: "AI数据",
                scoreBoost: 55
            ),
            SearchIndexDocument(
                id: "setting_omnibox",
                category: .setting,
                title: "万能投喂口与剪贴板识别",
                subtitle: "剪贴板返回即自动解析、拍照与截图智能入库",
                keywords: ["投喂口", "剪贴板", "万能投喂", "自动识别", "截图导入", "短信导入", "智能提取", "omnibox"],
                route: .setting(destination: "aiData_omnibox"),
                badge: "AI数据",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_applock",
                category: .setting,
                title: "生物识别与应用锁",
                subtitle: "Face ID / Touch ID / 独立密码安全锁与防窥遮罩",
                keywords: ["应用锁", "密码锁", "Face ID", "Touch ID", "面容", "指纹", "锁屏", "解锁", "隐私保护", "app lock"],
                route: .setting(destination: "aiData_applock"),
                badge: "安全",
                scoreBoost: 55
            ),
            SearchIndexDocument(
                id: "setting_backup_webdav",
                category: .setting,
                title: "数据备份与 WebDAV 云同步",
                subtitle: "全量离线加密备份、JSON 导出与坚果云/自建网盘同步",
                keywords: ["备份", "同步", "WebDAV", "云同步", "坚果云", "导出数据", "数据恢复", "还原", "backup"],
                route: .setting(destination: "aiData_backup"),
                badge: "数据",
                scoreBoost: 55
            ),
            SearchIndexDocument(
                id: "setting_permissions",
                category: .setting,
                title: "系统权限管理",
                subtitle: "通知、HealthKit 健康、相机、定位与日历权限状态检查",
                keywords: ["权限", "系统权限", "通知权限", "健康权限", "HealthKit", "相机权限", "定位", "日历授权"],
                route: .setting(destination: "system_permissions"),
                badge: "系统",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_shortcuts",
                category: .setting,
                title: "Siri 快捷指令与短信自动化向导",
                subtitle: "iOS 快捷指令自动化配置，实现收短信自动记账与录待办",
                keywords: ["快捷指令", "Siri", "Shortcuts", "自动化", "自动化向导", "短信记账", "短信待办"],
                route: .setting(destination: "system_shortcuts"),
                badge: "系统",
                scoreBoost: 50
            ),
            SearchIndexDocument(
                id: "setting_guide",
                category: .setting,
                title: "使用指南与常见问题 FAQ",
                subtitle: "全功能使用技巧、场景实操与疑难解答",
                keywords: ["帮助", "使用指南", "指南", "FAQ", "教程", "手册", "怎么用", "常见问题"],
                route: .setting(destination: "system_guide"),
                badge: "帮助",
                scoreBoost: 45
            ),
            SearchIndexDocument(
                id: "setting_about",
                category: .setting,
                title: "关于小助",
                subtitle: "版本信息、更新日志与隐私声明",
                keywords: ["关于", "版本", "更新", "关于小助", "开发者", "版本号"],
                route: .setting(destination: "system_about"),
                badge: "关于",
                scoreBoost: 40
            )
        ]

        engine.add(settingsDocs)
        totalIndexedCount = engine.count
    }

    // MARK: - 全域数据索引重建

    /// 全面扫描 App 全部业务数据表，构建高性能跨模块倒排索引
    public func rebuildIndex(context: ModelContext) async {
        guard !isIndexing else { return }
        isIndexing = true
        defer { isIndexing = false }

        // 重新初始化清空并注入设置项
        engine.clear()
        indexStaticSettings()

        var batch: [SearchIndexDocument] = []
        batch.reserveCapacity(2000)

        // 1. 待办事项 (TodoItem)
        var todoDescriptor = FetchDescriptor<TodoItem>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        todoDescriptor.fetchLimit = 800
        if let todos = try? context.fetch(todoDescriptor) {
            for t in todos {
                let sub: String? = {
                    if let code = t.pickupCode, !code.isEmpty {
                        let station = t.station ?? t.location ?? ""
                        return "取件码：\(code) · \(station)"
                    }
                    return t.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? t.detail : (t.station ?? t.location)
                }()
                var kw: [String] = [t.typeRaw, t.type.displayName]
                if let code = t.pickupCode { kw.append(code); kw.append("取件码") }
                if let courier = t.courier { kw.append(courier) }
                if let loc = t.location { kw.append(loc) }
                if let st = t.station { kw.append(st) }

                batch.append(
                    SearchIndexDocument(
                        id: "todo_\(t.id.uuidString)",
                        category: .todo,
                        title: t.title,
                        subtitle: sub,
                        content: t.detail,
                        keywords: kw,
                        date: t.dueAt ?? t.createdAt,
                        isSensitive: true,
                        route: .todo(id: t.id),
                        badge: t.type.displayName
                    )
                )
            }
        }

        // 2. 记账明细 (ExpenseRecord)
        var expDescriptor = FetchDescriptor<ExpenseRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        expDescriptor.fetchLimit = 500
        if let expenses = try? context.fetch(expDescriptor) {
            for e in expenses {
                let sign = e.isIncome ? "+" : "-"
                let sub = String(format: "%@%.2f 元 · %@", sign, e.amount, e.categoryRaw)
                batch.append(
                    SearchIndexDocument(
                        id: "exp_\(e.id.uuidString)",
                        category: .expense,
                        title: e.title,
                        subtitle: sub,
                        content: e.rawText,
                        keywords: [e.categoryRaw, e.isIncome ? "收入" : "支出", "账单", "记账"],
                        date: e.date,
                        isSensitive: true,
                        route: .tab(tabName: "expenses"),
                        badge: e.categoryRaw
                    )
                )
            }
        }

        // 3. 收纳物品 (StoredItem)
        var storeDescriptor = FetchDescriptor<StoredItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        storeDescriptor.fetchLimit = 300
        if let stored = try? context.fetch(storeDescriptor) {
            for s in stored {
                let loc = "\(s.roomArea) · \(s.location)"
                let kw: [String] = [s.roomArea, s.location, "收纳", "物品", "位置"]
                batch.append(
                    SearchIndexDocument(
                        id: "storage_\(s.id.uuidString)",
                        category: .storage,
                        title: s.name,
                        subtitle: loc,
                        content: s.notes,
                        keywords: kw,
                        date: s.updatedAt,
                        isSensitive: true,
                        route: .vault(destination: "storage"),
                        badge: s.roomArea
                    )
                )
            }
        }

        // 4. 证件卡包 (IDDocumentItem)
        var docDescriptor = FetchDescriptor<IDDocumentItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        docDescriptor.fetchLimit = 150
        if let docs = try? context.fetch(docDescriptor) {
            for d in docs {
                let sub = d.type.displayName
                var kw: [String] = [d.type.displayName, d.typeRaw, "证件", "卡包"]
                if let num = d.documentNumber, !num.isEmpty { kw.append(num) }
                if let holder = d.holderName, !holder.isEmpty { kw.append(holder) }
                batch.append(
                    SearchIndexDocument(
                        id: "doc_\(d.id.uuidString)",
                        category: .document,
                        title: d.title,
                        subtitle: sub,
                        content: d.notes,
                        keywords: kw,
                        date: d.expiryDate ?? d.updatedAt,
                        isSensitive: true,
                        route: .vault(destination: "documents"),
                        badge: d.type.displayName
                    )
                )
            }
        }

        // 5. 语音备忘录 (VoiceMemo)
        var memoDescriptor = FetchDescriptor<VoiceMemo>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        memoDescriptor.fetchLimit = 200
        if let memos = try? context.fetch(memoDescriptor) {
            for m in memos {
                let snippet = String((m.summary ?? m.transcription ?? "").prefix(40))
                let sub = snippet.isEmpty ? "\(Int(m.duration)) 秒录音" : snippet
                batch.append(
                    SearchIndexDocument(
                        id: "memo_\(m.id.uuidString)",
                        category: .memo,
                        title: m.title,
                        subtitle: sub,
                        content: m.transcription,
                        keywords: ["录音", "语音", "备忘录", "转写"],
                        date: m.createdAt,
                        isSensitive: true,
                        route: .vault(destination: "voiceMemos"),
                        badge: "语音备忘"
                    )
                )
            }
        }

        // 6. 密码保险箱 (PasswordVaultItem)
        var pwdDescriptor = FetchDescriptor<PasswordVaultItem>(sortBy: [SortDescriptor(\.lastRotatedAt, order: .reverse)])
        pwdDescriptor.fetchLimit = 200
        if let passwords = try? context.fetch(pwdDescriptor) {
            for p in passwords {
                batch.append(
                    SearchIndexDocument(
                        id: "pwd_\(p.id.uuidString)",
                        category: .password,
                        title: p.title,
                        subtitle: p.account.isEmpty ? p.category : p.account,
                        content: p.notes,
                        keywords: [p.category, "密码", "账号", "保险箱", "登录"],
                        date: p.lastRotatedAt,
                        isSensitive: true,
                        route: .vault(destination: "passwords"),
                        badge: p.category
                    )
                )
            }
        }

        // 7. 饮食摄入记录 (FoodIntakeRecord)
        var foodDescriptor = FetchDescriptor<FoodIntakeRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        foodDescriptor.fetchLimit = 200
        if let foods = try? context.fetch(foodDescriptor) {
            for f in foods {
                let sub = String(format: "摄入约 %.0f 千卡", f.consumedCalories)
                batch.append(
                    SearchIndexDocument(
                        id: "food_\(f.id.uuidString)",
                        category: .diet,
                        title: f.foodName,
                        subtitle: sub,
                        keywords: ["饮食", "食物", "卡路里", "热量", "营养", "餐食"],
                        date: f.date,
                        isSensitive: false,
                        route: .vault(destination: "foodCalorie"),
                        badge: "饮食"
                    )
                )
            }
        }

        // 8. 周期性习惯与家务 (PeriodicHabit)
        var habitDescriptor = FetchDescriptor<PeriodicHabit>(sortBy: [SortDescriptor(\.nextDueAt, order: .reverse)])
        habitDescriptor.fetchLimit = 100
        if let habits = try? context.fetch(habitDescriptor) {
            for h in habits {
                batch.append(
                    SearchIndexDocument(
                        id: "habit_\(h.id.uuidString)",
                        category: .habitMed,
                        title: h.title,
                        subtitle: "周期：\(h.recurrenceRaw)",
                        content: h.detail,
                        keywords: ["习惯", "打卡", "家务", "规律", h.recurrenceRaw],
                        date: h.nextDueAt,
                        isSensitive: false,
                        route: .vault(destination: "habits"),
                        badge: "习惯"
                    )
                )
            }
        }

        // 9. 用药计划 (MedicationPlan)
        var medDescriptor = FetchDescriptor<MedicationPlan>()
        medDescriptor.fetchLimit = 100
        if let meds = try? context.fetch(medDescriptor) {
            for m in meds {
                let times = m.dailyTimePoints.joined(separator: " / ")
                batch.append(
                    SearchIndexDocument(
                        id: "med_\(m.id.uuidString)",
                        category: .habitMed,
                        title: m.medName,
                        subtitle: "剂量：\(m.dosage) · \(times)",
                        content: m.notes,
                        keywords: ["药品", "吃药", "用药", "处方", "服药提醒", "药片"],
                        date: m.lastTakenAt,
                        isSensitive: true,
                        route: .vault(destination: "habits"),
                        badge: "用药"
                    )
                )
            }
        }

        // 10. 纪念日 (AnniversaryItem)
        var annDescriptor = FetchDescriptor<AnniversaryItem>(sortBy: [SortDescriptor(\.targetDate, order: .reverse)])
        annDescriptor.fetchLimit = 100
        if let anniversaries = try? context.fetch(annDescriptor) {
            for a in anniversaries {
                let days = a.passedDays
                batch.append(
                    SearchIndexDocument(
                        id: "ann_\(a.id.uuidString)",
                        category: .anniversary,
                        title: a.title,
                        subtitle: "累计 \(days) 天 · \(a.category)",
                        content: a.notes,
                        keywords: [a.category, "纪念日", "生日", "倒数日", "恋爱", "重要日子"],
                        date: a.targetDate,
                        isSensitive: true,
                        route: .vault(destination: "anniversaries"),
                        badge: a.category
                    )
                )
            }
        }

        // 11. 车辆管理 (VehicleProfile)
        var vehDescriptor = FetchDescriptor<VehicleProfile>()
        vehDescriptor.fetchLimit = 50
        if let vehicles = try? context.fetch(vehDescriptor) {
            for v in vehicles {
                batch.append(
                    SearchIndexDocument(
                        id: "veh_\(v.id.uuidString)",
                        category: .lifeVault,
                        title: "\(v.name) (\(v.plateNumber))",
                        subtitle: "能源类型：\(v.powerTypeRaw)",
                        keywords: ["车", "车辆", "爱车", "车牌", "保养", "年检", "里程", v.name, v.plateNumber],
                        date: v.lastMaintenanceDate,
                        isSensitive: true,
                        route: .vault(destination: "vehicles"),
                        badge: "车辆"
                    )
                )
            }
        }

        // 12. 宠物档案 (PetProfile)
        var petDescriptor = FetchDescriptor<PetProfile>()
        petDescriptor.fetchLimit = 50
        if let pets = try? context.fetch(petDescriptor) {
            for p in pets {
                batch.append(
                    SearchIndexDocument(
                        id: "pet_\(p.id.uuidString)",
                        category: .lifeVault,
                        title: p.name,
                        subtitle: "\(p.typeRaw) · \(p.breed)",
                        content: p.notes,
                        keywords: ["宠物", "猫", "狗", p.typeRaw, p.breed, "疫苗", "驱虫", p.name],
                        date: p.createdAt,
                        isSensitive: false,
                        route: .vault(destination: "pets"),
                        badge: "宠物"
                    )
                )
            }
        }

        // 13. 孩子档案 (ChildProfile)
        var childDescriptor = FetchDescriptor<ChildProfile>()
        childDescriptor.fetchLimit = 50
        if let children = try? context.fetch(childDescriptor) {
            for c in children {
                batch.append(
                    SearchIndexDocument(
                        id: "child_\(c.id.uuidString)",
                        category: .lifeVault,
                        title: c.name,
                        subtitle: "家庭成长档案",
                        content: c.notes,
                        keywords: ["孩子", "亲子", "育儿", "宝宝", "疫苗", c.name],
                        date: c.createdAt,
                        isSensitive: true,
                        route: .vault(destination: "children"),
                        badge: "亲子"
                    )
                )
            }
        }

        // 14. 出门随身清单 (DepartureCheckItem)
        var depDescriptor = FetchDescriptor<DepartureCheckItem>()
        depDescriptor.fetchLimit = 50
        if let departures = try? context.fetch(depDescriptor) {
            for d in departures {
                batch.append(
                    SearchIndexDocument(
                        id: "dep_\(d.id.uuidString)",
                        category: .lifeVault,
                        title: d.title,
                        subtitle: d.storageLocationNote ?? d.scene.displayName,
                        keywords: ["出门", "清单", "钥匙", "带伞", "随身物品", "防遗忘", "出行", d.scene.displayName],
                        date: d.createdAt,
                        isSensitive: false,
                        route: .vault(destination: "departure"),
                        badge: "出行"
                    )
                )
            }
        }

        // 15. 技能路径 (SkillPath)
        var skillDescriptor = FetchDescriptor<SkillPath>()
        skillDescriptor.fetchLimit = 50
        if let skills = try? context.fetch(skillDescriptor) {
            for s in skills {
                batch.append(
                    SearchIndexDocument(
                        id: "skill_\(s.id.uuidString)",
                        category: .lifeVault,
                        title: s.title,
                        subtitle: s.goal,
                        keywords: ["技能", "学习", "路径", "目标", "进阶", s.categoryRaw],
                        date: s.startedAt,
                        isSensitive: false,
                        route: .vault(destination: "skillPaths"),
                        badge: "技能"
                    )
                )
            }
        }

        // 16. 健康活力日快照 (HealthDaySnapshotRecord)
        var healthDescriptor = FetchDescriptor<HealthDaySnapshotRecord>(sortBy: [SortDescriptor(\.day, order: .reverse)])
        healthDescriptor.fetchLimit = 30
        if let snapshots = try? context.fetch(healthDescriptor) {
            for h in snapshots {
                let df = DateFormatter()
                df.dateFormat = "M月d日"
                let dateStr = df.string(from: h.day)
                let sleepText = h.sleepHours.map { String(format: "睡眠 %.1fh", $0) } ?? ""
                let stepText = h.stepCount.map { "\(Int($0))步" } ?? ""
                let sub = [sleepText, stepText].filter { !$0.isEmpty }.joined(separator: " · ")
                batch.append(
                    SearchIndexDocument(
                        id: "health_\(dateStr)",
                        category: .health,
                        title: "\(dateStr) 健康体征与睡眠",
                        subtitle: sub.isEmpty ? "生命体征快照" : sub,
                        keywords: ["健康", "睡眠", "步数", "心率", "活力指数", "卡路里", "运动"],
                        date: h.day,
                        isSensitive: true,
                        route: .vault(destination: "healthData"),
                        badge: "健康"
                    )
                )
            }
        }

        engine.add(batch)
        totalIndexedCount = engine.count
        isIndexInitialized = true
    }

    // MARK: - 检索接口

    /// 执行全域索引检索
    public func search(query: String, category: SearchIndexCategory = .all, limit: Int = 30) -> [SearchIndexMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.searchResults = []
            return []
        }
        let matches = engine.search(query: trimmed, category: category, limit: limit)
        self.searchResults = matches
        return matches
    }

    // MARK: - 最近搜索历史

    private func loadRecentSearches() {
        self.recentSearches = UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? [
            "睡眠提醒", "快递取件", "月度账单", "常用密码", "深色模式", "数据备份"
        ]
    }

    public func addRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = recentSearches.filter { $0 != trimmed }
        current.insert(trimmed, at: 0)
        let capped = Array(current.prefix(12))
        recentSearches = capped
        UserDefaults.standard.set(capped, forKey: recentSearchesKey)
    }

    public func removeRecentSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
        UserDefaults.standard.set(recentSearches, forKey: recentSearchesKey)
    }

    public func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.set([], forKey: recentSearchesKey)
    }
}
