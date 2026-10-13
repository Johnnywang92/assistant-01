import Foundation
import SwiftUI
import UIKit
import AssistantCore

/// 对话选项动作类型
public enum OptionActionType: Hashable, Equatable, Sendable {
    case applySetting        // 选中并应用设置
    case openManualSettings  // 中断对话并进入手动设置页
    case cancelSettings      // 中断/退出设置向导
    case planningAnswer      // 规划背景追问的芯片回答
}

/// 交互式气泡选项模型
public struct DialogueActionOption: Identifiable, Hashable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let icon: String?
    public let payload: String
    public let actionType: OptionActionType
    public let isPrimary: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        icon: String? = nil,
        payload: String,
        actionType: OptionActionType = .applySetting,
        isPrimary: Bool = false
    ) {
        self.id = id
        self.label = L10n.tr(label)
        self.icon = icon
        self.payload = payload
        self.actionType = actionType
        self.isPrimary = isPrimary
    }
}

/// 语音意图处理结果
struct VoiceIntentResult: Equatable {
    let reply: String
    var options: [DialogueActionOption]?
    var triggerOpenManualSettings: Bool
    var planningPlan: TaskPlanningPlan?
    var skillPlan: SkillPathDraft?

    init(
        reply: String,
        options: [DialogueActionOption]? = nil,
        triggerOpenManualSettings: Bool = false,
        planningPlan: TaskPlanningPlan? = nil,
        skillPlan: SkillPathDraft? = nil
    ) {
        self.reply = L10n.tr(reply)
        self.options = options
        self.triggerOpenManualSettings = triggerOpenManualSettings
        self.planningPlan = planningPlan
        self.skillPlan = skillPlan
    }
}

/// 设置向导当前步骤枚举 (1 ~ 7 步一条一条逐项交互问答)
public enum WizardStep: Int, CaseIterable, Sendable {
    case userTitle = 1       // 1. 对我的称呼
    case assistantName = 2   // 2. 助手的名字
    case voiceReply = 3      // 3. 语音朗读播报
    case assistantMode = 4   // 4. 运行模式 (提醒/安静/记录)
    case retention = 5       // 5. 对话记录留存周期 (7天/30天/不保留)
    case lifestyle = 6       // 6. 生活作息画像 (上班族/自由职业/学生)
    case theme = 7           // 7. 视觉主题与大字
}

/// 对话式基础设置中枢引擎（纯本地端侧离线执行，零网络延迟）
@MainActor
final class ConversationSettingsEngine {
    static let shared = ConversationSettingsEngine()

    /// 当前正在进行的向导步骤（nil 表示未在向导中）
    public var currentWizardStep: WizardStep? = nil

    private init() {}

