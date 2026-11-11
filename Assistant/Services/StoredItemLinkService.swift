import Foundation
import SwiftData

/// 收纳物品 ↔ 记账 的软关联维护。
///
/// `ExpenseRecord.linkedItemID` 指向 `StoredItem.id`（日均持有成本归集用）。
/// 这条关联是**单向存储、双向使用**的：
///
/// | 方向 | 现状 |
/// |---|---|
/// | 记账 → 物品 | 通：记账时选物品，持有成本 / 回本进度据此累计 |
/// | 物品 → 记账 | **缺失**：删除物品时账单上的关联不清理 |
///
/// 缺失的后果不是数据丢失，而是**统计静默失真**：账单还挂在已删除的物品上，
/// 物品详情里的「累计投入 ¥X」凭空少了一截，日均持有成本被低估、
/// 回本进度算出错误的结论——用户看到的数字与实际花的钱对不上。
///
/// 删除物品时只**解除关联**，不删账单：钱是真实花出去的，账不能因为收纳
/// 物品被清理就一起消失。
enum StoredItemLinkService {

    /// 删除收纳物品前调用：把指向它的账单一律解除关联。
    ///
    /// 幂等：没有关联账单时什么都不做。
    static func unlinkExpenses(for itemID: UUID, in context: ModelContext) {
        let target = itemID
        let descriptor = FetchDescriptor<ExpenseRecord>(predicate: #Predicate { $0.linkedItemID == target })
        guard let records = try? context.fetch(descriptor), !records.isEmpty else { return }
        for record in records {
            record.linkedItemID = nil
        }
    }
}
