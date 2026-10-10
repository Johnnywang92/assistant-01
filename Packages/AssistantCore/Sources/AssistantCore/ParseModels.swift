import Foundation

/// 一条快递到件信息（可能一条短信里包含多个取件码）。
public struct ParcelInfo: Equatable, Sendable {
    /// 取件码，如 "8-2-3021"、"12345678"
    public var pickupCodes: [String]
    /// 快递公司，如 "顺丰"
    public var courier: String?
    /// 驿站/快递柜品牌，如 "菜鸟驿站"、"丰巢"
    public var station: String?
    /// 具体地点，如 "XX小区菜鸟驿站"
    public var location: String?

    public init(pickupCodes: [String], courier: String? = nil, station: String? = nil, location: String? = nil) {
        self.pickupCodes = pickupCodes
        self.courier = courier
        self.station = station
        self.location = location
    }
}

/// 已取件 / 已签收通知。
public struct PickupConfirmation: Equatable, Sendable {
    public var pickupCodes: [String]
    public var courier: String?
    public var station: String?
    public var location: String?

    public init(pickupCodes: [String] = [], courier: String? = nil, station: String? = nil, location: String? = nil) {
        self.pickupCodes = pickupCodes
        self.courier = courier
        self.station = station
        self.location = location
    }
}

/// 运营商流量信息。数值统一换算为 MB。
public struct DataUsageInfo: Equatable, Sendable {
    public var operatorName: String?
    public var remainingMB: Double?
    public var usedMB: Double?
    public var usedPercent: Double?

    public init(operatorName: String? = nil, remainingMB: Double? = nil, usedMB: Double? = nil, usedPercent: Double? = nil) {
        self.operatorName = operatorName
        self.remainingMB = remainingMB
        self.usedMB = usedMB
        self.usedPercent = usedPercent
    }

    /// 已用百分比：优先用短信里的百分比，否则用 已用/(已用+剩余) 计算。
    public var effectiveUsedPercent: Double? {
        if let usedPercent { return usedPercent }
        if let used = usedMB, let remain = remainingMB, used + remain > 0 {
            return used / (used + remain) * 100
        }
        return nil
    }
}

/// 信用卡账单信息。
public struct CreditCardBillInfo: Equatable, Sendable {
    public var bankName: String?          // 银行名称，如 "招商银行", "建设银行"
    public var cardTail: String?          // 卡号尾号，如 "1234"
    public var amount: Double?            // 应还金额
    public var dueDateString: String?     // 到期还款日，如 "10月25日"
    public var minPayment: Double?        // 最低还款额

    public init(bankName: String? = nil, cardTail: String? = nil, amount: Double? = nil, dueDateString: String? = nil, minPayment: Double? = nil) {
        self.bankName = bankName
        self.cardTail = cardTail
        self.amount = amount
        self.dueDateString = dueDateString
        self.minPayment = minPayment
    }
}

/// 规则引擎的解析结果。
public enum ParseOutcome: Equatable, Sendable {
    case parcel(ParcelInfo)
    case pickedUp(PickupConfirmation)
    case dataUsage(DataUsageInfo)
    case creditCardBill(CreditCardBillInfo)
    /// 验证码、营销短信等，直接忽略
    case ignored
    /// 规则无法识别（后续交给端侧模型）
    case unknown
}
