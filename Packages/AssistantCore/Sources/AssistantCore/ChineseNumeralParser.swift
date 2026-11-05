import Foundation

/// 中文/阿拉伯数字的统一解析器。
///
/// 背景（审计 CORE-08）：这套逻辑曾在四个地方各写一遍，而且语义互不相同——
/// `ExpenseAmountExtractor.numberValue`（支持十/百/千/万，非法返回 nil）、
/// `FoodCalorieEstimator.parseChineseQuantity`（只支持十，非法**静默返回 1.0**）、
/// `SkillPathPlanner.numericValue`（另一套十的写法 + 特判两/半）、
/// `QueryInsightEngine.parseChineseNumber`（只支持 1–99，超范围返回 nil）。
/// 结果：同一句「近一百天」在查询侧解析失败、在记账侧得到 100；「半半」在份量侧被当成 1 份。
/// 修一处 bug 也不会传导到其它三处（CORE-02 的「三百五」就只在记账那份里暴露）。
///
/// 现在统一到这里：**一处实现、四处转发**，未知输入一律返回 `nil`，
/// 由调用方显式决定默认值（不再有「静默当成 1」的隐藏语义）。
public enum ChineseNumeralParser {

    private static let digitValues: [Character: Double] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
    ]

    /// 中文/阿拉伯数字 → 数值；无法解析返回 nil。
    ///
    /// 支持：
    /// - 阿拉伯数字直通（`"12.5"`，兼容全角 `．`）；
    /// - `零/〇/一…九/两`、`半`（单独或「一半」→ 0.5）；
    /// - `十/百/千/万` 组合，含口语省略下级单位（`"三百五"` = 350）与「零」显式个位（`"一千零五"` = 1005）。
    ///
    /// 不支持：中文数字与「半」的混合写法（如「一个半」）——这类量词表达式应在调用方
    /// 用正则剥离量词后再交给本解析器，混写一律视为不可解析。
    public static func value(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let arabic = Double(trimmed.replacingOccurrences(of: "．", with: ".")) {
            return arabic
        }
        if trimmed == "半" || trimmed == "一半" { return 0.5 }
        // 混写「X个半 / X碗半」由调用方的量词正则处理；这里不猜
        if trimmed.contains("半") { return nil }

        var total = 0.0
        var section = 0.0
        var current = 0.0
        var lastUnit = 0.0
        var pendingZero = false
        var zeroBeforeCurrent = false

        for char in trimmed {
            if let digit = digitValues[char] {
                if digit == 0 {
                    pendingZero = true
                } else {
                    current = digit
                    zeroBeforeCurrent = pendingZero
                    pendingZero = false
                }
                continue
            }
            switch char {
            case "十": section += (current == 0 ? 1 : current) * 10; current = 0; lastUnit = 10
            case "百": section += (current == 0 ? 1 : current) * 100; current = 0; lastUnit = 100
            case "千": section += (current == 0 ? 1 : current) * 1_000; current = 0; lastUnit = 1_000
            case "万": total += (section + current) * 10_000; section = 0; current = 0; lastUnit = 10_000
            default: return nil
            }
            pendingZero = false
            zeroBeforeCurrent = false
        }

        // 口语省略下级单位：末位数字表示下一级单位（三百五 = 350），
        // 但「零」是显式个位（三百零五 = 305，一千零五 = 1005）不能进位。
        if current > 0, lastUnit >= 100, !zeroBeforeCurrent {
            current *= lastUnit / 10
        }
        return total + section + current
    }

    /// 整数便捷入口：非整数或超范围返回 nil。
    public static func integer(_ text: String) -> Int? {
        guard let value = value(text),
              value == value.rounded(),
              value >= Double(Int.min),
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}
