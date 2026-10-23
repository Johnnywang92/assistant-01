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
            switch payload.kind {
            case .image:
                if let data = imageData, let image = UIImage(data: data) {
                    await handleImage(image, context: context)
                }
            case .text:
                if let text = payload.text {
                    handleText(text, context: context)
                }
            case .url:
                if let text = payload.text {
                    _ = try? ImportService(context: context).ingest(text, source: "share_url")
                }
            }
            ShareImportBridge.remove(payload)
        }

        WidgetSnapshotSyncController.shared.refreshSnapshot(context: context)
    }

    // MARK: - 图片：OCR → 记账 or 待办

    private static func handleImage(_ image: UIImage, context: ModelContext) async {
        let recognized: ImageTodoRecognitionResult
        do {
            recognized = try await OCRService.shared.recognizeTodo(from: image)
        } catch {
            NotificationService.post(title: "助手 · 分享识别失败", body: "无法读取图片内容")
            return
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
            try? context.save()
            NotificationService.post(title: "助手 · 分享记账", body: "已记 ¥\(formatAmount(amount)) \(record.title)")
            return
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
            TodoNotificationManager.shared.scheduleNotification(for: item)
            try? context.save()
            NotificationService.post(title: "助手 · 分享建待办", body: "已添加：\(recognized.title)")
            return
        }

        // 3. 兜底：纯文本规则解析
        guard !recognized.rawText.isEmpty else {
            NotificationService.post(title: "助手 · 分享识别", body: "未能识别到图片文字")
            return
        }
        let result = try? ImportService(context: context).ingest(recognized.rawText, source: "share_ocr")
        if result?.isNotable == true {
            NotificationService.post(title: "助手 · 分享提取", body: result!.summary)
        }
    }

    // MARK: - 文本：记账 or 规则导入

    private static func handleText(_ text: String, context: ModelContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let parsed = ExpenseNaturalLanguageParser.parse(trimmed) {
            let record = ExpenseRecord(
                amount: parsed.amount,
                isIncome: parsed.isIncome,
                category: parsed.category,
                title: parsed.title,
                rawText: trimmed,
                date: parsed.date
            )
            context.insert(record)
            try? context.save()
            NotificationService.post(title: "助手 · 分享记账", body: "已记 ¥\(formatAmount(parsed.amount)) \(record.title)")
            return
        }

        let result = try? ImportService(context: context).ingest(trimmed, source: "share_text")
        if result?.isNotable == true {
            NotificationService.post(title: "助手 · 分享提取", body: result!.summary)
        }
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
        amount == amount.rounded() ? String(format: "%.0f", amount) : String(format: "%.2f", amount)
    }
}
