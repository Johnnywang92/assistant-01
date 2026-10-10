import AssistantCore
import Foundation
import SwiftData

/// 导入结果，用于快捷指令返回值和本地通知。
struct ImportResult {
    var added: [String] = []
    var completed: [String] = []
    var notes: [String] = []
    var skippedDuplicate = false

    var summary: String {
        var parts: [String] = []
        if !added.isEmpty { parts.append("已添加：" + added.joined(separator: "；")) }
        if !completed.isEmpty { parts.append("已完成：" + completed.joined(separator: "；")) }
        parts.append(contentsOf: notes)
        if parts.isEmpty { return skippedDuplicate ? "重复消息，已跳过" : "无需处理" }
        return parts.joined(separator: "\n")
    }

    /// 是否值得发通知
    var isNotable: Bool { !added.isEmpty || !completed.isEmpty || !notes.isEmpty }
}

/// 把一段文本（短信/粘贴内容）解析并写入数据库。
@MainActor
struct ImportService {
    let context: ModelContext
    var engine = RuleEngine()

    init(context: ModelContext) {
        self.context = context
    }

    @discardableResult
    func ingest(_ text: String, source: String, sender: String? = nil) throws -> ImportResult {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return ImportResult() }

        // 原文去重：快捷指令同时写了收件箱文件和调用 Intent，补录时会再来一次
        if try isRecentDuplicate(content) {
            return ImportResult(skippedDuplicate: true)
        }

        let raw = RawMessage(source: source, sender: sender, content: content)
        context.insert(raw)

        var result = ImportResult()
        let outcome = engine.parse(content, sender: sender)
        switch outcome {
        case .parcel(let info):
            try handleParcel(info, content: content, result: &result)
            raw.parseSummary = "parcel \(info.pickupCodes)"
        case .pickedUp(let c):
            try handlePickup(c, result: &result)
            raw.parseSummary = "pickedUp \(c.pickupCodes)"
        case .dataUsage(let d):
            try handleDataUsage(d, result: &result)
            raw.parseSummary = "data remain=\(d.remainingMB ?? -1)"
        case .creditCardBill(let b):
            try handleCreditCardBill(b, content: content, result: &result)
            raw.parseSummary = "bill \(b.bankName ?? "") \(b.amount ?? 0)"
        case .ignored:
            raw.parseSummary = "ignored"
        case .unknown:
            let title = String(content.prefix(40))
            context.insert(TodoItem(type: .general, status: .pendingReview, title: title, sourceText: content))
            result.notes.append("待确认：\(title)")
            raw.parseSummary = "unknown"
        }
        try context.save()
        return result
    }

    // MARK: - 处理器

    private func handleParcel(_ info: ParcelInfo, content: String, result: inout ImportResult) throws {
        let pending = try activeParcels()
        let pendingLite = pending.map(\.lite)
        for code in info.pickupCodes {
            if let dup = ParcelMatcher.duplicate(code: code, info: info, pending: pendingLite) {
                // 已有同一取件码的待办：补全缺失信息
                if let item = pending.first(where: { $0.id == dup.id }) {
                    item.location = item.location ?? info.location
                    item.courier = item.courier ?? info.courier
                    item.station = item.station ?? info.station
                }
                continue
            }
            let title = TodoFormatter.parcelTitle(code: code, info: info)
            context.insert(TodoItem(type: .parcel, title: title, detail: info.location,
                                    pickupCode: code, courier: info.courier, station: info.station,
                                    location: info.location, sourceText: content))
            result.added.append(title)
        }
    }

    private func handlePickup(_ c: PickupConfirmation, result: inout ImportResult) throws {
        let pending = try activeParcels()
        let ids = Set(ParcelMatcher.matchPickup(c, pending: pending.map(\.lite)))
        let matched = pending.filter { ids.contains($0.id) }
        if matched.isEmpty {
            if !pending.isEmpty {
                result.notes.append("收到取件通知，但无法确定是哪个快递，请手动勾选")
            }
            return
        }
        for item in matched {
            item.status = .done
            result.completed.append(item.title)
        }
    }

    private func handleDataUsage(_ d: DataUsageInfo, result: inout ImportResult) throws {
        context.insert(DataUsageRecord(operatorName: d.operatorName, remainingMB: d.remainingMB,
                                       usedMB: d.usedMB, usedPercent: d.usedPercent))
        let low = (d.remainingMB.map { $0 < AppSettings.lowDataThresholdMB } ?? false)
            || (d.effectiveUsedPercent.map { $0 >= 90 } ?? false)

        let dataType = TodoType.data.rawValue
        let done = TodoStatus.done.rawValue
        let existing = try context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == dataType && $0.statusRaw != done }))

        guard low else {
            // 流量恢复（如月初重置），自动关闭旧的提醒
            existing.forEach { $0.status = .done }
            return
        }
        let remainText = d.remainingMB.map { TodoFormatter.formatMB($0) } ?? "不足 10%"
        let title = "流量剩余 \(remainText)，考虑购买流量包"
        if let item = existing.first {
            item.title = title
        } else {
            context.insert(TodoItem(type: .data, title: title, detail: d.operatorName))
            result.added.append(title)
        }
    }

    private func handleCreditCardBill(_ b: CreditCardBillInfo, content: String, result: inout ImportResult) throws {
        let bank = b.bankName ?? "信用卡"
        let tail = b.cardTail.map { "(\($0))" } ?? ""
        let amountText = b.amount.map { String(format: "¥%.2f", $0) } ?? "见详情"
        let dueText = b.dueDateString.map { "，还款日 \($0)" } ?? ""

        let title = "💳 还信用卡：\(bank)\(tail) 应还 \(amountText)"
        let detail = "应还金额 \(amountText)\(dueText)"

        let billType = TodoType.bill.rawValue
        let active = TodoStatus.active.rawValue
        let existing = try context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.title == title && $0.typeRaw == billType && $0.statusRaw == active }
        ))

        if existing.isEmpty {
            context.insert(TodoItem(type: .bill, status: .active, title: title, detail: detail, sourceText: content))
            result.added.append(title)
        }
    }

    // MARK: - 查询

    private func activeParcels() throws -> [TodoItem] {
        let parcel = TodoType.parcel.rawValue
        let active = TodoStatus.active.rawValue
        return try context.fetch(FetchDescriptor<TodoItem>(
            predicate: #Predicate { $0.typeRaw == parcel && $0.statusRaw == active }))
    }

    private func isRecentDuplicate(_ content: String) throws -> Bool {
        let since = Date.now.addingTimeInterval(-3 * 24 * 3600)
        var descriptor = FetchDescriptor<RawMessage>(
            predicate: #Predicate { $0.content == content && $0.receivedAt > since })
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }
}

extension TodoItem {
    var lite: PendingParcel {
        PendingParcel(id: id, pickupCode: pickupCode, courier: courier, station: station, location: location)
    }
}