    /// 判断输入是否命中设置相关的意图
    func isSettingsQuery(_ query: String) -> Bool {
        // 如果当前正处于向导交互流程中，用户的任何自定义输入都视为设置回答
        if currentWizardStep != nil {
            return true
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        let keywords = [
            "设置", "配置", "个性化", "改名", "叫我", "称呼", "声音", "朗读", "出声",
            "静音", "长辈模式", "大字模式", "字太小", "字号", "看不清", "背景", "壁纸",
            "模式", "别打扰", "悬浮球", "天气预警", "上班族", "自由职业", "学生",
            "保留", "留存", "保存", "7天", "30天", "聊天记录", "对话记录", "清空记录",
            "向导", "开始设置", "基础设置", "基础配置", "语言", "英文", "英语", "中文", "跟随系统",
            "settings", "configure", "call me", "mute", "unmute", "senior mode", "large text",
            "quiet mode", "alert mode", "record mode", "clear history", "setup wizard",
            "language", "english", "chinese"
        ]
        return keywords.contains { lower.contains($0) }
    }

    /// 自然语言解析并处理设置命令
    func processSettingsCommand(_ query: String) -> VoiceIntentResult? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // MARK: - 0. 如果正处于向导流程中，优先处理用户的单步回答或自由文本自定义
        if let step = currentWizardStep {
            // A. 手动设置中断指令
            if text.contains("手动设置") || text == "打开设置" || text.contains("详细设置") || text.contains("系统设置") || text == "去设置" {
                currentWizardStep = nil
                return VoiceIntentResult(
                    reply: "已为你中断对话向导，打开系统手动详细设置页面。",
                    triggerOpenManualSettings: true
                )
            }

            // B. 退出向导指令
            if text == "退出" || text == "退出设置" || text == "中断设置" || text == "取消" || text == "不用了" || text == "结束设置" || text == "结束向导" {
                currentWizardStep = nil
                return VoiceIntentResult(
                    reply: "好的，已为你退出基础设置向导。随时有需要对我说「设置」可重新开启！"
                )
            }

            // C. 跳过当前步骤
            if text == "跳过" || text == "跳过此步" || text == "下一个" || text == "下一步" {
                return advanceWizard(from: step, skipped: true)
            }

            // D. 针对当前步骤解析用户输入的自定义内容并流转到下一步
            return handleCustomInputForWizard(step: step, text: text)
        }

        // MARK: - 1. 顶层全局指令处理 (未在向导中时的单点设置与入口)

        // 手动设置中断指令
        if text.contains("手动设置") || text == "打开设置" || text.contains("详细设置") || text.contains("系统设置") || text == "去设置" {
            currentWizardStep = nil
            return VoiceIntentResult(
                reply: "已为你打开手动详细设置页面。你可以在完整的表单中自由配置全部选项。",
                triggerOpenManualSettings: true
            )
        }

        // 取消/退出向导指令
        if text == "退出设置" || text == "中断设置" || text == "取消设置" || text == "不用了" || text == "结束设置" {
            currentWizardStep = nil
            return VoiceIntentResult(
                reply: "好的，已为你退出设置向导，有需要随时对我说「设置」或直接告诉我你想调整的内容。"
            )
        }

        // 启动基础设置向导 (一条一条地交互选择)
        if text.contains("向导") || text.contains("基础设置") || text.contains("基础配置") || text == "设置" || text == "配置" || text.contains("开始配置") || text.contains("重新设置") {
            return renderWizardStep(.userTitle)
        }

        // 单点快速命令：对用户的称呼 (User Title)
        if let title = extractUserTitle(from: text) {
            AppSettings.userTitle = title
            Haptic.success()
            return VoiceIntentResult(
                reply: "好的\(title)，已记下啦！以后我就会称呼你为「\(title)」。",
                options: commonSettingsFollowUpOptions()
            )
        }

        // 单点快速命令：助手名称修改 (Assistant Name)
        if let name = extractAssistantName(from: text) {
            AppSettings.assistantName = name
            Haptic.success()
            return VoiceIntentResult(
                reply: "没问题！我的名字已更新为「\(name)」。以后你可以叫我「\(name)」。",
                options: commonSettingsFollowUpOptions()
            )
        }

        // 单点快速命令：语音回复与朗读 (TTS)
        if text.contains("别出声") || text.contains("不要朗读") || text.contains("关闭朗读") || text.contains("静音模式") || text.contains("关掉声音") || text.contains("关闭语音回答") || text.contains("安静点") {
            AppSettings.voiceReplyEnabled = false
            Haptic.success()
            return VoiceIntentResult(
                reply: "已关闭语音出声朗读，后续对话我将保持文字静音回复。",
                options: commonSettingsFollowUpOptions()
            )
        }
        if text.contains("开启朗读") || text.contains("出声朗读") || text.contains("打开声音") || text.contains("开启语音回答") || text.contains("读出来") {
            AppSettings.voiceReplyEnabled = true
            Haptic.success()
            return VoiceIntentResult(
                reply: "已开启语音出声朗读，之后回答时我会为你清晰读出来。",
                options: commonSettingsFollowUpOptions()
            )
        }

        // 单点快速命令：长辈关怀模式 (Senior Mode)
        if text.contains("开启长辈") || text.contains("长辈模式") || text.contains("大字模式") || text.contains("字太小") || text.contains("看不太清") || text.contains("放大字") {
            SeniorModeManager.shared.isSeniorModeEnabled = true
            Haptic.success()
            return VoiceIntentResult(
                reply: "已为您开启「老年人大字关怀模式」！文字与按钮已全局放大，对比度加深，现在看着舒服些了吗？",
                options: commonSettingsFollowUpOptions()
            )
        }
        if text.contains("关闭长辈") || text.contains("退出长辈") || text.contains("恢复正常字体") || text.contains("关闭大字") {
            SeniorModeManager.shared.isSeniorModeEnabled = false
            Haptic.success()
            return VoiceIntentResult(
                reply: "已关闭长辈关怀模式，恢复为标准界面排版。",
                options: commonSettingsFollowUpOptions()
            )
        }

        // 单点快速命令：运行模式 (Assistant Mode)
        if text.contains("提醒模式") {
            AppSettings.currentMode = .alert
            Haptic.success()
            return VoiceIntentResult(
                reply: "已切换到「提醒模式」，遇到事项变更或到达地点时会主动通知你。",
                options: commonSettingsFollowUpOptions()
            )
        }
        if text.contains("安静模式") || text.contains("静默模式") {
            AppSettings.currentMode = .quiet
            Haptic.success()
            return VoiceIntentResult(
                reply: "已切换到「安静模式」，不主动弹出横幅打扰你。",
                options: commonSettingsFollowUpOptions()
            )
        }
        if text.contains("记录模式") || text.contains("备忘模式") {
            AppSettings.currentMode = .recordOnly
            Haptic.success()
            return VoiceIntentResult(
                reply: "已切换到「记录模式」，专注于生活数据归档与备忘。",
                options: commonSettingsFollowUpOptions()
            )
        }

        // 单点快速命令：对话记录留存 (Dialogue Retention)
        if text.contains("保留7天") || text.contains("留存7天") || text.contains("保存7天") {
            AppSettings.dialogueRetentionPolicy = .sevenDays
            DialogueHistoryManager.shared.cleanExpiredRecords(context: Persistence.shared.mainContext)
            Haptic.success()
            return VoiceIntentResult(
                reply: "已开启「自动保留 7 天」！最近 7 天内的本地对话将安全留存，超期记录将在后台自动滚动清理。",
                options: commonSettingsFollowUpOptions()
            )
        }
        if text.contains("保留30天") || text.contains("留存30天") || text.contains("保存30天") {
            AppSettings.dialogueRetentionPolicy = .thirtyDays
            DialogueHistoryManager.shared.cleanExpiredRecords(context: Persistence.shared.mainContext)
            Haptic.success()
            return VoiceIntentResult(
                reply: "已开启「自动保留 30 天」！最近 30 天内的本地对话将安全留存，超期记录会在后台自动滚动清理。",
                options: commonSettingsFollowUpOptions()
            )
        }
        if text.contains("不保留对话") || text.contains("不保存对话") || text.contains("关闭对话保留") {
            AppSettings.dialogueRetentionPolicy = .none
            DialogueHistoryManager.shared.clearAll(context: Persistence.shared.mainContext)
            Haptic.success()
            return VoiceIntentResult(
                reply: "已切换为「不保留 (即用即走)」，离开对话界面即刻释放，保障极致隐私与零存储占用。",
                options: commonSettingsFollowUpOptions()
            )
        }
        if text.contains("清空对话") || text.contains("清空聊天") || text.contains("删除对话记录") || text.contains("清除对话") {
            DialogueHistoryManager.shared.clearAll(context: Persistence.shared.mainContext)
            Haptic.success()
            return VoiceIntentResult(
                reply: "已为你清空所有本地存储的对话记录。",
                options: commonSettingsFollowUpOptions()
            )
        }

        // 单点快速命令：应用语言切换 (Language Switch)
        let lowerText = text.lowercased()
        if text.contains("切换英文") || text.contains("改成英文") || text.contains("设为英文") || text.contains("用英文") || text.contains("切换英语") || lowerText.contains("switch to english") || lowerText.contains("in english") || lowerText == "english" {
            LanguageManager.shared.selectedLanguage = .en
            Haptic.success()
            return VoiceIntentResult(
                reply: "Switched app language to English! Interface, notifications, and voice assistant are now in English.",
                options: commonSettingsFollowUpOptions()
            )
        }
        if text.contains("切换中文") || text.contains("改成中文") || text.contains("设为中文") || text.contains("用中文") || text.contains("简体中文") || lowerText.contains("switch to chinese") || lowerText.contains("in chinese") || lowerText == "chinese" {
            LanguageManager.shared.selectedLanguage = .zhHans
            Haptic.success()
            return VoiceIntentResult(
                reply: "已将应用语言切换为「简体中文」！界面、通知与语音助手已同步更新。",
                options: commonSettingsFollowUpOptions()
            )
        }
        if text.contains("语言") || lowerText.contains("language") {
            let options = [
                DialogueActionOption(label: "🌐 跟随系统 / Follow System", payload: "set_lang:system"),
                DialogueActionOption(label: "🇨🇳 简体中文", payload: "set_lang:zh-Hans"),
                DialogueActionOption(label: "🇺🇸 English", payload: "set_lang:en"),
                DialogueActionOption(label: "⚙️ 手动进入详细设置", icon: "gearshape.fill", payload: "manual_settings", actionType: .openManualSettings)
            ]
            return VoiceIntentResult(
                reply: L10n.choose(
                    "请选择你想要切换的 App 语言（当前：\(LanguageManager.shared.selectedLanguage.displayName)）：",
                    "Please choose your preferred app language (current: \(LanguageManager.shared.selectedLanguage.displayName)):"
                ),
                options: options
            )
        }

        // 通用兜底：启动基础设置向导
        if text.contains("设置") || text.contains("配置") || text.contains("个性化") || lowerText.contains("settings") {
            return renderWizardStep(.userTitle)
        }

        return nil
    }

