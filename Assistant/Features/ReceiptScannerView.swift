import PhotosUI
import SwiftUI
import UIKit

/// 小票识别记账。支持相机拍摄，也支持一次选择多张照片，适合超长小票分段拍摄。
struct ReceiptScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var recognizedText = ""
    @State private var parsedResult: ExpenseParseResult?
    @State private var showingCamera = false
    @State private var isProcessing = false
    @State private var errorMessage: String?

    let onSave: (ExpenseParseResult, String, Data?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("拍一张", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        PhotosPicker(selection: $selectedItems, maxSelectionCount: 20, matching: .images) {
                            Label("选择多张", systemImage: "photo.on.rectangle.angled")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("小票较长时，请按顺序分段拍摄或选择多张照片。识别会合并所有页面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !images.isEmpty {
                    Section("已添加 \(images.count) 张") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 70, height: 92)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(alignment: .topTrailing) {
                                            Button {
                                                images.remove(at: index)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.white, .black.opacity(0.55))
                                            }
                                            .padding(3)
                                        }
                                }
                            }
                        }

                        Button {
                            Task { await recognizeReceipt() }
                        } label: {
                            HStack {
                                if isProcessing { ProgressView() }
                                Text(isProcessing ? "正在识别…" : "识别并预览")
                                Spacer()
                                Image(systemName: "text.viewfinder")
                            }
                        }
                        .disabled(isProcessing)
                    }
                }

                if let result = parsedResult {
                    Section("识别结果") {
                        LabeledContent("金额", value: String(format: "¥%.2f", result.amount))
                        LabeledContent("项目", value: result.title)
                        LabeledContent("分类", value: result.category.rawValue)
                        Button("确认记账") {
                            onSave(result, recognizedText, images.first?.jpegData(compressionQuality: 0.82))
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("拍小票记账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showingCamera) {
                ReceiptCameraView { image in
                    images.append(image)
                    showingCamera = false
                }
            }
            .onChange(of: selectedItems) { _, items in
                Task { await loadPhotos(items) }
            }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var loaded: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                loaded.append(image)
            }
        }
        await MainActor.run {
            images.append(contentsOf: loaded)
            parsedResult = nil
            errorMessage = loaded.isEmpty && images.isEmpty ? "未读取到图片" : nil
        }
    }

    private func recognizeReceipt() async {
        await MainActor.run {
            isProcessing = true
            errorMessage = nil
            parsedResult = nil
        }
        do {
            var pages: [String] = []
            for image in images {
                pages.append(try await OCRService.shared.recognizeText(from: image))
            }
            let text = pages.joined(separator: "\n")
            guard let result = ReceiptTextParser.parse(text) else {
                throw ReceiptScanError.amountNotFound
            }
            await MainActor.run {
                recognizedText = text
                parsedResult = result
                isProcessing = false
            }
        } catch {
            await MainActor.run {
                isProcessing = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum ReceiptScanError: LocalizedError {
    case amountNotFound
    var errorDescription: String? { "未识别到小票金额，请补拍含有“合计/实付”金额的部分" }
}

/// 小票金额优先取合计、实付、应付等字段，避免长小票中的商品价格被误记。
private enum ReceiptTextParser {
    static func parse(_ text: String) -> ExpenseParseResult? {
        let patterns = [
            "(?:合计|总计|应付|实付|实际支付|支付金额|订单金额)\\s*[:：]?\\s*[¥￥]?\\s*([0-9]+(?:[.,][0-9]{1,2})?)",
            "[¥￥]\\s*([0-9]+(?:[.,][0-9]{1,2})?)\\s*(?:元)?\\s*(?:合计|实付|应付)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let amount = Double(text[range].replacingOccurrences(of: ",", with: ".")), amount > 0 else { continue }
            let title = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map(String.init)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "小票消费"
            return ExpenseParseResult(amount: amount, isIncome: false, category: .shopping, title: title, date: .now)
        }
        return nil
    }
}

private struct ReceiptCameraView: UIViewControllerRepresentable {
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
