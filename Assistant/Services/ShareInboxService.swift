import AssistantCore
import Foundation
import SwiftData
import UIKit

/// 主 App 侧：排空分享扩展的 App Group 中转区，按内容类型分流为「记账 / 结构化待办 / 规则导入」并落库。
///
/// 与既有架构一致：所有 SwiftData 写入都发生在主 App 单进程（本服务），
/// 扩展进程只负责采集与交接（见 `ShareImportBridge`、`ShareViewController`）。
/// 触发时机：① App 回前台（`AssistantApp` 的 scenePhase.active）；② URL 深链 `assistant://share-import`。
@MainActor
enum ShareInboxService {

    /// 支付/金额关键词：命中即把截图/文本判定为「记账」，避免把普通截图误记为账。
    private static let paymentKeywords = [
        "微信支付", "支付宝", "支付成功", "付款成功", "已支付", "支付金额",
        "付款", "转账", "收款", "退款", "交易成功", "实付", "合计", "总计", "应付", "订单金额"
    ]

    private static var isProcessing = false

    /// 单条处理结果：只有 `.done` 才允许删除来源，`.retryable` 必须保留 JSON 与图片。
    private enum Outcome {
        case done
        case retryable(String)
    }

    /// 坏载荷（OCR 始终失败、文件损坏）最多尝试的次数，超过后不再重试也不再重复打扰。
    private static let maxAttempts = 3

    /// 排空并处理全部分享载荷。逐条落库后再从磁盘删除，防止处理中途挂起丢失后续分享项；并带防重入锁避免深链与回前台重复触发。
    static func processAll() async {
        await processAll(context: Persistence.shared.mainContext)
    }

    static func processAll(context: ModelContext) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        let items = ShareImportBridge.peekAll()
        guard !items.isEmpty else { return }

