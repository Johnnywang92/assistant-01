import Foundation
import SwiftData
import UserNotifications

/// 生活痛点自动化扫描器（订阅防被扣款、证件临期预警、健康补水）
@MainActor
struct DailyPainPointAuditor {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    init() {
        self.context = Persistence.shared.mainContext
    }

    /// 统一执行每日痛点巡检
    public func auditAll() {
        auditSubscriptions()
        auditItemExpiries()
        auditAnniversaries()
        auditPasswordRotations()
        auditIDDocuments()
    }

    /// 1. 自动续费与订阅被动扣费防范
    private func auditSubscriptions() {
        let descriptor = FetchDescriptor<SubscriptionItem>()
        guard let subs = try? context.fetch(descriptor) else { return }

        let now = Date.now
        let cal = Calendar.current

        for sub in subs {
            let daysUntilBilling = cal.dateComponents([.day], from: now, to: sub.nextBillingDate).day ?? 0
            if daysUntilBilling <= sub.remindDaysBefore && daysUntilBilling >= 0 {
                let title = "💳 订阅扣费预警：\(sub.name)"
                let detail = "预计将在 \(daysUntilBilling) 天后自动扣款（\(sub.priceString)），若不再需要请及时前往取消。"
                upsertTodo(type: .subscription, title: title, detail: detail, dueAt: sub.nextBillingDate)

                postThrottledNotification(
                    id: "sub-\(sub.id.uuidString)",
                    title: "自动续费提醒",
                    body: "「\(sub.name)」即将于 \(daysUntilBilling) 天后扣费（\(sub.priceString)）"
                )
            }
        }
    }

    /// 2. 证件与保质期临期预警
    private func auditItemExpiries() {
        let descriptor = FetchDescriptor<ItemExpiryItem>(
            predicate: #Predicate { !$0.isResolved }
        )
        guard let items = try? context.fetch(descriptor) else { return }

        let now = Date.now
        let cal = Calendar.current

        for item in items {
            let daysLeft = cal.dateComponents([.day], from: now, to: item.expireDate).day ?? 0
            if daysLeft <= item.remindDaysBefore {
                let statusDesc = daysLeft < 0 ? "已过期 \(abs(daysLeft)) 天！" : "即将在 \(daysLeft) 天后过期"
                let title = "⚠️ 临期预警：\(item.title)"
                let detail = "[\(item.category)] \(statusDesc)，请尽快处理或换新。"
                upsertTodo(type: .itemExpiry, title: title, detail: detail, dueAt: item.expireDate)

                postThrottledNotification(
                    id: "exp-\(item.id.uuidString)",
                    title: "临期提醒",
                    body: "「\(item.title)」\(statusDesc)"
                )
            }
        }
    }

    /// 3. 纪念日、生日与重要日子提醒
    private func auditAnniversaries() {
        let descriptor = FetchDescriptor<AnniversaryItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        for item in items {
            let daysLeft = item.daysUntilNext
            // 命中预警阈值（如提前 7 天、3 天、当天）
            if item.remindDaysBefore.contains(daysLeft) {
                let count = item.nextYearsCount
                let daysDesc = daysLeft == 0 ? "就在今天！🎉" : "还有 \(daysLeft) 天"
                let title = "🎁 纪念日提醒：\(item.title)（第 \(count) 周年）"
                let detail = "[\(item.category)] 距离 \(item.title) \(daysDesc)。提前备好礼物或惊喜吧！"

                upsertTodo(type: .anniversary, title: title, detail: detail, dueAt: item.nextAnniversaryDate)

                postThrottledNotification(
                    id: "anni-\(item.id.uuidString)-\(daysLeft)",
                    title: "纪念日提醒",
                    body: "「\(item.title)」\(daysDesc)（第 \(count) 周年）"
                )
            }
        }
    }

    /// 4. 长期未更换密码与安全轮换预警
    private func auditPasswordRotations() {
        let descriptor = FetchDescriptor<PasswordVaultItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        for item in items {
            if item.isRotationDue {
                let title = "🔑 密码更新提醒：\(item.title)"
                let detail = "[\(item.category)] 账号 \(item.account) 的密码已连续使用 \(item.usedDays) 天，建议及时轮换更新以保障安全。"
                upsertTodo(type: .passwordSecurity, title: title, detail: detail, dueAt: item.nextRotationDueDate ?? .now)

                postThrottledNotification(
                    id: "pwd-rotate-\(item.id.uuidString)",
                    title: "密码更新预警",
                    body: "「\(item.title)」密码已使用超 \(item.rotateCycleDays) 天，建议更换。"
                )
            }
        }
    }

    /// 5. 证件到期预警（身份证、护照、驾照等）
    private func auditIDDocuments() {
        let descriptor = FetchDescriptor<IDDocumentItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        for item in items {
            guard !item.isPermanent, let daysLeft = item.daysUntilExpiry, let expiry = item.expiryDate else { continue }
            if daysLeft <= 30 {
                let statusDesc = daysLeft < 0 ? "已过期 \(abs(daysLeft)) 天" : "即将在 \(daysLeft) 天后过期"
                let title = "🪪 证件临期预警：\(item.title)"
                let detail = "[\(item.type.rawValue)] \(statusDesc)，若需使用请提前前往换领或续签。"
                upsertTodo(type: .itemExpiry, title: title, detail: detail, dueAt: expiry)

                postThrottledNotification(
                    id: "id-doc-\(item.id.uuidString)",
                    title: "证件临期预警",
                    body: "「\(item.title)」\(statusDesc)，请记得及时换证。"
                )
            }
        }
    }

    private func postThrottledNotification(id: String, title: String, body: String) {
        let dateKey = "audit_notif_date_\(id)"
        let cal = Calendar.current
        if let lastDate = UserDefaults.standard.object(forKey: dateKey) as? Date,
           cal.isDateInToday(lastDate) {
            return
        }
        UserDefaults.standard.set(Date.now, forKey: dateKey)
        NotificationService.post(title: title, body: body, id: id)
    }

    private func upsertTodo(type: TodoType, title: String, detail: String, dueAt: Date) {
        let typeRaw = type.rawValue
        let active = TodoStatus.active.rawValue
        let existing = (try? context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.title == title && $0.typeRaw == typeRaw && $0.statusRaw == active }
        ))) ?? []

        if existing.isEmpty {
            let todo = TodoItem(type: type, status: .active, title: title, detail: detail, dueAt: dueAt)
            context.insert(todo)
            try? context.save()
        }
    }
}