    // MARK: - 步骤式设置向导 (Step-by-Step Wizard)

    /// 渲染向导特定步骤的提问气泡与预设选项
    func renderWizardStep(_ step: WizardStep, prefixMessage: String = "") -> VoiceIntentResult {
        currentWizardStep = step

        switch step {
        case .userTitle:
            let text = """
            \(prefixMessage)📋【基础设置向导 · 第 1/7 步：对你的称呼】
            你想让我平时怎么称呼你呢？请点选下方预设推荐；如果没有合适的，也可以直接在输入框打字或语音告诉我（如：“叫我王总”、“老板”）：
            """
            let options = [
                DialogueActionOption(label: "老板 🧑‍💼", payload: "wizard_set:title:老板"),
                DialogueActionOption(label: "主人 🏰", payload: "wizard_set:title:主人"),
                DialogueActionOption(label: "您 🍵", payload: "wizard_set:title:您"),
                DialogueActionOption(label: "你 (默认) 🤝", payload: "wizard_set:title:你"),
                DialogueActionOption(label: "跳过此步 ⏭️", payload: "wizard_step:2"),
                DialogueActionOption(label: "⚙️ 中断，手动设置", payload: "manual_settings", actionType: .openManualSettings),
                DialogueActionOption(label: "✕ 退出向导", payload: "cancel_settings", actionType: .cancelSettings)
            ]
            return VoiceIntentResult(reply: text, options: options)

        case .assistantName:
            let text = """
            \(prefixMessage)📋【基础设置向导 · 第 2/7 步：给助手命名】
            你想给我起个什么专属名字呢？请点选下方推荐；如果没有合适的，可直接打字或对我说出你想给我起的名字（如：“小千”、“大白”）：
            """
            let options = [
                DialogueActionOption(label: "小助 🤖 (默认)", payload: "wizard_set:name:小助"),
                DialogueActionOption(label: "管家 👔", payload: "wizard_set:name:管家"),
                DialogueActionOption(label: "贾维斯 💻", payload: "wizard_set:name:贾维斯"),
                DialogueActionOption(label: "星期五 📅", payload: "wizard_set:name:星期五"),
                DialogueActionOption(label: "小秘书 💼", payload: "wizard_set:name:小秘书"),
                DialogueActionOption(label: "跳过此步 ⏭️", payload: "wizard_step:3"),
                DialogueActionOption(label: "⚙️ 中断，手动设置", payload: "manual_settings", actionType: .openManualSettings),
                DialogueActionOption(label: "✕ 退出向导", payload: "cancel_settings", actionType: .cancelSettings)
            ]
            return VoiceIntentResult(reply: text, options: options)

        case .voiceReply:
            let text = """
            \(prefixMessage)📋【基础设置向导 · 第 3/7 步：声音与语音朗读】
            平时对话回答你的问题时，是否需要我通过语音为你读出回答？
            """
            let options = [
                DialogueActionOption(label: "🔊 开启语音朗读 (推荐)", payload: "wizard_set:voice:true"),
                DialogueActionOption(label: "🔇 静音文字回复 (更安静)", payload: "wizard_set:voice:false"),
                DialogueActionOption(label: "跳过此步 ⏭️", payload: "wizard_step:4"),
                DialogueActionOption(label: "⚙️ 中断，手动设置", payload: "manual_settings", actionType: .openManualSettings),
                DialogueActionOption(label: "✕ 退出向导", payload: "cancel_settings", actionType: .cancelSettings)
            ]
            return VoiceIntentResult(reply: text, options: options)

        case .assistantMode:
            let text = """
            \(prefixMessage)📋【基础设置向导 · 第 4/7 步：助手运行模式】
            你希望我以什么样的打扰频率为你服务？
            """
            let options = [
                DialogueActionOption(label: "🔔 提醒模式 (主动提醒待办与到达)", payload: "wizard_set:mode:alert"),
                DialogueActionOption(label: "🌙 安静模式 (不弹横幅，完全静默)", payload: "wizard_set:mode:quiet"),
                DialogueActionOption(label: "📝 记录模式 (专注备忘，不催办)", payload: "wizard_set:mode:recordOnly"),
                DialogueActionOption(label: "跳过此步 ⏭️", payload: "wizard_step:5"),
                DialogueActionOption(label: "⚙️ 中断，手动设置", payload: "manual_settings", actionType: .openManualSettings),
                DialogueActionOption(label: "✕ 退出向导", payload: "cancel_settings", actionType: .cancelSettings)
            ]
            return VoiceIntentResult(reply: text, options: options)

        case .retention:
            let text = """
            \(prefixMessage)📋【基础设置向导 · 第 5/7 步：对话记录保留周期】
            我们聊天的文字记录希望在本地自动保留多久？超期将在后台自动滚动清理：
            """
            let options = [
                DialogueActionOption(label: "📅 自动保留 7 天 (隐私清爽)", payload: "wizard_set:retention:7days"),
                DialogueActionOption(label: "🗓️ 自动保留 30 天 (推荐 · 便于回溯)", payload: "wizard_set:retention:30days"),
                DialogueActionOption(label: "🔒 不保留 (即用即走 · 极度私密)", payload: "wizard_set:retention:none"),
                DialogueActionOption(label: "♾️ 永久保留", payload: "wizard_set:retention:forever"),
                DialogueActionOption(label: "跳过此步 ⏭️", payload: "wizard_step:6"),
                DialogueActionOption(label: "⚙️ 中断，手动设置", payload: "manual_settings", actionType: .openManualSettings),
                DialogueActionOption(label: "✕ 退出向导", payload: "cancel_settings", actionType: .cancelSettings)
            ]
            return VoiceIntentResult(reply: text, options: options)

        case .lifestyle:
            let text = """
            \(prefixMessage)📋【基础设置向导 · 第 6/7 步：生活作息与身份】
            你的主要生活作息画像是？小助将根据你的日程时段动态优化事项优先级：
            """
            let options = [
                DialogueActionOption(label: "💼 上班族 (工作日通勤优先)", payload: "wizard_set:lifestyle:officeWorker"),
                DialogueActionOption(label: "💻 自由职业 (全天弹性节律)", payload: "wizard_set:lifestyle:flexible"),
                DialogueActionOption(label: "🎓 学生 (周中课业与假期分段)", payload: "wizard_set:lifestyle:student"),
                DialogueActionOption(label: "跳过此步 ⏭️", payload: "wizard_step:7"),
                DialogueActionOption(label: "⚙️ 中断，手动设置", payload: "manual_settings", actionType: .openManualSettings),
                DialogueActionOption(label: "✕ 退出向导", payload: "cancel_settings", actionType: .cancelSettings)
            ]
            return VoiceIntentResult(reply: text, options: options)

        case .theme:
            let text = """
            \(prefixMessage)📋【基础设置向导 · 第 7/7 步：视觉主题与字号】
            最后一步，选择你偏好的界面壁纸主题风格或字号：
            """
            let options = [
                DialogueActionOption(label: "🌌 暗夜星空主题", payload: "wizard_set:theme:midnight"),
                DialogueActionOption(label: "✨ 极光晨曦主题", payload: "wizard_set:theme:aurora"),
                DialogueActionOption(label: "🍃 薄荷微风主题", payload: "wizard_set:theme:mint"),
                DialogueActionOption(label: "🌅 暮光暖阳主题", payload: "wizard_set:theme:sunset"),
                DialogueActionOption(label: "👓 开启长辈大字模式", payload: "wizard_set:theme:senior"),
                DialogueActionOption(label: "🎉 完成配置", payload: "wizard_complete")
            ]
            return VoiceIntentResult(reply: text, options: options)
        }
    }

