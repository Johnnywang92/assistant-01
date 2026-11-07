import Foundation

// MARK: - 投喂口结构化直通（纯逻辑，下沉 AssistantCore 便于测试覆盖）

/// 有些输入有**确定性解**：快递取件短信里的取件码、驿站、柜位都是明文，
/// `RuleEngine` 的正则就能抽出来。把它们丢进 16 类概率判别是错配——
/// 标签集里没有「快递取件」这一类，模型只能在「纪念日与到期 / 出门清单 /
/// 查询事项」之间硬挑一个，再把短信原文硬填成纪念日。
///
/// 所以判别层之前先过这里：命中就直通，未命中才回到常规理解链路。
/// 这里只产出结构化事实，**不认识 App 的模型枚举**（TodoType 映射在 App 侧做）。
public enum StructuredCaptureRouter {

    /// 一条待建快递待办所需的全部确定信息。
    public struct ParcelDraft: Equatable, Sendable {
        public let title: String
        public let pickupCode: String
        public let station: String?
        public let location: String?
        public let courier: String?
        public let sourceText: String

        public init(
            title: String,
            pickupCode: String,
            station: String?,
            location: String?,
            courier: String?,
            sourceText: String
        ) {
            self.title = title
            self.pickupCode = pickupCode
            self.station = station
            self.location = location
            self.courier = courier
            self.sourceText = sourceText
        }
    }

    public enum Outcome: Equatable, Sendable {
        case parcel([ParcelDraft])
        case notStructured
    }

    /// 单条短信的合理长度上限。超长文本里可能混了别的意图，
    /// 不能因为夹了一句取件通知就把整段吞掉（不静默丢动作）。
    public static let maxSMSLength = 240

    /// 判断一段文本是否是可直通的快递到件通知。
    ///
    /// 只认 `.parcel`：已取件通知需要匹配既有待办、流量/账单/验证码各有去处，
    /// 这些都不能被一条「新建待办」抢走，一律交回常规链路。
    public static func route(_ text: String) -> Outcome {
        let sourceText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty, sourceText.count <= maxSMSLength else { return .notStructured }

        guard case .parcel(let info) = RuleEngine().parse(sourceText),
              !info.pickupCodes.isEmpty else { return .notStructured }

        let drafts = info.pickupCodes.map { code in
            ParcelDraft(
                title: TodoFormatter.parcelTitle(code: code, info: info),
                pickupCode: code,
                station: info.station,
                location: info.location,
                courier: info.courier,
                sourceText: sourceText
            )
        }
        return .parcel(drafts)
    }
}