        for (payload, imageData) in items {
            // 上次已落库但删文件失败：清掉来源，不再重复入账
            if ShareInboxLedger.contains(payload.id) {
                ShareImportBridge.remove(payload)
                continue
            }
            // 多次仍失败的坏载荷停止重试，来源留在中转区供排查
            if payload.attempts >= maxAttempts { continue }

            let outcome: Outcome
            switch payload.kind {
            case .image:
                if let data = imageData, let image = UIImage(data: data) {
                    outcome = await handleImage(image, context: context)
                } else {
                    // 图片字节暂时读不到（例如设备锁定时被文件保护拦下）：保留，下次解锁再试
                    outcome = .retryable("分享的图片暂时读不到")
                }
            case .text:
                outcome = payload.text.map { handleText($0, context: context) } ?? .done
            case .url:
                outcome = payload.text.map { ingest($0, source: "share_url", context: context) } ?? .done
            }

            switch outcome {
            case .done:
                ShareInboxLedger.mark(payload.id)
                ShareImportBridge.remove(payload)
            case .retryable(let reason):
                let attempts = ShareImportBridge.recordFailure(of: payload)
                if attempts == 1 {
                    NotificationService.post(title: "助手 · 分享导入稍后重试", body: "\(reason)，下次打开小助会再试一次")
                } else if attempts == maxAttempts {
                    NotificationService.post(title: "助手 · 分享导入失败", body: "已尝试 \(maxAttempts) 次仍未能保存（\(reason)），请重新分享一次")
                }
            }
        }

        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
    }

    // MARK: - 图片：OCR → 记账 or 待办

    private static func handleImage(_ image: UIImage, context: ModelContext) async -> Outcome {
        let recognized: ImageTodoRecognitionResult
        do {
            recognized = try await OCRService.shared.recognizeTodo(from: image)
        } catch {
            return .retryable("无法读取图片内容")
        }

        // 1. 支付类截图 → 记账
        if looksLikePayment(recognized.rawText), let amount = extractPaymentAmount(recognized.rawText) {
            let record = ExpenseRecord(
                amount: amount,
                isIncome: inferIsIncome(recognized.rawText),
                category: inferCategory(recognized.rawText),
                title: inferMerchant(from: recognized.rawText),
                rawText: recognized.rawText,
                date: .now
            )
            context.insert(record)
            do {
                try context.save()
            } catch {
                context.rollback()
                return .retryable("记账写入失败")
            }
            NotificationService.post(title: "助手 · 分享记账", body: "已记 ¥\(formatAmount(amount)) \(record.title)")
            return .done
        }

        // 2. 含二维码/时间/地点 → 结构化待办（与 ImportScreenshotIntent 同路径）
        if recognized.qrCodeImageData != nil || recognized.qrCodePayload != nil || recognized.dueAt != nil || recognized.location != nil {
            let item = TodoItem(
                type: recognized.type,
                status: .active,
                title: recognized.title,
                detail: recognized.detail,
                pickupCode: recognized.pickupCode,
                station: recognized.station,
                location: recognized.location,
                dueAt: recognized.dueAt,
                sourceText: recognized.rawText,
                remindBeforeMinutes: recognized.dueAt != nil ? 60 : 0,
                qrCodePayload: recognized.qrCodePayload,
                qrCodeImageData: recognized.qrCodeImageData,
                attachmentImageData: recognized.attachmentImageData
            )
            context.insert(item)
            do {
                try context.save()
            } catch {
                context.rollback()
                return .retryable("待办写入失败")
            }
            // 落库成功后再排提醒，避免为回滚掉的待办留下一条无处可点的通知
            TodoNotificationManager.shared.scheduleNotification(for: item)
            NotificationService.post(title: "助手 · 分享建待办", body: "已添加：\(recognized.title)")
            return .done
        }

        // 3. 兜底：纯文本规则解析
        guard !recognized.rawText.isEmpty else {
            NotificationService.post(title: "助手 · 分享识别", body: "未能识别到图片文字")
            return .done
        }
        return ingest(recognized.rawText, source: "share_ocr", context: context)
    }

    // MARK: - 文本：记账 or 规则导入

    private static func handleText(_ text: String, context: ModelContext) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .done }

        let parsedItems = ExpenseNaturalLanguageParser.parseMulti(trimmed)
        if !parsedItems.isEmpty {
            for parsed in parsedItems {
                let record = ExpenseRecord(
                    amount: parsed.amount,
                    isIncome: parsed.isIncome,
                    category: parsed.category,
                    title: parsed.title,
                    rawText: trimmed,
                    date: parsed.date,
                    currencyCode: parsed.isForeignCurrency ? parsed.currency.rawValue : nil,
                    foreignAmount: parsed.foreignAmount,
                    exchangeRateToCNY: parsed.exchangeRateToCNY
                )
                context.insert(record)
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                return .retryable("记账写入失败")
            }
            if parsedItems.count == 1, let parsed = parsedItems.first {
                NotificationService.post(title: "助手 · 分享记账", body: "已记 ¥\(formatAmount(parsed.amount)) \(parsed.title)")
            } else {
                let total = parsedItems.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
                NotificationService.post(title: "助手 · 分享记账", body: "已记 \(parsedItems.count) 笔 · 合计 ¥\(formatAmount(total))")
            }
            return .done
        }

        return ingest(trimmed, source: "share_text", context: context)
    }

    /// 规则导入：`ImportService.ingest` 自己会保存，落库失败时回滚并保留来源。
    private static func ingest(_ text: String, source: String, context: ModelContext) -> Outcome {
        let result: ImportResult
        do {
            result = try ImportService(context: context).ingest(text, source: source)
        } catch {
            context.rollback()
            return .retryable("规则导入写入失败")
        }
        if result.isNotable {
            NotificationService.post(title: "助手 · 分享提取", body: result.summary)
        }
        return .done
    }

    // MARK: - 判定与提取

    private static func looksLikePayment(_ text: String) -> Bool {
        paymentKeywords.contains { text.contains($0) }
    }

    /// 从支付截图文本提取金额：优先「金额/实付/合计」字段与「¥xx.xx」，避免抓到订单号等噪声数字。
    private static func extractPaymentAmount(_ text: String) -> Double? {
        let patterns = [
            "(?:支付金额|交易金额|实付款?|付款金额|订单金额|金额|合计|总计|应付)\\s*[:：]?\\s*[¥￥]?\\s*([0-9]+(?:[.,][0-9]{1,2})?)",
            "[¥￥]\\s*([0-9]+(?:\\.[0-9]{1,2})?)",
            "(?:支付成功|交易成功)[\\s\\S]{0,24}?([0-9]+(?:\\.[0-9]{1,2})?)",
            "([0-9]+(?:\\.[0-9]{1,2})?)\\s*元"
        ]
        for pattern in patterns {
            if let raw = Regex.firstGroup(pattern, in: text),
               let value = Double(raw.replacingOccurrences(of: ",", with: ".")), value > 0 {
                return value
            }
        }
        return nil
    }

    private static func inferIsIncome(_ text: String) -> Bool {
        ["收款", "退款", "转入", "收入", "到账"].contains { text.contains($0) }
    }

    /// 轻量分类推断，命中不到时归入「其它支出/其它收入」。
    private static func inferCategory(_ text: String) -> ExpenseCategory {
        let isIncome = inferIsIncome(text)
        let table: [(ExpenseCategory, [String])] = [
            (.food, ["餐", "饭", "吃", "外卖", "咖啡", "奶茶", "食", "restaurant", "food"]),
            (.transport, ["打车", "地铁", "公交", "加油", "停车", "高铁", "机票", "出行", "taxi", "fuel"]),
            (.living, ["超市", "便利", "日用", "买菜", "水电", "燃气", "物业"])
        ]
        for (category, keywords) in table where keywords.contains(where: { text.contains($0) }) {
            return category
        }
        return isIncome ? .otherIncome : .other
    }

    /// 从截图里挑一条像「商户/商品」的行做标题；找不到用「微信支付/支付宝」。
    private static func inferMerchant(from text: String) -> String {
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        let noise = paymentKeywords + ["金额", "时间", "订单", "账单", "详情", "支付方式", "零钱"]
        for line in lines {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.count >= 2, candidate.count <= 24 else { continue }
            guard candidate.contains(where: { $0.isLetter }) else { continue }
            if noise.contains(where: { candidate.contains($0) }) { continue }
            if candidate.rangeOfCharacter(from: .decimalDigits) != nil { continue } // 跳过含数字的行（金额/单号）
            return candidate
        }
        if text.contains("支付宝") { return "支付宝支付" }
        return "微信支付"
    }

    private static func formatAmount(_ amount: Double) -> String {
        AmountFormatter.format(amount)
    }
}