    /// 处理用户在当前步骤下的手动打字或自由语音输入
    private func handleCustomInputForWizard(step: WizardStep, text: String) -> VoiceIntentResult {
        switch step {
        case .userTitle:
            let candidate = (extractUserTitle(from: text) ?? text)
                .replacingOccurrences(of: "叫我", with: "")
                .replacingOccurrences(of: "以后叫我", with: "")
                .replacingOccurrences(of: "称呼我为", with: "")
                .replacingOccurrences(of: "称呼我", with: "")
                .replacingOccurrences(of: "我叫", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = candidate.isEmpty ? "你" : candidate
            AppSettings.userTitle = title
            Haptic.success()
            return advanceWizard(from: .userTitle, skipped: false, savedMessage: "好的「\(title)」，已为你保存称呼！\n\n")

        case .assistantName:
            let candidate = (extractAssistantName(from: text) ?? text)
                .replacingOccurrences(of: "叫你", with: "")
                .replacingOccurrences(of: "名字叫", with: "")
                .replacingOccurrences(of: "给你起名叫", with: "")
                .replacingOccurrences(of: "起名叫", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = candidate.isEmpty ? "小助" : candidate
            AppSettings.assistantName = name
            Haptic.success()
            return advanceWizard(from: .assistantName, skipped: false, savedMessage: "太棒了！我的名字已更新为「\(name)」。\n\n")

        case .voiceReply:
            let isMute = text.contains("不") || text.contains("关") || text.contains("静") || text.contains("别")
            AppSettings.voiceReplyEnabled = !isMute
            Haptic.success()
            let msg = isMute ? "已为你设为静音文字回复！\n\n" : "已为你开启语音出声朗读！\n\n"
            return advanceWizard(from: .voiceReply, skipped: false, savedMessage: msg)

        case .assistantMode:
            if text.contains("安静") {
                AppSettings.currentMode = .quiet
            } else if text.contains("记录") || text.contains("备忘") {
                AppSettings.currentMode = .recordOnly
            } else {
                AppSettings.currentMode = .alert
            }
            Haptic.success()
            return advanceWizard(from: .assistantMode, skipped: false, savedMessage: "运行模式已保存为「\(AppSettings.currentMode.rawValue)」！\n\n")

        case .retention:
            if text.contains("7") {
                AppSettings.dialogueRetentionPolicy = .sevenDays
            } else if text.contains("30") {
                AppSettings.dialogueRetentionPolicy = .thirtyDays
            } else if text.contains("不") || text.contains("零") || text.contains("无") {
                AppSettings.dialogueRetentionPolicy = .none
            } else if text.contains("永久") || text.contains("一直") {
                AppSettings.dialogueRetentionPolicy = .forever
            } else {
                AppSettings.dialogueRetentionPolicy = .thirtyDays
            }
            DialogueHistoryManager.shared.cleanExpiredRecords(context: Persistence.shared.mainContext)
            Haptic.success()
            return advanceWizard(from: .retention, skipped: false, savedMessage: "已设定对话保留策略为「\(AppSettings.dialogueRetentionPolicy.displayName)」！\n\n")

        case .lifestyle:
            if text.contains("自由") || text.contains("弹性") {
                UserDefaults.standard.set(UserLifestyleProfile.flexible.rawValue, forKey: "user_lifestyle_profile")
            } else if text.contains("学生") {
                UserDefaults.standard.set(UserLifestyleProfile.student.rawValue, forKey: "user_lifestyle_profile")
            } else {
                UserDefaults.standard.set(UserLifestyleProfile.officeWorker.rawValue, forKey: "user_lifestyle_profile")
            }
            Haptic.success()
            return advanceWizard(from: .lifestyle, skipped: false, savedMessage: "已设定你的日常作息画像！\n\n")

        case .theme:
            if text.contains("暗夜") || text.contains("黑") {
                AppBackgroundManager.shared.currentStyle = .midnight
            } else if text.contains("极光") {
                AppBackgroundManager.shared.currentStyle = .aurora
            } else if text.contains("薄荷") || text.contains("绿") {
                AppBackgroundManager.shared.currentStyle = .mint
            } else if text.contains("暮光") || text.contains("暖") {
                AppBackgroundManager.shared.currentStyle = .sunset
            } else if text.contains("大字") || text.contains("长辈") {
                SeniorModeManager.shared.isSeniorModeEnabled = true
            }
            Haptic.success()
            return renderWizardComplete(prefixMessage: "界面主题与字号已应用！\n\n")
        }
    }

    /// 向导步进控制器
    private func advanceWizard(from step: WizardStep, skipped: Bool = false, savedMessage: String = "") -> VoiceIntentResult {
        let prefix = skipped ? "已跳过该项配置。\n\n" : savedMessage
        let nextRaw = step.rawValue + 1
        if let nextStep = WizardStep(rawValue: nextRaw) {
            return renderWizardStep(nextStep, prefixMessage: prefix)
        } else {
            return renderWizardComplete(prefixMessage: prefix)
        }
    }

    /// 向导完成总结界面
    func renderWizardComplete(prefixMessage: String = "") -> VoiceIntentResult {
        currentWizardStep = nil
        Haptic.success()

        let profileRaw = UserDefaults.standard.string(forKey: "user_lifestyle_profile") ?? "上班族"
        let profileName = UserLifestyleProfile(rawValue: profileRaw)?.shortTitle ?? profileRaw
        let themeName = AppBackgroundManager.shared.currentStyle.rawValue

        let text = """
        \(prefixMessage)🎉 恭喜你！基础配置已全部完成！
        当前你的专属配置如下：
        • 对你的称呼：「\(AppSettings.userTitle)」
        • 助手名字：「\(AppSettings.assistantName)」
        • 语音朗读：\(AppSettings.voiceReplyEnabled ? "已开启" : "已静音")
        • 运行模式：\(AppSettings.currentMode.rawValue)
        • 对话记录：\(AppSettings.dialogueRetentionPolicy.shortTitle)
        • 作息画像：\(profileName)
        • 主题外观：\(themeName)

        现在，随时对我说出你的待办事项、记账、用车计划或出行规划吧！
        """

        let options = [
            DialogueActionOption(label: "⛺️ 露营出行规划", icon: "tent.fill", payload: "plan:camping"),
            DialogueActionOption(label: "📦 搬家任务规划", icon: "box.truck.fill", payload: "plan:moving"),
            DialogueActionOption(label: "⚙️ 重新进入设置向导", icon: "arrow.counterclockwise", payload: "wizard:start"),
            DialogueActionOption(label: "⚙️ 手动详细设置", icon: "gearshape.fill", payload: "manual_settings", actionType: .openManualSettings)
        ]

        return VoiceIntentResult(reply: text, options: options)
    }

    /// 应用卡片按钮的 Payload
    func applyOption(payload: String) -> VoiceIntentResult {
        Haptic.light()

        // 1. 手动设置中断
        if payload == "manual_settings" {
            currentWizardStep = nil
            return VoiceIntentResult(
                reply: "已为你打开手动详细设置界面，可直接在完整表单中自由配置。",
                triggerOpenManualSettings: true
            )
        }

        // 2. 取消/中断设置
        if payload == "cancel_settings" {
            currentWizardStep = nil
            return VoiceIntentResult(
                reply: "好的，已为你退出设置向导。有什么生活琐事随时叫我！"
            )
        }

        // 3. 启动或跳步骤
        if payload.hasPrefix("set_lang:") {
            let code = String(payload.dropFirst("set_lang:".count))
            let lang = AppLanguage(rawValue: code) ?? .system
            LanguageManager.shared.selectedLanguage = lang
            Haptic.success()
            return VoiceIntentResult(
                reply: L10n.choose(
                    "已将应用语言切换为「\(lang.displayName)」！",
                    "App language switched to \"\(lang.displayName)\"!"
                ),
                options: commonSettingsFollowUpOptions()
            )
        }

        if payload == "wizard:start" || payload == "menu_main" {
            return renderWizardStep(.userTitle)
        }

        if payload == "wizard_complete" {
            return renderWizardComplete()
        }

        if payload.hasPrefix("wizard_step:") {
            let numStr = String(payload.dropFirst("wizard_step:".count))
            let num = Int(numStr) ?? 1
            if let step = WizardStep(rawValue: num) {
                return renderWizardStep(step)
            } else {
                return renderWizardComplete()
            }
        }

        // 4. 执行向导各步骤预设点选并流转到下一步
        if payload.hasPrefix("wizard_set:title:") {
            let title = String(payload.dropFirst("wizard_set:title:".count))
            AppSettings.userTitle = title
            return advanceWizard(from: .userTitle, skipped: false, savedMessage: "好的「\(title)」，已为你保存称呼！\n\n")
        }

        if payload.hasPrefix("wizard_set:name:") {
            let name = String(payload.dropFirst("wizard_set:name:".count))
            AppSettings.assistantName = name
            return advanceWizard(from: .assistantName, skipped: false, savedMessage: "好嘞！我的名字已更新为「\(name)」。\n\n")
        }

        if payload.hasPrefix("wizard_set:voice:") {
            let val = payload.contains("true")
            AppSettings.voiceReplyEnabled = val
            let msg = val ? "已开启语音出声朗读！\n\n" : "已切换为静音文字回复！\n\n"
            return advanceWizard(from: .voiceReply, skipped: false, savedMessage: msg)
        }

        if payload.hasPrefix("wizard_set:mode:") {
            let mode = String(payload.dropFirst("wizard_set:mode:".count))
            if mode == "quiet" {
                AppSettings.currentMode = .quiet
            } else if mode == "recordOnly" {
                AppSettings.currentMode = .recordOnly
            } else {
                AppSettings.currentMode = .alert
            }
            return advanceWizard(from: .assistantMode, skipped: false, savedMessage: "运行模式已保存为「\(AppSettings.currentMode.rawValue)」！\n\n")
        }

        if payload.hasPrefix("wizard_set:retention:") {
            let ret = String(payload.dropFirst("wizard_set:retention:".count))
            if ret == "7days" {
                AppSettings.dialogueRetentionPolicy = .sevenDays
            } else if ret == "none" {
                AppSettings.dialogueRetentionPolicy = .none
            } else if ret == "forever" {
                AppSettings.dialogueRetentionPolicy = .forever
            } else {
                AppSettings.dialogueRetentionPolicy = .thirtyDays
            }
            DialogueHistoryManager.shared.cleanExpiredRecords(context: Persistence.shared.mainContext)
            return advanceWizard(from: .retention, skipped: false, savedMessage: "已设定对话保留策略为「\(AppSettings.dialogueRetentionPolicy.displayName)」！\n\n")
        }

        if payload.hasPrefix("wizard_set:lifestyle:") {
            let key = String(payload.dropFirst("wizard_set:lifestyle:".count))
            if let profile = UserLifestyleProfile.allCases.first(where: { "\($0)" == key || $0.rawValue == key }) {
                UserDefaults.standard.set(profile.rawValue, forKey: "user_lifestyle_profile")
            }
            return advanceWizard(from: .lifestyle, skipped: false, savedMessage: "已保存你的日常作息画像！\n\n")
        }

        if payload.hasPrefix("wizard_set:theme:") {
            let t = String(payload.dropFirst("wizard_set:theme:".count))
            if t == "senior" {
                SeniorModeManager.shared.isSeniorModeEnabled = true
            } else if t == "aurora" {
                AppBackgroundManager.shared.currentStyle = .aurora
            } else if t == "mint" {
                AppBackgroundManager.shared.currentStyle = .mint
            } else if t == "sunset" {
                AppBackgroundManager.shared.currentStyle = .sunset
            } else {
                AppBackgroundManager.shared.currentStyle = .midnight
            }
            return renderWizardComplete(prefixMessage: "界面主题与字号已应用！\n\n")
        }

        return renderWizardStep(.userTitle)
    }

    /// 设置完成后的快捷延续操作选项
    private func commonSettingsFollowUpOptions() -> [DialogueActionOption] {
        [
            DialogueActionOption(label: "⚙️ 进入基础设置向导", icon: "slider.horizontal.3", payload: "wizard:start"),
            DialogueActionOption(label: "⚙️ 手动进入详细设置", icon: "gearshape.fill", payload: "manual_settings", actionType: .openManualSettings),
            DialogueActionOption(label: "✕ 完成并退出", icon: "checkmark", payload: "cancel_settings", actionType: .cancelSettings)
        ]
    }

    // MARK: - 意图槽位抽取器 (Regex / Keyword Extraction)

    private func extractUserTitle(from text: String) -> String? {
        let prefixes = ["以后叫我", "叫我", "称呼我为", "称呼我", "对我称呼", "我的名字是", "我叫"]
        for p in prefixes {
            if let range = text.range(of: p) {
                let candidate = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "吧", with: "")
                    .replacingOccurrences(of: "就可以了", with: "")
                    .replacingOccurrences(of: "就好", with: "")
                    .replacingOccurrences(of: "。", with: "")
                    .replacingOccurrences(of: "！", with: "")
                    .replacingOccurrences(of: "「", with: "")
                    .replacingOccurrences(of: "」", with: "")
                    .replacingOccurrences(of: "“", with: "")
                    .replacingOccurrences(of: "”", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "'", with: "")
                if !candidate.isEmpty && candidate.count <= 10 {
                    return candidate
                }
            }
        }
        return nil
    }

    private func extractAssistantName(from text: String) -> String? {
        let patterns = [
            "把你名字改成", "把你的名字改成", "你的名字叫", "你以后叫",
            "助手改名叫", "助手改名", "改名叫做", "改名叫"
        ]
        for p in patterns {
            if let range = text.range(of: p) {
                let candidate = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "吧", with: "")
                    .replacingOccurrences(of: "就可以了", with: "")
                    .replacingOccurrences(of: "就好", with: "")
                    .replacingOccurrences(of: "。", with: "")
                    .replacingOccurrences(of: "！", with: "")
                    .replacingOccurrences(of: "「", with: "")
                    .replacingOccurrences(of: "」", with: "")
                    .replacingOccurrences(of: "“", with: "")
                    .replacingOccurrences(of: "”", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "'", with: "")
                if !candidate.isEmpty && candidate.count <= 10 {
                    return candidate
                }
            }
        }
        return nil
    }
}
