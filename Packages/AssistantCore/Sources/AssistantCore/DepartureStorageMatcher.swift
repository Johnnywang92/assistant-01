import Foundation

/// 出门清单物品与收纳档案的智能关联匹配器
public enum DepartureStorageMatcher {
    /// 在生活收纳档案中为出门物品寻找最吻合的存放位置记录
    public static func findMatch(
        itemTitle: String,
        storedItems: [DepartureStoredItemSnapshot]
    ) -> DepartureStoredItemSnapshot? {
        let cleanedTitle = cleanItemTitle(itemTitle)
        guard !cleanedTitle.isEmpty, !storedItems.isEmpty else { return nil }

        // 1. 完全精确匹配（去除标点与首尾空格）
        if let exact = storedItems.first(where: { cleanItemTitle($0.name) == cleanedTitle }) {
            return exact
        }

        // 2. 双向包含匹配（过滤掉单字符泛词）
        let candidates = storedItems.filter { stored in
            let cleanedStored = cleanItemTitle(stored.name)
            guard cleanedStored.count >= 2, cleanedTitle.count >= 2 else { return false }
            return cleanedTitle.contains(cleanedStored) || cleanedStored.contains(cleanedTitle)
        }

        if let best = candidates.min(by: {
            abs($0.name.count - cleanedTitle.count) < abs($1.name.count - cleanedTitle.count)
        }) {
            return best
        }

        // 3. 常见出行随身装备近义词/别名匹配
        let aliases: [[String]] = [
            ["伞", "雨伞", "折叠伞", "遮阳伞", "太阳伞", "雨具"],
            ["钥匙", "门卡", "门禁卡", "家门钥匙", "车钥匙"],
            ["工卡", "工牌", "工作证", "门禁"],
            ["耳机", "airpods", "降噪耳机", "蓝牙耳机"],
            ["充电宝", "移动电源", "快充", "充电线", "数据线"],
            ["电脑", "笔记本", "笔记本电脑", "macbook", "ipad", "平板"],
            ["水杯", "保温杯", "水壶", "摇摇杯", "运动水杯"],
            ["药", "常备药", "感冒药", "创可贴", "布洛芬", "胃药"],
            ["证件", "身份证", "护照", "医保卡", "驾照"],
            ["口罩", "一次性口罩", "n95"],
            ["毛巾", "速干毛巾", "运动毛巾"],
            ["奶瓶", "保温杯", "温水杯"],
            ["拾便袋", "牵引绳", "狗绳"]
        ]

        let lowerTitle = cleanedTitle.lowercased()
        for group in aliases {
            let matchedInTitle = group.contains { lowerTitle.contains($0) }
            if matchedInTitle {
                if let matchedItem = storedItems.first(where: { item in
                    let lowerStored = cleanItemTitle(item.name).lowercased()
                    return group.contains { lowerStored.contains($0) }
                }) {
                    return matchedItem
                }
            }
        }

        return nil
    }

    /// 清理物品名称中的补充说明（如括号、斜杠附注）
    public static func cleanItemTitle(_ raw: String) -> String {
        var text = raw
        // 去除英/中文圆括号内容
        while let range = text.range(of: "\\(.*?\\)", options: .regularExpression) {
            text.removeSubrange(range)
        }
        while let range = text.range(of: "（.*?）", options: .regularExpression) {
            text.removeSubrange(range)
        }
        // 若含有斜杠，取斜杠前核心词
        if let slashIndex = text.firstIndex(of: "/") {
            text = String(text[..<slashIndex])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
