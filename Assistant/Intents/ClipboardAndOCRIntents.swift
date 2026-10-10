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
    static var description = IntentDescription("接收屏幕截图，使用系统 Vision 离线识别中文文字，并提取待办。")
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
            let recognizedText = try await OCRService.shared.recognizeText(from: image)
            guard !recognizedText.isEmpty else {
                return .result(value: "未能识别到屏幕文字")
            }

            let context = Persistence.shared.mainContext
            let result = try ImportService(context: context).ingest(recognizedText, source: "screenshot_ocr")
            if result.isNotable {
                NotificationService.post(title: "助手 · 截图提取", body: result.summary)
            }
            return .result(value: result.summary)
        } catch {
            return .result(value: "识别出错: \(error.localizedDescription)")
        }
    }
}
