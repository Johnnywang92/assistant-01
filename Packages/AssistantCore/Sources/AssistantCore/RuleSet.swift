import Foundation

/// 关键词 → 名称 的映射（有序，先匹配先得）。
public struct KeywordMapping: Codable, Equatable, Sendable {
    public var keyword: String
    public var name: String

    public init(_ keyword: String, _ name: String) {
        self.keyword = keyword
        self.name = name
    }
}

/// 规则配置。全部是正则字符串，可序列化为 JSON，后续支持在 App 内编辑/覆盖。
/// 注意：正则作用于 `RuleEngine.normalize` 之后的文本（全角 ASCII 已转半角，如 "，" → ","、"：" → ":"）。
public struct RuleSet: Codable, Equatable, Sendable {
    public var pickupCodePattern: String
    public var locationPattern: String
    public var pickedUpStrongPattern: String
    public var pickedUpWeakPattern: String
    public var ignorePhrasePattern: String
    public var verificationPattern: String
    public var marketingPattern: String
    public var dataRemainingPattern: String
    public var dataUsedPattern: String
    public var dataPercentPattern: String
    public var couriers: [String]
    public var stations: [String]
    public var operatorSenders: [String: String]
    public var operatorKeywords: [KeywordMapping]

    public static let `default`: RuleSet = {
        let code = "[A-Za-z0-9]{1,12}(?:-[A-Za-z0-9]{1,8}){0,4}"
        let unit = "(GB|MB|KB|TB|G|M|K)"
        let num = "(\\d+(?:\\.\\d+)?)"
        let stop = "[^0-9,。;!?]"
        let locCore = "(?:驿站|快递柜|丰巢柜|丰巢|快递超市|超市|便利店|门卫室|门卫|服务站|服务点|自提点|代收点|快递点|网点|收发室|智能柜|大堂|传达室|物业中心|物业|店|柜)"
        let cabinetSuffix = "(?:[0-9A-Za-z一二三四五六七八九十区栋幢\\-]{1,8}号[柜箱架机库格]|主柜|副柜|[A-Za-z0-9]柜)?"
        return RuleSet(
            pickupCodePattern:
                "(?:取件码|提货码|取货码|取件号|提货号|取件编码|凭)\\s*(?:为|是|:)*\\s*(\(code)(?:\\s*[、,和及/]\\s*\(code))*)",
            locationPattern:
                "(?:已到达|已到|到达|送达|存入|放至|放入|放到|送至|已从|从|到|至|在)了?"
                + "([^,。;!?]{0,30}?\(locCore)\(cabinetSuffix)(?![\\u4e00-\\u9fa50-9]{0,2}(?:驿站|柜|店)))",
            pickedUpStrongPattern:
                "已取件|已取出|已被取走|取件成功|已被领取|已领取|已完成取件|已出库|已从.{1,30}取出",
            pickedUpWeakPattern:
                "已签收|签收成功",
            ignorePhrasePattern:
                "(?:如|若|如果)?(?:您)?(?:已经|已)(?:取件|取出|签收|领取)[^,。;]{0,8}?(?:请)?(?:忽略|无需理会)(?:本短信|此短信|此信息|本消息|此消息)?",
            verificationPattern:
                "验证码|校验码|动态码|动态密码|确认码",
            marketingPattern:
                "退订|回T|拒收请回复",
            dataRemainingPattern:
                "(?:剩余|还剩|可用|余量)\(stop){0,12}?\(num)\\s*\(unit)",
            dataUsedPattern:
                "(?:已使用|已用|使用了|已消耗)\(stop){0,12}?\(num)\\s*\(unit)",
            dataPercentPattern:
                "(?:已使用|已用|使用了|已达|达到|超过|已超)\(stop){0,12}?\(num)\\s*%",
            couriers: ["顺丰", "京东", "中通", "圆通", "韵达", "申通", "极兔", "邮政", "EMS", "德邦", "百世", "天天", "丹鸟", "菜鸟速递", "跨越"],
            stations: ["菜鸟驿站", "妈妈驿站", "兔喜生活", "兔喜", "丰巢", "近邻宝", "速递易", "递管家", "熊猫快收", "云柜", "中邮驿站", "邮政驿站", "京东快递柜", "日日顺", "快递超市", "菜鸟"],
            operatorSenders: ["10086": "中国移动", "10010": "中国联通", "10000": "中国电信", "10099": "中国广电"],
            operatorKeywords: [
                KeywordMapping("中国移动", "中国移动"),
                KeywordMapping("中国联通", "中国联通"),
                KeywordMapping("中国电信", "中国电信"),
                KeywordMapping("中国广电", "中国广电"),
                KeywordMapping("移动", "中国移动"),
                KeywordMapping("联通", "中国联通"),
                KeywordMapping("电信", "中国电信"),
            ]
        )
    }()
}
