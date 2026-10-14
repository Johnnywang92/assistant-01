import Foundation

/// 对话意图路由（纯函数、无平台依赖，下沉 AssistantCore 供测试钉住行为）。
///
/// **为什么需要它。**
/// 1. 规则直出：确定性查询（快递码、查账、查地点）直接读库由规则引擎答复，避免小模型对金额/日期产生幻觉；
/// 2. 闲聊旁路：打招呼/感谢/幽默等问候不加载 12 段生活档案，省掉昂贵的全量 prefill，极大降低首 token 延迟。
public enum DialogueRouter: Sendable {

    /// 明确的查询类指令：应直接路由到规则引擎读取 SwiftData 返回，
    /// 确保金额、日期和数据库记录不被端侧小模型猜错。
    public static func shouldRouteQueryToRules(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let lookupKeywords = [
            "快递", "取件", "包裹", "流量", "话费", "哪里", "地点", "开销", "支出",
            "消费", "花销", "账单", "账本", "花了多少", "消费了多少", "纪念日", "生日",
            "倒数", "待办", "要做", "安排", "出门", "防丢", "忘带", "随身", "日报",
            "周报", "月报", "年报", "年度总结", "本年总结", "复盘", "今天总结", "今日总结", "本周总结", "本月总结"
        ]
        guard lookupKeywords.contains(where: text.contains) else { return false }

        let questionMarkers = [
            "多少", "几笔", "吗", "？", "?", "是不是", "有没有", "哪些", "什么",
            "查", "看", "今天", "昨天", "本月", "本周", "最近", "当前", "哪", "哪里", "在哪"
        ]
        return questionMarkers.contains(where: text.contains)
    }

    /// 闲聊与情绪交流：不需要加载 12 段生活档案，提示词走轻量人格与规则即可。
    /// 涵盖问候、道谢、调侃、情绪抒发、自我介绍等。
    public static func isSmallTalk(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }

        // 1. 助手身份与自我介绍（优先匹配，即使包含“做什么”等字样）
        let identity = [
            "你是谁", "你叫什么", "你能做什么", "你能干嘛", "你有什么功能", "自我介绍", "介绍一下自己"
        ]
        if identity.contains(where: { text.contains($0) }) {
            return true
        }

        // 2. 感谢与礼貌
        let gratitude = [
            "谢谢", "多谢", "感谢", "辛苦了", "真棒", "太棒了", "你真厉害", "真聪明",
            "真好", "你真好", "客气", "不客气", "再见", "拜拜", "byebye", "bye"
        ]
        if gratitude.contains(where: { text.contains($0) }) {
            return true
        }

        // 3. 情绪互动与幽默
        let casualInteractions = [
            "好无聊", "今天好累", "好开心", "心情不好", "好难过", "讲个笑话", "讲个故事",
            "唱首歌", "陪我聊聊", "陪我聊天", "陪我说话", "聊天吧", "聊会儿天", "无聊"
        ]
        if casualInteractions.contains(where: { text.contains($0) }) {
            return true
        }

        // 4. 硬防线：只要命中具体生活业务实体或明确动作词，绝不走闲聊旁路
        let domainKeywords = [
            "快递", "取件", "包裹", "驿站", "记账", "记一笔", "记一下", "账", "花销",
            "消费", "支出", "开销", "花了", "买", "付", "待办", "提醒", "日程",
            "安排", "清单", "计划", "纪念日", "生日", "倒数", "收纳", "放在", "放在哪",
            "在哪里", "地点", "药", "服药", "习惯", "证件", "护照", "宠物", "爱车",
            "保养", "育儿", "孩子", "宝宝", "保质期", "订阅", "备忘", "录音", "日报",
            "周报", "月报", "总结", "干嘛", "要做什么", "有什么事"
        ]
        if domainKeywords.contains(where: text.contains) {
            return false
        }

        // 5. 纯问候与寒暄（剔除常见助手称谓与语气助词后匹配）
        let greetings = [
            "你好", "您好", "早", "早上好", "早安", "中午好", "下午好", "晚上好",
            "晚安", "哈喽", "嗨", "hi", "hello", "hey"
        ]
        var cleaned = text
        for token in ["小助", "助手", "小助手", "管家", "呀", "啊", "呢", "啦", "哈", "，", ",", "！", "!", "。", "."] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if greetings.contains(cleaned) {
            return true
        }

        return false
    }
}
