import AppIntents
import Foundation
import UIKit

/// 快捷指令动作：从剪贴板一键提取（可绑定背面轻点两下或操作按钮）
struct ImportClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "从剪贴板导入"
    static var description = IntentDescription("自动读取剪贴板的最新文本（例如刚复制的微信消息），提取待办。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .result(value: "剪贴板为空或不是文本")
        }

        let context = Persistence.shared.mainContext
        let result = try ImportService(context: context).ingest(text, source: "clipboard")
        if result.isNotable {
            NotificationService.post(title: "助手 · 剪贴板提取", body: result.summary)
        }
        return .result(value: result.summary)
    }
}

/// 快捷指令动作：截屏导入（快捷指令完成截屏后传给此 Intent 进行离线 OCR 识别并入库）
struct ImportScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "截屏识别并导入"
    static var description = IntentDescription("接收屏幕截图，使用系统 Vision 离线识别中文文字及预约二维码，自动提取时间、地点、事件并建立待办。")
    static var openAppWhenRun = false

    @Parameter(title: "截图文件", description: "来自快捷指令截屏动作的图像输入")
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let data = file.data
        guard let image = UIImage(data: data) else {
            return .result(value: "无法读取截图数据")
        }

        do {
            let recognized = try await OCRService.shared.recognizeTodo(from: image)
            let context = Persistence.shared.mainContext

            // 若识别出预约二维码、具体时间或场馆地点，直接构建带核销码的结构化待办
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
                try context.save()

                let locDesc = recognized.location.map { " · \($0)" } ?? ""
                let qrDesc = (recognized.qrCodeImageData != nil || recognized.qrCodePayload != nil) ? "（已存预约二维码）" : ""
                let summary = "已添加：\(recognized.title)\(locDesc)\(qrDesc)"
                NotificationService.post(title: "助手 · 截图识别成功", body: summary)
                return .result(value: summary)
            }

            guard !recognized.rawText.isEmpty else {
                return .result(value: "未能识别到屏幕文字")
            }

            let result = try ImportService(context: context).ingest(recognized.rawText, source: "screenshot_ocr")
            if result.isNotable {
                NotificationService.post(title: "助手 · 截图提取", body: result.summary)
            }
            return .result(value: result.summary)
        } catch {
            return .result(value: "识别出错: \(error.localizedDescription)")
        }
    }
}
