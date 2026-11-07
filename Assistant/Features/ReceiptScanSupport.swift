import AssistantCore
import SwiftUI
import UIKit

/// 小票拍照与新记账链路共用的支撑组件。
///
/// 历史上与已下线的旧小票扫描视图同处一个文件；该视图零引用，
/// 2026-11-07 已删除，这里只保留仍被 `ExpenseTrackerView` 使用的
/// 解析适配器与小票相机取景器。
///
/// 注意：`ReceiptTextParser` 的正则本体只有一份，在 AssistantCore；
/// `ReceiptScanParser` 只做 Core 结果 → App 枚举的映射，不要在这里复制解析规则。

// MARK: - 小票智能解析与置信度评估

/// 小票解析结果的 App 侧视图：把 AssistantCore 的 `ReceiptParseResult`
/// （categoryRaw 为 `ExpenseCategory.rawValue`）映射回枚举。
/// 解析正则本体只有一份，位于 AssistantCore `ReceiptTextParser`。
struct ReceiptScanOutcome {
    var amount: Double
    var title: String
    var category: ExpenseCategory
    var date: Date
    var confidence: Double
    var confidenceReason: String?
    var candidateAmounts: [Double]
}

enum ReceiptScanParser {
    static func parse(_ text: String) -> ReceiptScanOutcome {
        let parsed = AssistantCore.ReceiptTextParser.parse(text)
        return ReceiptScanOutcome(
            amount: parsed.amount,
            title: parsed.title,
            category: ExpenseCategory(rawValue: parsed.categoryRaw) ?? .shopping,
            date: parsed.date,
            confidence: parsed.confidence,
            confidenceReason: parsed.confidenceReason,
            candidateAmounts: parsed.candidateAmounts
        )
    }
}

// MARK: - 相机取景控制器

struct ReceiptCameraView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ReceiptCameraView
        init(_ parent: ReceiptCameraView) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
