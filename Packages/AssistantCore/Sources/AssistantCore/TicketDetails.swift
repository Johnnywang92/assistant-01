import Foundation

/// 一张车票/机票上「抬头就要看到」的关键信息。
/// 只用 Foundation，便于在 macOS 上直接 `swift test`。
public struct TicketDetails: Equatable, Sendable {
    /// 车次/航班号，如 G1234、MU5102
    public var vehicleNumber: String?
    /// 车厢号，如 5
    public var carNumber: String?
    /// 座位号，如 12A
    public var seatNumber: String?
    /// 检票口 / 登机口，如 B12
    public var gate: String?

    public init(vehicleNumber: String? = nil,
                carNumber: String? = nil,
                seatNumber: String? = nil,
                gate: String? = nil) {
        self.vehicleNumber = vehicleNumber
        self.carNumber = carNumber
        self.seatNumber = seatNumber
        self.gate = gate
    }

    /// 是否抽到了任何可用信息
    public var isEmpty: Bool {
        vehicleNumber == nil && carNumber == nil && seatNumber == nil && gate == nil
    }

    /// 车厢 + 座位，如 "5车 12A"
    public var seatLine: String? {
        let car = carNumber.map { "\($0)车" }
        switch (car, seatNumber) {
        case let (c?, s?): return "\(c) \(s)"
        case let (c?, nil): return c
        case let (nil, s?): return s
        case (nil, nil): return nil
        }
    }

    /// 车次 + 座位，如 "G1234 · 5车 12A"。检票口单独成行时用这个，避免重复。
    public var vehicleAndSeatLine: String? {
        let parts = [vehicleNumber, seatLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 一行完整摘要，如 "G1234 · 5车 12A · 检票口B12"。
    /// 面积有限，优先保证「车次 + 座位 + 检票口」这三项。
    public var wristSummary: String? {
        let parts = [vehicleAndSeatLine, gate.map { "检票口\($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 从行程类短信原文 / 备注文本里抽取登乘信息。
///
/// 设计取舍：不做万能票据 OCR，只覆盖国内 12306、航司短信与常见手写备注的高频写法，
/// 抽不出来就返回空（调用方回退到显示整段详情），宁缺勿错。
public enum TicketDetailsExtractor {
    public static func extract(from texts: [String?]) -> TicketDetails {
        let merged = texts.compactMap { $0 }.joined(separator: " ")
        return extract(from: merged)
    }

    public static func extract(from text: String) -> TicketDetails {
        guard !text.isEmpty else { return TicketDetails() }
        let wide = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        let upper = wide.uppercased()

        var result = TicketDetails()
        result.vehicleNumber = vehicleNumber(in: wide, upper: upper)
        result.carNumber = carNumber(in: wide)
        result.seatNumber = seatNumber(in: wide, upper: upper)
        result.gate = gate(in: wide, upper: upper)
        return result
    }

    // MARK: - 各项抽取

    /// 优先认 explicit 的「车次/航班号」前缀，其次才退到孤立的车次格式，避免把普通单词误判成车次。
    private static func vehicleNumber(in wide: String, upper: String) -> String? {
        if let labelled = firstMatch(of: "(?:车次|列车|航班|航班号)\\s*[:：]?\\s*([A-Za-z0-9]{2,8})", in: wide) {
            return labelled
        }
        // 高铁/动车/城际/直达/快速/特快：G1234、D2286、C2002、Z28、T109、K1234
        if let bare = firstMatch(of: "(?:^|[^A-Za-z0-9])([GDZTKC]\\d{2,5})\\s*(?:次)?", in: upper) {
            return bare
        }
        // 航班：两位字母 + 3~4 位数字（MU5102、CA1832）
        return firstMatch(of: "(?:^|[^A-Za-z0-9])([A-Z]{2}\\d{3,4})(?:[^A-Za-z0-9]|$)", in: upper)
    }

    private static func carNumber(in wide: String) -> String? {
        firstMatch(of: "(\\d{1,2})\\s*(?:号)?\\s*车厢", in: wide)
            ?? firstMatch(of: "车厢\\s*[:：]?\\s*(\\d{1,2})", in: wide)
    }

    private static func seatNumber(in wide: String, upper: String) -> String? {
        if let labelled = firstMatch(of: "(?:座位|席位|座位号|席)\\s*[:：]?\\s*([0-9]{1,3}[A-Fa-f]?)", in: wide) {
            return labelled.uppercased()
        }
        // 孤立的 "12A"：要求前后不是字母数字，避免和 "C2002"、日期片段混淆
        return firstMatch(of: "(?<![A-Za-z0-9])(\\d{1,3}[A-F])(?![A-Za-z0-9])", in: upper)
    }

    private static func gate(in wide: String, upper: String) -> String? {
        firstMatch(of: "(?:检票口|检票)\\s*[:：]?\\s*([A-Za-z0-9]{1,6})", in: wide)
            ?? firstMatch(of: "(?:登机口|登机门)\\s*[:：]?\\s*([A-Za-z0-9]{1,6})", in: wide)
            ?? firstMatch(of: "(?:GATE)\\s*[:：]?\\s*([A-Za-z0-9]{1,6})", in: upper)
    }

    // MARK: - 基础工具

    private static func firstMatch(of pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
