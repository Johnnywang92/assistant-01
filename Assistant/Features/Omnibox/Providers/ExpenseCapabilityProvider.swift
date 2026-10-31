import AssistantCore
import Foundation
import SwiftData

struct ExpenseCapabilityProvider: CapabilityProvider {
    let moduleID = "expense"
    let capabilities: [ActionCapability] = [.expenseCreate, .expenseUpdate]
    let undoKinds: [ActionUndoToken.Kind] = [.expense]

    func execute(_ action: PlannedAction, prior: [UUID: String], context: ModelContext) throws -> ActionExecutionOutcome {
        switch action.capability {
        case .expenseCreate:
            return try executeCreate(action, context: context)
        case .expenseUpdate:
            return try executeUpdate(action, context: context)
        default:
            throw OmniboxError.invalidParams("expense 模块不认识该动作")
        }
    }

    // MARK: expense.create

    private func executeCreate(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        guard let amountValue = Double(action.params["amount"] ?? ""), amountValue > 0 else {
            throw OmniboxError.invalidParams("金额无效")
        }
        let isIncome = action.params["isIncome"] == "true"
        let category = ExpenseCategory(rawValue: action.params["category"] ?? "") ?? (isIncome ? .otherIncome : .other)
        let title = action.params["title"]?.isEmpty == false ? action.params["title"]! : L10n.tr("投喂记录")
        // 短信/订单截图里识别出的交易时间优先于当前时间
        let transactionDate = OmniboxPlanner.parseParamDate(action.params["dateISO"]) ?? .now
        let currencyCode: String? = {
            guard let code = action.params["currency"],
                  let cur = ExpenseCurrency(rawValue: code),
                  cur != .cny else { return nil }
            return cur.rawValue
        }()
        let foreignAmount = currencyCode != nil ? Double(action.params["foreignAmount"] ?? "") : nil
        let exchangeRate = currencyCode != nil ? Double(action.params["exchangeRate"] ?? "") : nil

        let record = ExpenseRecord(
            amount: amountValue,
            isIncome: isIncome,
            category: category,
            title: title,
            rawText: action.summary,
            date: transactionDate,
            currencyCode: currencyCode,
            foreignAmount: foreignAmount,
            exchangeRateToCNY: exchangeRate
        )
        context.insert(record)
        try context.save()

        // 联动餐饮食物热量估算与饮水记录
        if record.category == .food {
            ExpenseCalorieService.handleSaved(record, propose: true, context: context)
            ExpenseWaterService.handleSaved(record, context: context)
        }

        if !record.isIncome {
            BudgetAlertService.shared.evaluateAndNotify(context: context)
        }

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: OmniboxPlanner.summary(for: .expenseCreate, params: action.params),
            undo: OmniboxUndoToken(kind: .expense, recordID: record.id)
        )
    }

    // MARK: expense.update

    private func executeUpdate(_ action: PlannedAction, context: ModelContext) throws -> ActionExecutionOutcome {
        let mention = action.params["target"] ?? action.params["title"] ?? ""
        let amt = Double(action.params["amount"] ?? "")
        let resolution = ActionTargetResolver.resolveExpense(mention: mention, amount: amt, context: context)
        guard case .unique(let record) = resolution else {
            switch resolution {
            case .ambiguous(let candidates):
                throw OmniboxError.invalidParams("匹配到多笔账目（\(candidates.map(\.displayTitle).joined(separator: " / "))），请明确指定")
            case .none, .unique:
                throw OmniboxError.invalidParams("未找到与「\(mention)」相符的账单记录")
            }
        }

        let snapshot: [String: String] = [
            "title": record.title,
            "amount": String(record.amount),
            "categoryRaw": record.categoryRaw
        ]
        let snapshotData = ActionUndoToken.makeSnapshotData(snapshot)

        if let newAmt = Double(action.params["newAmount"] ?? action.params["amount"] ?? ""), newAmt > 0 {
            record.amount = newAmt
        }
        if let newTitle = action.params["newTitle"], !newTitle.isEmpty {
            record.title = newTitle
        }
        if let newCat = action.params["newCategory"], let cat = ExpenseCategory(rawValue: newCat) {
            record.category = cat
        }
        try context.save()
        if record.category == .food {
            ExpenseWaterService.handleSaved(record, context: context)
        }
        if !record.isIncome {
            BudgetAlertService.shared.evaluateAndNotify(context: context)
        }

        return ActionExecutionOutcome(
            id: action.id,
            action: action,
            summary: "已修改账目：\(record.title) ¥\(String(format: "%.2f", record.amount))",
            undo: OmniboxUndoToken(kind: .expense, recordID: record.id, snapshotJSON: snapshotData)
        )
    }

    func undo(_ token: OmniboxUndoToken, context: ModelContext) throws {
        guard case .expense = token.kind else { return }
        guard let id = token.recordID else { return }
        let descriptor = FetchDescriptor<ExpenseRecord>(predicate: #Predicate { $0.id == id })
        if let record = try context.fetch(descriptor).first {
            if let snapshot = token.decodeSnapshot() {
                // 修改式回滚
                if let amtStr = snapshot["amount"], let amt = Double(amtStr) {
                    record.amount = amt
                }
                if let title = snapshot["title"] { record.title = title }
                if let catRaw = snapshot["categoryRaw"], let cat = ExpenseCategory(rawValue: catRaw) {
                    record.category = cat
                }
            } else {
                // 创建式回滚
                ExpenseCalorieService.handleDeleted(expenseID: record.id, context: context)
                ExpenseWaterService.handleDeleted(expenseID: record.id, context: context)
                context.delete(record)
            }
        }
        try context.save()
    }
}
