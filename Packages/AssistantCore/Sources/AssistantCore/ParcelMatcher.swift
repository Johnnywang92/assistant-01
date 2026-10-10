import Foundation

/// 待办在匹配逻辑里的轻量表示（与 SwiftData 模型解耦，方便测试）。
public struct PendingParcel: Equatable, Sendable {
    public var id: UUID
    public var pickupCode: String?
    public var courier: String?
    public var station: String?
    public var location: String?

    public init(id: UUID, pickupCode: String?, courier: String?, station: String?, location: String?) {
        self.id = id
        self.pickupCode = pickupCode
        self.courier = courier
        self.station = station
        self.location = location
    }
}

public enum ParcelMatcher {
    /// 取件码归一化：去掉空格、大写。
    public static func normalizeCode(_ code: String) -> String {
        code.replacingOccurrences(of: " ", with: "").uppercased()
    }

    /// 根据"已取件"通知找到应完成的待办。
    /// 规则（依次尝试，命中即返回）：
    /// 1. 取件码相同 → 全部返回
    /// 2. 地点相同或互相包含 → 仅当唯一时返回
    /// 3. 驿站品牌（+快递公司）相同 → 仅当唯一时返回
    /// 无法确定时返回空，由用户手动处理。
    public static func matchPickup(_ c: PickupConfirmation, pending: [PendingParcel]) -> [UUID] {
        if !c.pickupCodes.isEmpty {
            let codes = Set(c.pickupCodes.map(normalizeCode))
            let hits = pending.filter { p in p.pickupCode.map { codes.contains(normalizeCode($0)) } ?? false }
            if !hits.isEmpty { return hits.map(\.id) }
        }
        if let loc = c.location {
            let hits = pending.filter { p in
                guard let pl = p.location else { return false }
                return pl == loc || pl.contains(loc) || loc.contains(pl)
            }
            if hits.count == 1 { return hits.map(\.id) }
            if hits.count > 1 { return [] }
        }
        if let station = c.station {
            var hits = pending.filter { $0.station == station }
            if let courier = c.courier, hits.count > 1 {
                hits = hits.filter { $0.courier == courier }
            }
            if hits.count == 1 { return hits.map(\.id) }
        }
        if let courier = c.courier, c.station == nil {
            let hits = pending.filter { $0.courier == courier }
            if hits.count == 1 { return hits.map(\.id) }
        }
        return []
    }

    /// 判断新到件是否与已有待办重复（同一取件码 + 地点/驿站一致或未知）。
    public static func duplicate(code: String, info: ParcelInfo, pending: [PendingParcel]) -> PendingParcel? {
        let n = normalizeCode(code)
        return pending.first { p in
            guard let pc = p.pickupCode, normalizeCode(pc) == n else { return false }
            if let a = p.location, let b = info.location { return a == b }
            if let a = p.station, let b = info.station { return a == b }
            return true
        }
    }
}

public enum TodoFormatter {
    /// 快递待办标题，如 "顺丰 · 取件码 8-2-3021"
    public static func parcelTitle(code: String, info: ParcelInfo) -> String {
        let prefix = info.courier ?? info.station ?? "快递"
        return "\(prefix) · 取件码 \(code)"
    }

    /// 流量显示，如 "1.5 GB"
    public static func formatMB(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024).replacingOccurrences(of: ".00 ", with: " ")
        }
        return String(format: "%.0f MB", mb)
    }
}
